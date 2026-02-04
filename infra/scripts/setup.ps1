#Requires -Version 5.1
<#
.SYNOPSIS
    Terraform Accelerator Setup Wizard (PowerShell)
.DESCRIPTION
    Generates configuration files and optionally provisions IAM roles
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Split-Path -Parent $ScriptDir

function Write-Info { param($Message) Write-Host "[INFO] $Message" -ForegroundColor Blue }
function Write-Success { param($Message) Write-Host "[OK] $Message" -ForegroundColor Green }
function Write-Warn { param($Message) Write-Host "[WARN] $Message" -ForegroundColor Yellow }
function Write-Err { param($Message) Write-Host "[ERROR] $Message" -ForegroundColor Red }
function Fail { param($Message) Write-Err $Message; exit 1 }

function Read-Prompt {
    param(
        [string]$PromptText,
        [string]$Default = ""
    )
    if ($Default) {
        $input = Read-Host "$PromptText [$Default]"
        if ([string]::IsNullOrWhiteSpace($input)) { return $Default }
        return $input
    }
    return Read-Host $PromptText
}

function Read-YesNo {
    param(
        [string]$PromptText
    )
    $input = Read-Host "$PromptText [y/N]"
    return $input -match "^[Yy]"
}

function Provision-IAM {
    param(
        [string]$Env,
        [string]$AccountId,
        [string]$Region,
        [string]$BucketName,
        [string]$BootstrapRole,
        [string]$ExecRole,
        [string]$GithubOrg,
        [string]$GithubRepo,
        [bool]$UseKms,
        [bool]$DryRun
    )

    Write-Info "Provisioning IAM for $Env environment..."

    # Verify credentials
    $currentAccount = aws sts get-caller-identity --query Account --output text 2>&1
    if ($LASTEXITCODE -ne 0) { Fail "Failed to call sts:get-caller-identity. Check AWS credentials." }
    
    if ($currentAccount -ne $AccountId) {
        Write-Warn "Current AWS credentials are for account $currentAccount, not $AccountId"
        Write-Warn "Skipping IAM provisioning for $Env. Switch credentials and re-run."
        return $false
    }

    # Check/create OIDC provider
    $providerArn = $null
    $arns = aws iam list-open-id-connect-providers --query 'OpenIDConnectProviderList[].Arn' --output text 2>&1
    if ($LASTEXITCODE -ne 0) { Fail "Missing iam:ListOpenIDConnectProviders permission" }

    foreach ($arn in $arns -split "\s+") {
        if (-not $arn -or $arn -eq "None") { continue }
        $url = aws iam get-open-id-connect-provider --open-id-connect-provider-arn $arn --query Url --output text 2>&1
        if ($LASTEXITCODE -ne 0) { continue }
        if ($url -eq "token.actions.githubusercontent.com") { 
            $providerArn = $arn
            break 
        }
    }

    if (-not $providerArn) {
        if ($DryRun) {
            $providerArn = "arn:aws:iam::${AccountId}:oidc-provider/token.actions.githubusercontent.com"
            Write-Info "[dry-run] Would create OIDC provider: $providerArn"
        } else {
            Write-Info "Creating GitHub OIDC provider..."
            $providerArn = aws iam create-open-id-connect-provider `
                --url https://token.actions.githubusercontent.com `
                --client-id-list sts.amazonaws.com `
                --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1 `
                --query OpenIDConnectProviderArn --output text
            if ($LASTEXITCODE -ne 0) { Fail "Failed to create OIDC provider" }
            Write-Success "Created OIDC provider"
        }
    } else {
        Write-Success "OIDC provider already exists"
    }

    # Trust policy
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
          "token.actions.githubusercontent.com:sub": "repo:$GithubOrg/${GithubRepo}:environment:$Env"
        }
      }
    }
  ]
}
"@

    # Create roles
    function Ensure-Role {
        param([string]$RoleName, [string]$Policy)
        $out = aws iam get-role --role-name $RoleName 2>&1
        if ($LASTEXITCODE -eq 0) { 
            Write-Success "Role exists: $RoleName"
            return 
        }
        if ($out -match "NoSuchEntity") {
            if ($DryRun) {
                Write-Info "[dry-run] Would create role: $RoleName"
                return
            }
            Write-Info "Creating role: $RoleName..."
            aws iam create-role --role-name $RoleName --assume-role-policy-document $Policy > $null
            if ($LASTEXITCODE -ne 0) { Fail "Failed to create role $RoleName" }
            Write-Success "Created role: $RoleName"
            return
        }
        Fail "Missing iam:GetRole permission for $RoleName"
    }

    Ensure-Role -RoleName $BootstrapRole -Policy $trustPolicy
    Ensure-Role -RoleName $ExecRole -Policy $trustPolicy

    # Bootstrap policy
    $bootstrapKmsStmt = ""
    if ($UseKms) {
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
        "kms:UntagResource",
        "kms:ListAliases",
        "kms:DeleteAlias",
        "kms:UpdateAlias"
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
      "Sid": "ListAllBuckets",
      "Effect": "Allow",
      "Action": ["s3:ListAllMyBuckets"],
      "Resource": "*"
    },
    {
      "Sid": "StateBucketAdmin",
      "Effect": "Allow",
      "Action": [
        "s3:GetBucket*",
        "s3:GetLifecycleConfiguration",
        "s3:GetReplicationConfiguration",
        "s3:GetAccelerateConfiguration",
        "s3:GetEncryptionConfiguration",
        "s3:ListBucket",
        "s3:PutBucketPolicy",
        "s3:PutBucketVersioning",
        "s3:PutBucketEncryption",
        "s3:PutBucketPublicAccessBlock",
        "s3:PutBucketOwnershipControls",
        "s3:PutBucketLogging",
        "s3:PutBucketTagging",
        "s3:PutBucketCors",
        "s3:PutLifecycleConfiguration",
        "s3:PutReplicationConfiguration",
        "s3:PutAccelerateConfiguration",
        "s3:DeleteBucketPolicy",
        "s3:DeleteBucketCors",
        "s3:DeleteBucketLifecycle",
        "s3:DeleteBucketReplication"
      ],
      "Resource": "arn:aws:s3:::$BucketName"
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
      "Resource": "arn:aws:s3:::$BucketName/*"
    },
    {
      "Sid": "IAMPolicyManagement",
      "Effect": "Allow",
      "Action": [
        "iam:CreatePolicy",
        "iam:DeletePolicy",
        "iam:GetPolicy",
        "iam:GetPolicyVersion",
        "iam:ListPolicyVersions",
        "iam:CreatePolicyVersion",
        "iam:DeletePolicyVersion",
        "iam:TagPolicy",
        "iam:UntagPolicy"
      ],
      "Resource": "arn:aws:iam::${AccountId}:policy/${OrgPrefix}-terraform-execution-*"
    },
    {
      "Sid": "IAMRolePolicyAttachment",
      "Effect": "Allow",
      "Action": [
        "iam:AttachRolePolicy",
        "iam:DetachRolePolicy",
        "iam:ListAttachedRolePolicies"
      ],
      "Resource": "arn:aws:iam::${AccountId}:role/$ExecRole"
    }$bootstrapKmsStmt
  ]
}
"@

    # Exec policy
    $execKmsStmt = ""
    if ($UseKms) {
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
          "kms:ViaService": "s3.$Region.amazonaws.com"
        },
        "StringLike": {
          "kms:EncryptionContext:aws:s3:arn": "arn:aws:s3:::$BucketName/*"
        }
      }
    }
