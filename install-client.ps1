#Requires -RunAsAdministrator
$ErrorActionPreference = "Stop"

Clear-Host
Write-Host "=== CAI DAT CLIENT DNS PROXY ===" -ForegroundColor Cyan

# Lay danh sach card mang
$adapters = Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.254.*" } | ForEach-Object {
    $adapter = Get-NetAdapter -InterfaceIndex $_.InterfaceIndex -ErrorAction SilentlyContinue
    if ($adapter -and $adapter.Status -eq "Up") {
        [PSCustomObject]@{ IP = $_.IPAddress; Name = $adapter.Name }
    }
}

Write-Host "`nCard mang hien tai:" -ForegroundColor Yellow
foreach ($a in $adapters) { Write-Host " - $($a.Name) : $($a.IP)" }

Write-Host "`nNhap IP Server Linux (VD: 10.248.74.129): " -NoNewline
$ServerIP = Read-Host

Write-Host "Nhap IP Upstream DNS (VD: 10.30.95.34): " -NoNewline
$UpstreamDNS = Read-Host

$port = 53

Write-Host "`nDang tao script DNS Proxy..." -ForegroundColor Green

$proxyContent = @'
$ListenIP = "0.0.0.0"
$ListenPort = __PORT__
$TargetIP = "__UPSTREAM__"
$TargetPort = __PORT__
$LogFile = "C:\dns-proxy.log"

$udpBlock = {
    param($lip, $lport, $tip, $tport, $log)
    try {
        $listener = New-Object System.Net.Sockets.UdpClient
        $listener.Client.SetSocketOption([System.Net.Sockets.SocketOptionLevel]::Socket,[System.Net.Sockets.SocketOptionName]::ReuseAddress, $true)
        $listener.Client.Bind((New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse($lip), $lport)))
    } catch { return }
    while ($true) {
        try {
            $remoteEP = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
            $data = $listener.Receive([ref]$remoteEP)
            $up = New-Object System.Net.Sockets.UdpClient
            $up.Client.ReceiveTimeout = 5000
            $up.Send($data, $data.Length, (New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse($tip), $tport))) | Out-Null
            try {
                $resp = $up.Receive([ref]$remoteEP)
                $listener.Send($resp, $resp.Length, $remoteEP) | Out-Null
            } catch {} finally { $up.Close() }
        } catch { Start-Sleep -Milliseconds 10 }
    }
}

$tcpBlock = {
    param($lip, $lport, $tip, $tport, $log)
    try {
        $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Parse($lip), $lport)
        $listener.Start()
    } catch { return }
    while ($true) {
        try {
            $client = $listener.AcceptTcpClient()
            $cs = $client.GetStream()
            $up = New-Object System.Net.Sockets.TcpClient
            $up.Connect($tip, $tport)
            $us = $up.GetStream()
            $b1 = New-Object byte[] 8192; $b2 = New-Object byte[] 8192
            $t1 = $cs.ReadAsync($b1, 0, $b1.Length); $t2 = $us.ReadAsync($b2, 0, $b2.Length)
            while ($true) {
                $idx = [System.Threading.Tasks.Task]::WaitAny(@($t1, $t2), 60000)
                if ($idx -eq -1) { break }
                if ($idx -eq 0) {
                    $n = $t1.Result; if ($n -eq 0) { break }
                    $us.Write($b1, 0, $n); $us.Flush(); $t1 = $cs.ReadAsync($b1, 0, $b1.Length)
                } else {
                    $n = $t2.Result; if ($n -eq 0) { break }
                    $cs.Write($b2, 0, $n); $cs.Flush(); $t2 = $us.ReadAsync($b2, 0, $b2.Length)
                }
            }
            $up.Close(); $client.Close()
        } catch { Start-Sleep -Milliseconds 10 }
    }
}

$tcpRunspace = [runspacefactory]::CreateRunspace($Host); $tcpRunspace.Open()
$tcpPS = [powershell]::Create(); $tcpPS.Runspace = $tcpRunspace
$tcpPS.AddScript($tcpBlock).AddArgument($ListenIP).AddArgument($ListenPort).AddArgument($TargetIP).AddArgument($TargetPort).AddArgument($LogFile) | Out-Null
$tcpPS.BeginInvoke() | Out-Null

& $udpBlock $ListenIP $ListenPort $TargetIP $TargetPort $LogFile
'@

$proxyContent = $proxyContent -replace '__PORT__', $port -replace '__UPSTREAM__', $UpstreamDNS
$ProxyScript = "C:\dns-proxy.ps1"
[System.IO.File]::WriteAllText($ProxyScript, $proxyContent, [System.Text.UTF8Encoding]::new($true))

# Firewall
Remove-NetFirewallRule -DisplayName "DNS-Proxy-*" -ErrorAction SilentlyContinue
New-NetFirewallRule -DisplayName "DNS-Proxy-UDP" -Direction Inbound -Protocol UDP -LocalPort $port -RemoteAddress $ServerIP -Action Allow | Out-Null
New-NetFirewallRule -DisplayName "DNS-Proxy-TCP" -Direction Inbound -Protocol TCP -LocalPort $port -RemoteAddress $ServerIP -Action Allow | Out-Null

# Scheduled Task
$TaskName = "DNS-Proxy-Relay"
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$ProxyScript`""
$trigger = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)

Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings | Out-Null

Start-ScheduledTask -TaskName $TaskName
Start-Sleep -Seconds 3

Write-Host "`n[OK] Da tao file $ProxyScript" -ForegroundColor Green
Write-Host "[OK] Da mo Firewall cho IP $ServerIP" -ForegroundColor Green
Write-Host "[OK] Da tao va khoi dong Task '$TaskName'" -ForegroundColor Green
Write-Host "`nHoan tat! Nhan Enter de thoat..." -ForegroundColor Cyan
Read-Host