# Cloudflare SpeedTest Auto-Pilot (Pure Logic Edition)
param (
    [switch]$Speedtest, # 仅测速
    [switch]$SyncDNS    # 仅同步
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Net.Http
$scriptPath = split-path -parent $MyInvocation.MyCommand.Definition
Set-Location $scriptPath

# --- 初始化全局资源 ---
if ($null -eq $global:TencentHttpClient) {
    $global:TencentHttpClient = New-Object System.Net.Http.HttpClient
}

function HMAC256 {
    param([byte[]]$Key, [string]$Data)
    $hmac = New-Object System.Security.Cryptography.HMACSHA256; $hmac.Key = $Key
    return $hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Data))
}

# --- 加载配置 ---
$configPath = "$scriptPath\config.json"
$config = Get-Content $configPath -Raw -Encoding utf8 | ConvertFrom-Json

$targetUrl = "https://speed.cloudflare.com/__down?bytes=100000000"
$cfst = "core\cfst.exe"
$ipList = "core\ip.txt"
$outputCsv = "results_speedtest.csv"
$reportMd = "SPEEDTEST_REPORT.md"
$syncLogs = New-Object System.Collections.Generic.List[string]

$doSpeedtest = $Speedtest -or ((-not $Speedtest) -and (-not $SyncDNS))
$doSync = $SyncDNS -or ((-not $Speedtest) -and (-not $SyncDNS))

# --- 腾讯云 API 引擎 ---
function Invoke-TencentApi {
    param ([string]$Action, [object]$Payload)
    $Service = "dnspod"; $Version = "2021-03-23"; $HostName = "dnspod.tencentcloudapi.com"
    $Algorithm = "TC3-HMAC-SHA256"
    $Timestamp = [long][double]::Parse((Get-Date (Get-Date).ToUniversalTime() -UFormat %s))
    $Date = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd")
    $JsonPayload = $Payload | ConvertTo-Json -Compress
    
    $SignedHeaders = "content-type;host"
    $ContentType = "application/json; charset=utf-8"
    $HashedPayload = [System.BitConverter]::ToString((New-Object System.Security.Cryptography.SHA256Managed).ComputeHash([System.Text.Encoding]::UTF8.GetBytes($JsonPayload))).Replace("-", "").ToLower()
    $CanonicalHeaders = "content-type:$ContentType`nhost:$HostName`n"
    $CanonicalRequest = "POST`n/`n`n$CanonicalHeaders`n$SignedHeaders`n$HashedPayload"
    $HashedCanonicalRequest = [System.BitConverter]::ToString((New-Object System.Security.Cryptography.SHA256Managed).ComputeHash([System.Text.Encoding]::UTF8.GetBytes($CanonicalRequest))).Replace("-", "").ToLower()
    $CredentialScope = "$Date/$Service/tc3_request"
    $StringToSign = "$Algorithm`n$Timestamp`n$CredentialScope`n$HashedCanonicalRequest"
    
    $SDate = HMAC256 -Key ([System.Text.Encoding]::UTF8.GetBytes("TC3" + $config.SecretKey)) -Data $Date
    $SService = HMAC256 -Key $SDate -Data $Service
    $SSigning = HMAC256 -Key $SService -Data "tc3_request"
    $Signature = [System.BitConverter]::ToString((HMAC256 -Key $SSigning -Data $StringToSign)).Replace("-", "").ToLower()
    $Authorization = "$Algorithm Credential=$($config.SecretId)/$CredentialScope, SignedHeaders=$SignedHeaders, Signature=$Signature"
    
    $Request = New-Object System.Net.Http.HttpRequestMessage -Property @{Method=[System.Net.Http.HttpMethod]::Post; RequestUri="https://$HostName"}
    $Request.Headers.TryAddWithoutValidation("Authorization", $Authorization) | Out-Null
    $Request.Headers.TryAddWithoutValidation("X-TC-Action", $Action) | Out-Null
    $Request.Headers.TryAddWithoutValidation("X-TC-Version", $Version) | Out-Null
    $Request.Headers.TryAddWithoutValidation("X-TC-Timestamp", $Timestamp.ToString()) | Out-Null
    $Request.Content = New-Object System.Net.Http.StringContent($JsonPayload, [System.Text.Encoding]::UTF8, "application/json")
    
    $Task = $global:TencentHttpClient.SendAsync($Request); $Task.Wait()
    $ResponseBody = $Task.Result.Content.ReadAsStringAsync().Result
    
    $Result = $ResponseBody | ConvertFrom-Json
    
    if ($null -ne $Result.Response.Error) { 
        throw $Result.Response.Error.Message
    }
    return $Result.Response
}

function Run-Speedtest {
    Write-Host ">>> [1/3] Speedtest Running..." -ForegroundColor Cyan
    Remove-Item $outputCsv -ErrorAction SilentlyContinue
    $args = "-f core\ip.txt -url $targetUrl -httping -n $($config.Threads) -dn $($config.DownloadCount) -tl $($config.LatencyLimit) -o $outputCsv -p 0"
    Start-Process -FilePath $cfst -ArgumentList $args -Wait -NoNewWindow
}