"@
    }

    # Execution role policy - MINIMAL: only state bucket access
    # Infrastructure permissions are managed by Terraform in bootstrap/execution-policy.tf
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
      "Resource": "arn:aws:s3:::$BucketName"
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
      "Resource": "arn:aws:s3:::$BucketName/*"
    }$execKmsStmt
  ]
}
"@
    # NOTE: Infrastructure permissions (S3, EC2, Lambda, etc.) are managed by Terraform
    # in infra/bootstrap/execution-policy.tf and applied via the bootstrap workflow.

    # Attach policies
    if ($DryRun) {
        Write-Info "[dry-run] Would attach TerraformBootstrapPolicy to $BootstrapRole"
        Write-Info "[dry-run] Would attach TerraformExecutionPolicy to $ExecRole"
    } else {
        Write-Info "Attaching policies..."
        aws iam put-role-policy --role-name $BootstrapRole --policy-name TerraformBootstrapPolicy --policy-document $bootstrapPolicy
        if ($LASTEXITCODE -ne 0) { Fail "Failed to attach policy to $BootstrapRole" }
        aws iam put-role-policy --role-name $ExecRole --policy-name TerraformExecutionPolicy --policy-document $execPolicy
        if ($LASTEXITCODE -ne 0) { Fail "Failed to attach policy to $ExecRole" }
        Write-Success "Attached IAM policies"
    }

    Write-Success "IAM provisioning complete for $Env"
    return $true
}

# Main script
Write-Host ""
Write-Host "==========================================="
Write-Host "  Terraform Accelerator Setup Wizard"
Write-Host "==========================================="
Write-Host ""

# Global configuration
Write-Info "Global Configuration"
Write-Host ""

$OrgPrefix = Read-Prompt "Organization/project prefix (lowercase, e.g., 'acme' or 'myproject')"
if (-not ($OrgPrefix -match "^[a-z0-9-]+$") -or $OrgPrefix.Length -lt 3) {
    Fail "Invalid org_prefix: must be 3+ chars, lowercase alphanumeric and hyphens"
}

