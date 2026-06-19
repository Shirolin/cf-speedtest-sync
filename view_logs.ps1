# PowerShell script to view Cloudflare DNS sync logs from the past 7 days.
$ErrorActionPreference = "Stop"

$scriptPath = split-path -parent $MyInvocation.MyCommand.Definition
$configPath = "$scriptPath\config.json"

if (-not (Test-Path $configPath)) {
    Write-Error "[ERROR] config.json missing. Cannot determine domain name."
    exit 1
}

$config = Get-Content $configPath -Raw -Encoding utf8 | ConvertFrom-Json
$domain = $config.Domain
$logPath = "$scriptPath\output\$domain\sync.log"

if (-not (Test-Path $logPath)) {
    Write-Error "[ERROR] Log file not found at: $logPath"
    exit 1
}

$dateLimit = (Get-Date).AddDays(-7).ToString("yyyy-MM-dd")

Write-Host ">>> Filter logs since: $dateLimit (Past 7 days) <<<" -ForegroundColor Cyan
Write-Host "--------------------------------------------------------"

Get-Content -Path $logPath | Where-Object {
    if ($_ -match '^\[(\d{4}-\d{2}-\d{2})') {
        $Matches[1] -ge $dateLimit
    } else {
        $true # Keep non-timestamped lines
    }
}
