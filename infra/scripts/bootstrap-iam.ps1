param(
  [string]$Org = $env:ORG,
  [string]$Repo = $env:REPO,
  [string]$EnvName = $env:ENV_NAME,
  [string]$AwsRegion = $env:AWS_REGION,
  [string]$AccountId = $env:ACCOUNT_ID,
  [string]$StateBucketName = $env:STATE_BUCKET_NAME,
  [string]$BootstrapRoleName = $(if ($env:BOOTSTRAP_ROLE_NAME) { $env:BOOTSTRAP_ROLE_NAME } else { "TerraformBootstrapRole" }),
  [string]$ExecRoleName = $(if ($env:EXEC_ROLE_NAME) { $env:EXEC_ROLE_NAME } else { "TerraformExecutionRole" }),
  [string]$UseKms = $(if ($env:USE_KMS) { $env:USE_KMS } elseif ($env:TF_USE_KMS) { $env:TF_USE_KMS } else { "true" }),
  [string]$StateKmsKeyArn = $env:STATE_KMS_KEY_ARN,
  [switch]$DryRun
)

function Fail($Message) {
  Write-Host "Error: $Message"
  exit 1
}

if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
  Fail "Missing required command: aws"
}

if (-not $Org -or -not $Repo -or -not $EnvName -or -not $AwsRegion -or -not $StateBucketName) {
  Fail "Set ORG, REPO, ENV_NAME, AWS_REGION, and STATE_BUCKET_NAME"
}

$tfWorkdir = $(if ($env:TF_WORKDIR) { $env:TF_WORKDIR } else { "infra" })
$tfOrgPrefix = $(if ($env:TF_ORG_PREFIX) { $env:TF_ORG_PREFIX } else { $Org })
$tfStateBucketSuffix = $(if ($env:TF_STATE_BUCKET_SUFFIX) { $env:TF_STATE_BUCKET_SUFFIX } else { "" })
$tfEnableAccessLogs = $(if ($env:TF_ENABLE_ACCESS_LOGS) { $env:TF_ENABLE_ACCESS_LOGS } else { "false" })
$tfLogBucketName = $(if ($env:TF_LOG_BUCKET_NAME) { $env:TF_LOG_BUCKET_NAME } else { "" })
$tfLogBucketPrefix = $(if ($env:TF_LOG_BUCKET_PREFIX) { $env:TF_LOG_BUCKET_PREFIX } else { "tfstate/" })
$tfExtraTagsHcl = $(if ($env:TF_EXTRA_TAGS_HCL) { $env:TF_EXTRA_TAGS_HCL } else { "" })

$dryRunEnabled = $DryRun.IsPresent -or $env:DRY_RUN -in @("1", "true", "TRUE")

$currentAccountId = aws sts get-caller-identity --query Account --output text
if ($LASTEXITCODE -ne 0) { Fail "Failed to call sts:get-caller-identity. Check AWS credentials." }
if ($AccountId -and $AccountId -ne $currentAccountId) {
  Fail "ACCOUNT_ID ($AccountId) does not match current credentials ($currentAccountId)"
}

aws iam list-open-id-connect-providers > $null
if ($LASTEXITCODE -ne 0) { Fail "Missing iam:ListOpenIDConnectProviders permission" }

$providerArn = $null
$arns = aws iam list-open-id-connect-providers --query 'OpenIDConnectProviderList[].Arn' --output text 2>&1
if ($LASTEXITCODE -ne 0) { Fail "Missing iam:ListOpenIDConnectProviders permission" }

foreach ($arn in $arns -split "\s+") {
  if (-not $arn -or $arn -eq "None") { continue }
  $url = aws iam get-open-id-connect-provider --open-id-connect-provider-arn $arn --query Url --output text 2>&1
  if ($LASTEXITCODE -ne 0) {
    if ($url -match "AccessDenied") { Fail "Missing iam:GetOpenIDConnectProvider permission" }
    continue
  }
  if ($url -eq "token.actions.githubusercontent.com") { $providerArn = $arn; break }
}

