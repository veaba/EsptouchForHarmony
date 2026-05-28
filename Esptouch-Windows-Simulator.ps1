# EspTouch V1 Protocol Simulator for Windows
# 在 Windows 上模拟 Android EspTouch 库发送配网 UDP 数据包
# 无需 Android 手机即可对 ESP 设备进行配网

param(
    [Parameter(Mandatory=$true)]
    [string]$SSID,

    [Parameter(Mandatory=$false)]
    [string]$Password = "",

    [Parameter(Mandatory=$true)]
    [string]$BSSID,

    [Parameter(Mandatory=$false)]
    [int]$DeviceCount = 1,

    [Parameter(Mandatory=$false)]
    [switch]$Broadcast = $true,

    [Parameter(Mandatory=$false)]
    [int]$TimeoutSeconds = 45
)

# 协议常量
$TARGET_PORT = 7001
$LISTEN_PORT = 18266
$GUIDE_CODE_INTERVAL_MS = 8
$DATA_CODE_INTERVAL_MS = 8

# CRC8 Table
$CrcTable = New-Object byte[] 256
$CRC_POLYNOM = 0x8c
$CRC_INITIAL = 0x00

for ($dividend = 0; $dividend -lt 256; $dividend++) {
    $remainder = $dividend
    for ($bit = 0; $bit -lt 8; $bit++) {
        if (($remainder -band 0x01) -ne 0) {
            $remainder = ($remainder -shr 1) -bxor $CRC_POLYNOM
        } else {
            $remainder = $remainder -shr 1
        }
    }
    $CrcTable[$dividend] = $remainder
}

function Calculate-Crc8 {
    param([byte[]]$Data)
    $value = $CRC_INITIAL
    foreach ($b in $Data) {
        $data = $b -bxor $value
        $value = $CrcTable[$data -band 0xff] -bxor ($value -shl 8)
    }
    return ($value -band 0xff)
}

function Parse-Bssid {
    param([string]$BssidStr)
    $parts = $BssidStr -split ':'
    if ($parts.Count -ne 6) {
        throw "BSSID 格式错误，应该是 XX:XX:XX:XX:XX:XX"
    }
    $bytes = New-Object byte[] 6
    for ($i = 0; $i -lt 6; $i++) {
        $bytes[$i] = [byte]::Parse($parts[$i], 'HexNumber')
    }
    return $bytes
}

function Get-LocalIPAddress {
    $localIP = (Get-NetIPAddress -InterfaceAlias "Wi-Fi" -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Select-Object -First 1).IPAddress
    if (-not $localIP) {
        $localIP = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.InterfaceAlias -notmatch "Loopback" } |
            Select-Object -First 1).IPAddress
    }
    return $localIP
}

function Split-Uint8To2Bytes {
    param([int]$Value)
    $high = [Math]::Floor($Value / 16)
    $low = $Value % 16
    return @($high, $low)
}

function Combine-2BytesToOne {
    param([byte]$High, [byte]$Low)
    if ($High -gt 0xf -or $Low -gt 0xf) {
        throw "Invalid nibble values"
    }
    return ($High -shl 4) -bor $Low
}

function New-DataCode {
    param([int]$CharValue, [int]$Index)
    $u8 = $CharValue -band 0xFF
    $crc = Calculate-Crc8 @([byte]$u8, [byte]$Index)

    $dataHigh, $dataLow = Split-Uint8To2Bytes $u8
    $crcHigh, $crcLow = Split-Uint8To2Bytes $crc

    $dataCode = New-Object byte[] 6
    $dataCode[0] = 0x00
    $dataCode[1] = Combine-2BytesToOne $crcHigh $dataHigh
    $dataCode[2] = 0x01
    $dataCode[3] = [byte]$Index
    $dataCode[4] = 0x00
    $dataCode[5] = Combine-2BytesToOne $crcLow $dataLow

    return $dataCode
}

function New-GuideCode {
    $gcBytes = @()
    foreach ($code in @(512, 513, 514, 515)) {
        $dc = New-DataCode -CharValue $code -Index 0
        $gcBytes += ,@($dc)
    }
    return $gcBytes
}

