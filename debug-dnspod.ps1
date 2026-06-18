# DNSPod API v3 (TC3-HMAC-SHA256) Debugger
# ========================================================
# 功能：调用 DescribeDomainList 接口，输出全流程调试信息
# ========================================================

Add-Type -AssemblyName System.Net.Http
$scriptPath = split-path -parent $MyInvocation.MyCommand.Definition
Set-Location $scriptPath

$configPath = "$scriptPath\config.json"
if (-Not (Test-Path $configPath)) { Write-Host "Error: config.json missing!" -ForegroundColor Red; exit 1 }
$config = Get-Content $configPath -Raw -Encoding utf8 | ConvertFrom-Json

function Invoke-TencentDebug {
    param ([string]$Action, [object]$Payload)
    
    $Service = "dnspod"; $Version = "2021-03-23"; $HostName = "dnspod.tencentcloudapi.com"
    $Algorithm = "TC3-HMAC-SHA256"
    $Timestamp = [long][double]::Parse((Get-Date (Get-Date).ToUniversalTime() -UFormat %s))
    $Date = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd")
    $JsonPayload = $Payload | ConvertTo-Json -Compress
    
    # --- 1. Compute Payload Hash ---
    $HashedPayload = [System.BitConverter]::ToString((New-Object System.Security.Cryptography.SHA256Managed).ComputeHash([System.Text.Encoding]::UTF8.GetBytes($JsonPayload))).Replace("-", "").ToLower()
    
    # --- 2. Build Canonical Request ---
    $SignedHeaders = "content-type;host"
    $ContentType = "application/json; charset=utf-8"
    $CanonicalHeaders = "content-type:$ContentType`nhost:$HostName`n"
    $CanonicalRequest = "POST`n/`n`n$CanonicalHeaders`n$SignedHeaders`n$HashedPayload"
    $HashedCanonicalRequest = [System.BitConverter]::ToString((New-Object System.Security.Cryptography.SHA256Managed).ComputeHash([System.Text.Encoding]::UTF8.GetBytes($CanonicalRequest))).Replace("-", "").ToLower()
    
    # --- 3. Build String to Sign ---
    $CredentialScope = "$Date/$Service/tc3_request"
    $StringToSign = "$Algorithm`n$Timestamp`n$CredentialScope`n$HashedCanonicalRequest"
    
    # --- 4. Compute Signature ---
    function HMAC256 { param([byte[]]$Key, [string]$Data)
        $hmac = New-Object System.Security.Cryptography.HMACSHA256; $hmac.Key = $Key
        return $hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Data))
    }
    $SDate = HMAC256 -Key ([System.Text.Encoding]::UTF8.GetBytes("TC3" + $config.SecretKey)) -Data $Date
    $SService = HMAC256 -Key $SDate -Data $Service
    $SSigning = HMAC256 -Key $SService -Data "tc3_request"
    $Signature = [System.BitConverter]::ToString((HMAC256 -Key $SSigning -Data $StringToSign)).Replace("-", "").ToLower()
    
    $Authorization = "$Algorithm Credential=$($config.SecretId)/$CredentialScope, SignedHeaders=$SignedHeaders, Signature=$Signature"
    
    # --- Output Debug Info ---
    Write-Host "`n--- [DEBUG INFO] ---" -ForegroundColor Yellow
    Write-Host "Action: $Action"
    Write-Host "Timestamp: $Timestamp"
    Write-Host "Date: $Date"
    Write-Host "CanonicalRequest:`n$CanonicalRequest" -ForegroundColor Gray
    Write-Host "`nStringToSign:`n$StringToSign" -ForegroundColor Gray
    Write-Host "`nAuthorization Header:`n$Authorization" -ForegroundColor Cyan
    Write-Host "-------------------`n"
    
    $HttpClient = New-Object System.Net.Http.HttpClient
    $Request = New-Object System.Net.Http.HttpRequestMessage
    $Request.Method = [System.Net.Http.HttpMethod]::Post
    $Request.RequestUri = "https://$HostName"
    
    $Request.Headers.TryAddWithoutValidation("Authorization", $Authorization) | Out-Null
    $Request.Headers.TryAddWithoutValidation("X-TC-Action", $Action) | Out-Null
    $Request.Headers.TryAddWithoutValidation("X-TC-Version", $Version) | Out-Null
    $Request.Headers.TryAddWithoutValidation("X-TC-Timestamp", $Timestamp.ToString()) | Out-Null
    
    # Ensure Content-Type matches CanonicalRequest EXACTLY
    $Content = New-Object System.Net.Http.StringContent($JsonPayload, [System.Text.Encoding]::UTF8, "application/json")
    $Request.Content = $Content
    
    $Resp = $HttpClient.SendAsync($Request).Result
    $Body = $Resp.Content.ReadAsStringAsync().Result
    $HttpClient.Dispose()
    
    Write-Host "HTTP Status: $($Resp.StatusCode)"
    Write-Host "Response Body:`n$Body" -ForegroundColor Green
}

# Run Debug
Invoke-TencentDebug -Action "DescribeDomainList" -Payload @{}