if (-not $providerArn) {
  if ($dryRunEnabled) {
    $providerArn = "arn:aws:iam::${currentAccountId}:oidc-provider/token.actions.githubusercontent.com"
    Write-Host "[dry-run] Would create OIDC provider: $providerArn"
  } else {
    $providerArn = aws iam create-open-id-connect-provider `
      --url https://token.actions.githubusercontent.com `
      --client-id-list sts.amazonaws.com `
      --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1 `
      --query OpenIDConnectProviderArn --output text
    if ($LASTEXITCODE -ne 0) { Fail "Failed to create OIDC provider" }
  }
}

$trustPolicy = @"
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Federated": "$providerArn" },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
          "token.actions.githubusercontent.com:sub": "repo:$Org/$Repo:environment:$EnvName"
        }
      }
    }
  ]
}
"@

function Ensure-Role($RoleName, $TrustPolicy) {
  $out = aws iam get-role --role-name $RoleName 2>&1
  if ($LASTEXITCODE -eq 0) { Write-Host "Role exists: $RoleName (skipping create)"; return }
  if ($out -match "NoSuchEntity") {
    if ($dryRunEnabled) {
      Write-Host "[dry-run] Would create role: $RoleName"
      return
    }
    aws iam create-role --role-name $RoleName --assume-role-policy-document $TrustPolicy > $null
    if ($LASTEXITCODE -ne 0) { Fail "Missing iam:CreateRole permission for $RoleName" }
    return
  }
  Fail "Missing iam:GetRole permission for $RoleName"
}

Ensure-Role -RoleName $BootstrapRoleName -TrustPolicy $trustPolicy
Ensure-Role -RoleName $ExecRoleName -TrustPolicy $trustPolicy

$bootstrapKmsStmt = ""
if ($UseKms -eq "true" -or $UseKms -eq "1") {
  $bootstrapKmsStmt = @"
,
    {
      "Sid": "KmsAdmin",
      "Effect": "Allow",
      "Action": [
        "kms:CreateKey",
        "kms:CreateAlias",
        "kms:DescribeKey",
        "kms:EnableKeyRotation",
        "kms:PutKeyPolicy",
        "kms:ScheduleKeyDeletion",
        "kms:TagResource",
        "kms:UntagResource"
      ],
      "Resource": "*"
    }
"@
}

$bootstrapPolicy = @"
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "CreateBucket",
      "Effect": "Allow",
      "Action": ["s3:CreateBucket"],
      "Resource": "*"
    },
    {
      "Sid": "StateBucketAdmin",
      "Effect": "Allow",
      "Action": [
        "s3:GetBucketLocation",
        "s3:ListBucket",
        "s3:GetBucketPolicy",
        "s3:GetBucketVersioning",
        "s3:GetBucketEncryption",
        "s3:GetBucketPublicAccessBlock",
        "s3:GetBucketOwnershipControls",
        "s3:GetBucketLogging",
        "s3:GetBucketTagging",
        "s3:PutBucketPolicy",
        "s3:PutBucketVersioning",
        "s3:PutBucketEncryption",
        "s3:PutBucketPublicAccessBlock",
        "s3:PutBucketOwnershipControls",
        "s3:PutBucketLogging",
        "s3:PutBucketTagging"
      ],
      "Resource": "arn:aws:s3:::$StateBucketName"
    },
    {
      "Sid": "StateBucketObjects",
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:GetObject",
        "s3:GetObjectVersion",
        "s3:DeleteObject",
        "s3:AbortMultipartUpload",
        "s3:ListMultipartUploadParts",
        "s3:ListBucketMultipartUploads"
      ],
      "Resource": "arn:aws:s3:::$StateBucketName/*"
    }$bootstrapKmsStmt
  ]
}
"@

$execKmsStmt = ""
if ($StateKmsKeyArn) {
  $execKmsStmt = @"
,
    {
      "Sid": "KmsState",
      "Effect": "Allow",
      "Action": [
        "kms:Encrypt",
        "kms:Decrypt",
        "kms:GenerateDataKey*",
        "kms:ReEncrypt*",
        "kms:DescribeKey"
      ],
      "Resource": "$StateKmsKeyArn"
    }
"@
} elseif ($UseKms -eq "true" -or $UseKms -eq "1") {
  $execKmsStmt = @"
,
    {
      "Sid": "KmsStateViaS3",
      "Effect": "Allow",
      "Action": [
        "kms:Encrypt",
        "kms:Decrypt",
        "kms:GenerateDataKey*",
        "kms:ReEncrypt*",
        "kms:DescribeKey"
      ],
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "kms:ViaService": "s3.$AwsRegion.amazonaws.com"
        },
        "StringLike": {
          "kms:EncryptionContext:aws:s3:arn": "arn:aws:s3:::$StateBucketName/*"
        }
      }
    }