function New-DatumCode {
    param([byte[]]$ApSsid, [byte[]]$ApBssid, [byte[]]$ApPassword, [byte[]]$IpAddress)

    $EXTRA_HEAD_LEN = 5
    $apPwdLen = $ApPassword.Length
    $apSsidLen = $ApSsid.Length
    $ipLen = $IpAddress.Length

    $ssidCrc = Calculate-Crc8 $ApSsid
    $bssidCrc = Calculate-Crc8 $ApBssid
    $totalLen = $EXTRA_HEAD_LEN + $ipLen + $apPwdLen + $apSsidLen

    $dataList = New-Object System.Collections.ArrayList

    [void]$dataList.Add(@($totalLen, 0))
    [void]$dataList.Add(@($apPwdLen, 1))
    [void]$dataList.Add(@($ssidCrc, 2))
    [void]$dataList.Add(@($bssidCrc, 3))
    [void]$dataList.Add(@(0, 4))

    for ($i = 0; $i -lt $ipLen; $i++) {
        [void]$dataList.Add(@($IpAddress[$i], $i + $EXTRA_HEAD_LEN))
    }

    for ($i = 0; $i -lt $ApPassword.Length; $i++) {
        [void]$dataList.Add(@($ApPassword[$i], $i + $EXTRA_HEAD_LEN + $ipLen))
    }

    for ($i = 0; $i -lt $ApSsid.Length; $i++) {
        [void]$dataList.Add(@($ApSsid[$i], $i + $EXTRA_HEAD_LEN + $ipLen + $apPwdLen))
    }

    $totalXor = 0
    for ($i = 0; $i -lt $dataList.Count; $i++) {
        if ($i -ne 4) {
            $totalXor = $totalXor -bxor $dataList[$i][0]
        }
    }
    $dataList[4] = @($totalXor, 4)

    for ($i = 0; $i -lt $ApBssid.Length; $i++) {
        $index = $totalLen + $i
        [void]$dataList.Add(@($ApBssid[$i], $index))
    }

    $dcBytes2 = @()
    foreach ($item in $dataList) {
        $charVal = $item[0]
        $index = $item[1]
        $dc = New-DataCode -CharValue $charVal -Index $index
        $dcBytes2 += ,@($dc)
    }

    return $dcBytes2
}

function Send-UDPPacket {
    param([byte[]]$Data, [string]$TargetAddress, [int]$Port)
    try {
        $udpClient = New-Object System.Net.Sockets.UdpClient
        $target = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse($TargetAddress), $Port)
        $udpClient.Send($Data, $Data.Length, $target) | Out-Null
        $udpClient.Close()
        return $true
    } catch {
        return $false
    }
}

function Start-ListenForResponse {
    param([int]$Port, [int]$TimeoutMs)
    try {
        $udpServer = New-Object System.Net.Sockets.UdpClient($Port)
        $udpServer.Client.ReceiveTimeout = $TimeoutMs

        Write-Host "[INFO] 监听端口 $Port，等待设备响应..." -ForegroundColor Cyan

        $startTime = Get-Date
        while (((Get-Date) - $startTime).TotalMilliseconds -lt $TimeoutMs) {
            try {
                $remoteEP = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
                $receiveData = $udpServer.Receive([ref]$remoteEP)

                if ($receiveData -and $receiveData.Length -gt 0) {
                    $bssid = ""
                    for ($i = 0; $i -lt 6 -and $i -lt $receiveData.Length; $i++) {
                        $bssid += $receiveData[$i].ToString("X2")
                        if ($i -lt 5) { $bssid += ":" }
                    }

                    $ip = ""
                    if ($receiveData.Length -ge 10) {
                        for ($i = 6; $i -lt 10; $i++) {
                            $ip += $receiveData[$i].ToString()
                            if ($i -lt 9) { $ip += "." }
                        }
                    }

                    Write-Host "[SUCCESS] 设备配网成功！" -ForegroundColor Green
                    Write-Host "  BSSID: $bssid" -ForegroundColor Green
                    Write-Host "  IP: $ip" -ForegroundColor Green

                    $udpServer.Close()
                    return $true
                }
            } catch [System.Net.Sockets.SocketException] {
                if ($_.Exception.SocketErrorCode -eq "TimedOut") {
                    continue
                }
            }
        }

        $udpServer.Close()
        Write-Host "[INFO] 监听超时，未收到响应" -ForegroundColor Yellow
        return $false

    } catch {
        Write-Host "[ERROR] 监听失败: $_" -ForegroundColor Red
        return $false
    }
}

# 主程序
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  EspTouch V1 Protocol Simulator" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

