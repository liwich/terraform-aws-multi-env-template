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

if (-not $env -and $cmd -ne "fmt") {
  Write-Host "Missing -env. Example: -env dev"
  exit 1
}

$stackDir = "live/$env/$stack"
$backendConfig = "$stackDir/backend.hcl"

if ($cmd -ne "fmt") {
  if (-not (Test-Path $stackDir)) {
    Write-Host "Stack directory not found: $stackDir"
    exit 1
  }
}

switch ($cmd) {
  "fmt" {
    terraform fmt -recursive
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