"@
}

$execPolicy = @"
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "StateBucketList",
      "Effect": "Allow",
      "Action": [
        "s3:ListBucket",
        "s3:GetBucketLocation",
        "s3:ListBucketMultipartUploads"
      ],
      "Resource": "arn:aws:s3:::$StateBucketName"
    },
    {
      "Sid": "StateObjectsRW",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:GetObjectVersion",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:AbortMultipartUpload",
        "s3:ListMultipartUploadParts"
      ],
      "Resource": "arn:aws:s3:::$StateBucketName/*"
    }$execKmsStmt
  ]
}
"@

if ($dryRunEnabled) {
  Write-Host "[dry-run] Would attach inline policy TerraformBootstrapPolicy to $BootstrapRoleName"
  Write-Host "[dry-run] Would attach inline policy TerraformExecutionPolicy to $ExecRoleName"
} else {
  aws iam put-role-policy --role-name $BootstrapRoleName --policy-name TerraformBootstrapPolicy --policy-document $bootstrapPolicy
  if ($LASTEXITCODE -ne 0) { Fail "Missing iam:PutRolePolicy permission for $BootstrapRoleName" }
  aws iam put-role-policy --role-name $ExecRoleName --policy-name TerraformExecutionPolicy --policy-document $execPolicy
  if ($LASTEXITCODE -ne 0) { Fail "Missing iam:PutRolePolicy permission for $ExecRoleName" }
}

$useKmsBool = "false"
if ($UseKms -eq "true" -or $UseKms -eq "1") { $useKmsBool = "true" }

$tfExtraTagsHclOut = $(if ($tfExtraTagsHcl) { $tfExtraTagsHcl } else { "{}" })

Write-Host "OIDC provider: $providerArn"
Write-Host "Bootstrap role: arn:aws:iam::${currentAccountId}:role/$BootstrapRoleName"
Write-Host "Execution role: arn:aws:iam::${currentAccountId}:role/$ExecRoleName"
Write-Host "Set GitHub Environment variables:"
Write-Host "  TF_WORKDIR=$tfWorkdir"
Write-Host "  TF_ORG_PREFIX=$tfOrgPrefix"
Write-Host "  TF_STATE_BUCKET_SUFFIX=$tfStateBucketSuffix"
Write-Host "  TF_ENABLE_ACCESS_LOGS=$tfEnableAccessLogs"
Write-Host "  TF_LOG_BUCKET_NAME=$tfLogBucketName"
Write-Host "  TF_LOG_BUCKET_PREFIX=$tfLogBucketPrefix"
Write-Host "  TF_USE_KMS=$useKmsBool"
Write-Host "  TF_EXTRA_TAGS_HCL=$tfExtraTagsHclOut"
Write-Host "  AWS_ACCOUNT_ID=$currentAccountId"
Write-Host "  AWS_REGION=$AwsRegion"
Write-Host "  AWS_BOOTSTRAP_ROLE_ARN=arn:aws:iam::${currentAccountId}:role/$BootstrapRoleName"
Write-Host "  AWS_ROLE_ARN=arn:aws:iam::${currentAccountId}:role/$ExecRoleName"

Write-Host ""
Write-Host "Bootstrap tfvars values (append to infra/bootstrap/$EnvName.tfvars):"
Write-Host "env        = \"$EnvName\""
Write-Host "account_id = \"$currentAccountId\""
Write-Host "primary_region = \"$AwsRegion\""
Write-Host "assume_role_arn = \"arn:aws:iam::${currentAccountId}:role/$BootstrapRoleName\""
Write-Host "state_bucket_admin_principals = [\"arn:aws:iam::${currentAccountId}:role/$BootstrapRoleName\"]"
Write-Host "state_bucket_rw_principals = [\"arn:aws:iam::${currentAccountId}:role/$ExecRoleName\"]"
Write-Host "kms_admin_principals = [\"arn:aws:iam::${currentAccountId}:role/$BootstrapRoleName\"]"
Write-Host "use_kms = $useKmsBool"
Write-Host ""
Write-Host "Keep org_prefix and state_bucket_suffix aligned with your naming standard."