$bssidBytes = Parse-Bssid $BSSID
$localIP = Get-LocalIPAddress

if (-not $localIP) {
    Write-Host "[ERROR] 无法获取本地 IP 地址" -ForegroundColor Red
    exit 1
}
$ipBytes = [System.Net.IPAddress]::Parse($localIP).GetAddressBytes()

Write-Host "[CONFIG]" -ForegroundColor Yellow
Write-Host "  SSID: $SSID"
Write-Host "  BSSID: $BSSID"
Write-Host "  Password: $($Password.Length > 0 ? '******' : '(empty)')"
Write-Host "  Local IP: $localIP"
Write-Host "  Device Count: $DeviceCount"
Write-Host "  Mode: $(if ($Broadcast) { 'Broadcast' } else { 'Multicast' })"
Write-Host "  Timeout: $TimeoutSeconds seconds"
Write-Host ""

$ssidBytes = [System.Text.Encoding]::UTF8.GetBytes($SSID)
$pwdBytes = [System.Text.Encoding]::UTF8.GetBytes($Password)

Write-Host "[INFO] 生成协议数据..." -ForegroundColor Cyan
$gcBytes2 = New-GuideCode
$dcBytes2 = New-DatumCode -ApSsid $ssidBytes -ApBssid $bssidBytes -ApPassword $pwdBytes -IpAddress $ipBytes

Write-Host "[INFO] Guide Code 数量: $($gcBytes2.Count)"
Write-Host "[INFO] Datum Code 数量: $($dcBytes2.Count)"
Write-Host ""

$targetAddress = if ($Broadcast) { "255.255.255.255" } else { "234.0.0.1" }

Write-Host "[INFO] 开始发送配网数据包..." -ForegroundColor Cyan
Write-Host "[INFO] 目标地址: $targetAddress`:$TARGET_PORT" -ForegroundColor Cyan

$startTime = Get-Date
$guideCodeSent = $false
$totalDataSent = 0

while (((Get-Date) - $startTime).TotalSeconds -lt $TimeoutSeconds) {

    if (-not $guideCodeSent) {
        Write-Host "[PHASE 1] 发送 Guide Code..." -ForegroundColor Magenta
        for ($i = 0; $i -lt 4; $i++) {
            foreach ($dc in $gcBytes2) {
                Send-UDPPacket -Data $dc -TargetAddress $targetAddress -Port $TARGET_PORT | Out-Null
                $totalDataSent++
                Start-Sleep -Milliseconds $GUIDE_CODE_INTERVAL_MS
            }
        }
        $guideCodeSent = $true
        Write-Host "[PHASE 1] Guide Code 发送完成" -ForegroundColor Magenta
    }

    foreach ($dc in $dcBytes2) {
        Send-UDPPacket -Data $dc -TargetAddress $targetAddress -Port $TARGET_PORT | Out-Null
        $totalDataSent++
        Start-Sleep -Milliseconds $DATA_CODE_INTERVAL_MS

        if (((Get-Date) - $startTime).TotalSeconds -ge $TimeoutSeconds) {
            break
        }
    }

    if ($totalDataSent % 500 -eq 0) {
        $elapsed = [Math]::Round(((Get-Date) - $startTime).TotalSeconds)
        Write-Host "[PROGRESS] 已发送 $($totalDataSent) 个数据包... (${elapsed}s)" -ForegroundColor DarkGray
    }
}

Write-Host ""
Write-Host "[INFO] 数据发送完成，共发送 $($totalDataSent) 个数据包" -ForegroundColor Green
Write-Host "[INFO] 等待设备响应..." -ForegroundColor Cyan

$responseReceived = Start-ListenForResponse -Port $LISTEN_PORT -TimeoutMs 5000

if (-not $responseReceived) {
    Write-Host ""
    Write-Host "[WARN] 未收到设备响应，配网可能失败" -ForegroundColor Yellow
    Write-Host "[HINT] 请检查:" -ForegroundColor Yellow
    Write-Host "  1. 设备是否在范围内" -ForegroundColor Yellow
    Write-Host "  2. 设备是否已开启 Smart Config" -ForegroundColor Yellow
    Write-Host "  3. Wi-Fi 是否连接正常" -ForegroundColor Yellow
    Write-Host "  4. BSSID 是否正确" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "[COMPLETE] EspTouch 配网模拟结束" -ForegroundColor Cyan