function Run-Sync {
    Write-Host ">>> [2/3] DNS Syncing..." -ForegroundColor Cyan
    if (-Not (Test-Path $outputCsv)) { throw "CSV missing." }
    $csv = Get-Content $outputCsv -Encoding Default
    $all = New-Object System.Collections.Generic.List[PSObject]
    for($i=1; $i -lt $csv.Count; $i++){
        $p = $csv[$i].Split(','); if($p.Count -lt 7){continue}
        $all.Add([PSCustomObject]@{ IP=$p[0]; Latency=[double]$p[4]; Speed=[double]$p[5]; Colo=$p[6] })
    }
    
    $bestIps = $all | Sort-Object @{Expression="Speed"; Descending=$true}, @{Expression="Latency"; Ascending=$true} | Select-Object -First $config.DownloadCount -ExpandProperty IP
    
    # [安全锁] 如果测速结果为空，严禁进入同步流程，防止误删线上记录
    if ($null -eq $bestIps -or $bestIps.Count -eq 0) {
        throw "No valid IPs found during speedtest. Aborting sync to protect existing DNS records."
    }

    $subdomains = if ($config.SubDomain -is [System.Array]) { $config.SubDomain } else { @($config.SubDomain) }

    foreach ($sub in $subdomains) {
        try {
            Write-Host ">>> Processing Subdomain: $sub" -ForegroundColor Yellow
            # 获取当前所有解析记录（仅查一次）
            $resp = Invoke-TencentApi -Action "DescribeRecordList" -Payload @{Domain=$config.Domain; Subdomain=$sub}
            $onlineRecords = if ($null -eq $resp.RecordList) { @() } else { $resp.RecordList }
            
            $validOnline = New-Object System.Collections.Generic.HashSet[string]

            # 阶段 1: 清理无效记录并统计有效记录
            foreach ($r in $onlineRecords) {
                $isCorrectType = ($r.Type -eq "A")
                $isBestIp = ($bestIps -contains $r.Value)
                $isConfiguredLine = ($config.Lines -contains $r.Line)

                if (-not ($isCorrectType -and $isBestIp -and $isConfiguredLine)) {
                    Invoke-TencentApi -Action "DeleteRecord" -Payload @{Domain=$config.Domain; RecordId=$r.RecordId} | Out-Null
                    $syncLogs.Add("[-] ($sub) Deleted ($($r.Line)): $($r.Value)")
                    Start-Sleep -Milliseconds 300
                } else {
                    # 记录依然有效的 (线路+IP) 组合
                    $validOnline.Add("$($r.Line)_$($r.Value)") | Out-Null
                }
            }

            # 阶段 2: 填充缺失记录
            foreach ($line in $config.Lines) {
                foreach ($ip in $bestIps) {
                    $key = "${line}_$ip"
                    if (-not $validOnline.Contains($key)) {
                        Invoke-TencentApi -Action "CreateRecord" -Payload @{Domain=$config.Domain; SubDomain=$sub; RecordType="A"; RecordLine=$line; Value=$ip} | Out-Null
                        $syncLogs.Add("[+] ($sub) Added ($line): $ip")
                        Start-Sleep -Milliseconds 300
                    }
                }
            }
        } catch {
            $errMsg = "Error syncing $sub: $($_.Exception.Message)"
            Write-Warning $errMsg
            $syncLogs.Add("[!] ($sub) Sync FAILED: $($_.Exception.Message)")
            continue # 错误隔离：一个子域名失败不影响其他子域名
        }
    }
}

function Run-Report {
    Write-Host ">>> [3/3] Generating Report..." -ForegroundColor Cyan
    if (-Not (Test-Path $outputCsv)) { return }
    $csv = Get-Content $outputCsv -Encoding Default
    $all = New-Object System.Collections.Generic.List[PSObject]
    for($i=1; $i -lt $csv.Count; $i++){
        $p = $csv[$i].Split(','); if($p.Count -lt 7){continue}
        $all.Add([PSCustomObject]@{ IP=$p[0]; Latency=[double]$p[4]; Speed=[double]$p[5]; Colo=$p[6] })
    }
    $top5 = $all | Sort-Object @{Expression="Speed"; Descending=$true}, @{Expression="Latency"; Ascending=$true} | Select-Object -First 5
    $report = "# Cloudflare Optimization Report`n> Generated: $(Get-Date)`n`n## Top 5 Optimized IPs`n| Rank | IP | Latency | Speed | Region |`n| :--- | :--- | :--- | :--- | :--- |`n"
    $idx=1; foreach($r in $top5){ $report += "| $idx | **$($r.IP)** | $($r.Latency) | $($r.Speed) | $($r.Colo) |`n"; $idx++ }
    if ($syncLogs.Count -gt 0) { $report += "`n## Sync Log`n" + "````n" + ($syncLogs -join "`n") + "`n````n" }
    $report | Out-File $reportMd -Encoding utf8
    $top5 | Format-Table -AutoSize
}

try {
    if ($doSpeedtest) { Run-Speedtest }
    if ($doSync) { Run-Sync }
} finally {
    Run-Report
}
