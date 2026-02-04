param(
  [string]$env = "",
  [string]$stack = "storage",
  [Parameter(Position = 0)][string]$cmd = "",
  [Parameter(ValueFromRemainingArguments = $true)][string[]]$args
)

if (-not $cmd) {
  Write-Host "Usage: ./scripts/tf.ps1 -env <dev|stage|prod> -stack <stack> <plan|apply|destroy|init|validate|fmt|lint|sec>"
  exit 1
}

$allowLocal = $env:ALLOW_LOCAL_TF
if (-not $env:GITHUB_ACTIONS -and -not $env:CI -and $allowLocal -notin @("1", "true", "TRUE")) {
  Write-Host "Local Terraform execution is disabled. Use GitHub Actions workflows (PR/merge or workflow_dispatch)."
  Write-Host "Set ALLOW_LOCAL_TF=1 to override for break-glass use only."
  exit 1
}

if (-not $env -and $cmd -ne "fmt") {
  Write-Host "Missing -env. Example: -env dev"
  exit 1
}

$rootDir = $env:TF_ROOT
if (-not $rootDir) {
  $rootDir = (Resolve-Path (Join-Path $PSScriptRoot ".."))
}

$stackDir = Join-Path $rootDir "live/$env/$stack"
$backendConfig = Join-Path $stackDir "backend.hcl"

if ($cmd -ne "fmt") {
  if (-not (Test-Path $stackDir)) {
    Write-Host "Stack directory not found: $stackDir"
    exit 1
  }
}

switch ($cmd) {
  "fmt" {
    terraform fmt -recursive $rootDir
  }
  "lint" {
    tflint --init --chdir $stackDir
    tflint --chdir $stackDir
  }
  "sec" {
    tfsec $stackDir
  }
  "init" {
    terraform -chdir=$stackDir init -backend-config=$backendConfig
  }
  default {
    terraform -chdir=$stackDir init -backend-config=$backendConfig
    terraform -chdir=$stackDir $cmd @args
  }
}