$PrimaryRegion = Read-Prompt "Primary AWS region" "us-east-1"
$StateBucketSuffix = Read-Prompt "State bucket suffix for uniqueness (optional, press Enter to skip)" ""

# KMS encryption option
Write-Host ""
$UseKms = Read-YesNo "Use KMS encryption for state bucket? (recommended for production)"

# Access logging option
$EnableAccessLogs = Read-YesNo "Enable S3 access logging for state bucket?"
$LogBucketName = $null
$LogBucketPrefix = "tfstate/"
if ($EnableAccessLogs) {
    $LogBucketName = Read-Prompt "Log bucket name (must already exist)"
    $LogBucketPrefix = Read-Prompt "Log bucket prefix" "tfstate/"
}

# GitHub info
Write-Host ""
Write-Info "GitHub Repository (for OIDC role trust)"
$GithubOrg = Read-Prompt "GitHub organization or username"
$GithubRepo = Read-Prompt "GitHub repository name"

# IAM provisioning
Write-Host ""
$ProvisionIAM = Read-YesNo "Provision IAM roles automatically? (requires AWS CLI with admin access)"

$DryRun = $false
if ($ProvisionIAM) {
    if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
        Fail "AWS CLI is required for IAM provisioning"
    }
    $DryRun = Read-YesNo "Dry run mode? (show what would be created without making changes)"
}

Write-Host ""
Write-Info "Environment Configuration"
Write-Host ""
Write-Host "Configure each environment. Dev is required; stage/prod can be skipped by pressing Enter."
Write-Host ""

$EnvConfigs = @{}

foreach ($env in @("dev", "stage", "prod")) {
    Write-Host ""
    Write-Info "=== $env environment ==="
    
    if ($env -eq "dev") {
        # Dev is required
        $accountId = Read-Prompt "AWS Account ID for $env"
        while (-not ($accountId -match "^[0-9]{12}$")) {
            Write-Error "Invalid AWS account ID: $accountId (must be 12 digits)"
            $accountId = Read-Prompt "AWS Account ID for $env"
        }
    } else {
        # Stage/prod are optional - Enter to skip
        $accountId = Read-Prompt "AWS Account ID for $env (Enter to skip)" ""
        if ([string]::IsNullOrEmpty($accountId)) {
            Write-Warn "Skipping $env environment"
            continue
        }
        if (-not ($accountId -match "^[0-9]{12}$")) {
            Fail "Invalid AWS account ID: $accountId (must be 12 digits)"
        }
    }
    
    $bootstrapRole = Read-Prompt "Bootstrap IAM Role name for $env" "TerraformBootstrapRole"
    $execRole = Read-Prompt "Terraform Execution Role name for $env" "TerraformExecutionRole"
    
    # Compute bucket name
    if ($StateBucketSuffix) {
        $bucketName = "$OrgPrefix-tfstate-$env-$accountId-$PrimaryRegion-$StateBucketSuffix"
    } else {
        $bucketName = "$OrgPrefix-tfstate-$env-$accountId-$PrimaryRegion"
    }
    
    $EnvConfigs[$env] = @{
        AccountId = $accountId
        BootstrapRole = $bootstrapRole
        ExecRole = $execRole
        BucketName = $bucketName
    }
}

# Provision IAM if requested
if ($ProvisionIAM) {
    Write-Host ""
    Write-Info "Provisioning IAM resources..."
    Write-Host ""
    
    foreach ($env in $EnvConfigs.Keys) {
        $config = $EnvConfigs[$env]
        try {
            Provision-IAM `
                -Env $env `
                -AccountId $config.AccountId `
                -Region $PrimaryRegion `
                -BucketName $config.BucketName `
                -BootstrapRole $config.BootstrapRole `
                -ExecRole $config.ExecRole `
                -GithubOrg $GithubOrg `
                -GithubRepo $GithubRepo `
                -UseKms $UseKms `
                -DryRun $DryRun
        } catch {
            Write-Warn "IAM provisioning failed for $env`: $_"
        }
        Write-Host ""
    }
}

Write-Host ""
Write-Info "Generating configuration files..."
Write-Host ""

$DefaultStacks = @("storage")

foreach ($env in $EnvConfigs.Keys) {
    $config = $EnvConfigs[$env]
    $accountId = $config.AccountId
    $bootstrapRole = $config.BootstrapRole
    $execRole = $config.ExecRole
    $bucketName = $config.BucketName
    
    # Bootstrap tfvars
    $tfvarsContent = @"
org_prefix = "$OrgPrefix"
env        = "$env"
account_id = "$accountId"

primary_region      = "$PrimaryRegion"
state_bucket_suffix = "$StateBucketSuffix"

use_kms            = $($UseKms.ToString().ToLower())
enable_access_logs = $($EnableAccessLogs.ToString().ToLower())
log_bucket_name    = $(if ($LogBucketName) { "`"$LogBucketName`"" } else { "null" })
log_bucket_prefix  = "$LogBucketPrefix"

aws_profile     = null
assume_role_arn = null

state_bucket_admin_principals = ["arn:aws:iam::${accountId}:role/$bootstrapRole"]
state_bucket_rw_principals    = ["arn:aws:iam::${accountId}:role/$execRole"]
kms_admin_principals          = ["arn:aws:iam::${accountId}:role/$bootstrapRole"]

extra_tags = {}

#######################################
# Execution Role Policy (managed by Terraform)
#######################################

manage_execution_role_policy = true
execution_role_name          = "$execRole"

# S3 permissions automatically scoped to `${org_prefix}-* buckets
enable_s3_permissions = true

# Add extra permissions here (EC2, Lambda, DynamoDB, etc.)
extra_execution_policy_statements = []
"@
    $tfvarsPath = Join-Path $RootDir "bootstrap\$env.tfvars"
    Set-Content -Path $tfvarsPath -Value $tfvarsContent -Encoding UTF8
    Write-Success "Created bootstrap\$env.tfvars"
    
    # Bootstrap backend.hcl
    $backendContent = @"
bucket       = "$bucketName"
key          = "bootstrap/terraform.tfstate"
region       = "$PrimaryRegion"
encrypt      = true
use_lockfile = true
"@
    $backendPath = Join-Path $RootDir "bootstrap\$env.backend.hcl"
    Set-Content -Path $backendPath -Value $backendContent -Encoding UTF8
    Write-Success "Created bootstrap\$env.backend.hcl"
    
    # Live stack configs
    foreach ($stack in $DefaultStacks) {
        $stackDir = Join-Path $RootDir "live\$env\$stack"
        
        if (-not (Test-Path $stackDir)) {
            Write-Warn "Stack directory not found: live\$env\$stack, skipping"
            continue
        }
        
        # backend.hcl
        $stackBackendContent = @"
bucket       = "$bucketName"
key          = "$env/$stack/terraform.tfstate"
region       = "$PrimaryRegion"
encrypt      = true
use_lockfile = true
"@
        $stackBackendPath = Join-Path $stackDir "backend.hcl"
        Set-Content -Path $stackBackendPath -Value $stackBackendContent -Encoding UTF8
        Write-Success "Created live\$env\$stack\backend.hcl"
        
        # terraform.tfvars
        $stackTfvarsContent = @"
env                 = "$env"
org_prefix          = "$OrgPrefix"
expected_account_id = "$accountId"

primary_region  = "$PrimaryRegion"
allowed_regions = ["$PrimaryRegion"]

assume_role_arn = null
aws_profile     = null

example_bucket_suffix = ""

extra_tags = {}
"@
        $stackTfvarsPath = Join-Path $stackDir "terraform.tfvars"
        Set-Content -Path $stackTfvarsPath -Value $stackTfvarsContent -Encoding UTF8
        Write-Success "Created live\$env\$stack\terraform.tfvars"
    }
}

Write-Host ""
Write-Host "==========================================="
Write-Host "  Setup Complete!"
Write-Host "==========================================="
Write-Host ""

Write-Info "GitHub Environment Secrets (configure in repository settings):"
Write-Host ""
Write-Host "For each environment (dev, stage, prod), set these secrets:"

foreach ($env in $EnvConfigs.Keys) {
    $config = $EnvConfigs[$env]
    Write-Host ""
    Write-Host "  Environment: $env"
    Write-Host "    AWS_REGION: $PrimaryRegion"
    Write-Host "    AWS_ACCOUNT_ID: $($config.AccountId)"
    Write-Host "    AWS_BOOTSTRAP_ROLE_ARN: arn:aws:iam::$($config.AccountId):role/$($config.BootstrapRole)"
    Write-Host "    AWS_ROLE_ARN: arn:aws:iam::$($config.AccountId):role/$($config.ExecRole)"
}

Write-Host ""
Write-Info "Next steps:"
Write-Host ""
Write-Host "1. Commit the generated configuration files:"
Write-Host "   git add -A && git commit -m 'Configure Terraform for $OrgPrefix'"
Write-Host ""
Write-Host "2. Configure GitHub Environment secrets (see above)"
Write-Host ""
Write-Host "3. Push to GitHub and run the bootstrap workflow:"
Write-Host "   - Go to Actions -> Terraform -> Run workflow"
Write-Host "   - Select: target=bootstrap, env=dev, action=apply, bootstrap-phase=initial"
Write-Host "   - After successful apply, run again with bootstrap-phase=migrate"
Write-Host ""
Write-Success "Configuration complete!"
