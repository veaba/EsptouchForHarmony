# 在 Windows 上模拟 EspTouch 配网

本文档介绍如何在 Windows 上使用 PowerShell 脚本模拟 EspTouch 协议，通过 UDP 数据包对 ESP 设备进行配网，无需使用 Android 手机。

## 概述

EspTouch 协议工作原理：

```
┌─────────────┐       UDP (广播/组播)        ┌─────────────┐
│   手机/PC    │  ──────────────────────>   │  ESP 设备   │
│  (发送方)   │   SSID + Password 编码在    │  (接收方)   │
│             │   数据包长度字段中          │             │
└─────────────┘                              └─────────────┘
       │                                         │
       │         UDP (单播)                      │
│     <───────────────────────────────────────────│
│              设备返回 IP 和 BSSID               │
```

### 协议流程

1. **Guide Code（引导码）**：发送 4 个数据报（512, 513, 514, 515），用于唤醒设备
2. **Datum Code（数据码）**：循环发送包含 SSID、密码、BSSID、本机 IP 的数据包
3. **设备响应**：设备配网成功后，通过 UDP 单播返回自己的 BSSID 和 IP

### 数据包格式

| 字段 | 长度 | 说明 |
|------|------|------|
| DA | 6 | 目标 MAC（全 FF） |
| SA | 6 | 源 MAC |
| Length | 2 | 编码后的 SSID 和密钥 |
| DATA | 变长 | 载荷 |

## 使用方法

### 前提条件

- Windows PowerShell 5.0+
- 网络连接到 2.4 GHz Wi-Fi（EspTouch 不支持 5 GHz）
- 获取路由器和 ESP 设备的 BSSID

### 获取 BSSID

**路由器 BSSID**：
```powershell
netsh wlan show interfaces
```

**ESP 设备 BSSID**：查看设备文档或使用 EspTouch App 获取

### 运行脚本

```powershell
# 基本用法
.\Esptouch-Windows-Simulator.ps1 -SSID "YourRouterSSID" -Password "YourPassword" -BSSID "AA:BB:CC:DD:EE:FF"

# 无密码网络
.\Esptouch-Windows-Simulator.ps1 -SSID "OpenNetwork" -Password "" -BSSID "AA:BB:CC:DD:EE:FF"

# 组播模式
.\Esptouch-Windows-Simulator.ps1 -SSID "YourSSID" -Password "YourPassword" -BSSID "AA:BB:CC:DD:EE:FF" -Broadcast:$false

# 自定义超时和设备数量
.\Esptouch-Windows-Simulator.ps1 -SSID "YourSSID" -Password "YourPassword" -BSSID "AA:BB:CC:DD:EE:FF" -TimeoutSeconds 60 -DeviceCount 3
```

### 参数说明

| 参数 | 必需 | 默认值 | 说明 |
|------|------|--------|------|
| SSID | 是 | - | 目标 Wi-Fi 网络名称 |
| Password | 否 | "" | Wi-Fi 密码（开放网络留空） |
| BSSID | 是 | - | 目标路由器 MAC 地址（格式：XX:XX:XX:XX:XX:XX） |
| DeviceCount | 否 | 1 | 预期配网设备数量 |
| Broadcast | 否 | $true | $true=广播模式, $false=组播模式 |
| TimeoutSeconds | 否 | 45 | 最大配网超时时间（秒） |

## 协议常量

| 常量 | 值 | 说明 |
|------|-----|------|
| TARGET_PORT | 7001 | 设备监听端口 |
| LISTEN_PORT | 18266 | 本机监听端口 |
| GUIDE_CODE_INTERVAL_MS | 8 | 引导码发送间隔 |
| DATA_CODE_INTERVAL_MS | 8 | 数据码发送间隔 |
| GUIDE_CODES | 512, 513, 514, 515 | 引导码值 |

## DataCode 格式

每个 DataCode 为 6 字节：

```
Byte 0: 0x00
Byte 1: [CRC high 4bits] [Data high 4bits]
Byte 2: 0x01
Byte 3: Sequence header (index)
Byte 4: 0x00
Byte 5: [CRC low 4bits] [Data low 4bits]
```

编码规则：
- 每个字符（uint8）拆分为高 4 位和低 4 位
- CRC = CRC8(data & 0xFF, index)
- 一个字符用两个 DataCode 表示（9 bits x 2）

## DatumCode 数据顺序

```
[0] total_len          - 总长度
[1] password_len       - 密码长度
[2] ssid_crc           - SSID 的 CRC8
[3] bssid_crc          - BSSID 的 CRC8
[4] total_xor          - 所有数据 XOR
[5-8] ip_address      - 手机 IP（4 字节）
[9...] password       - 密码字节
[...] ssid            - SSID 字节
[最后] bssid          - BSSID（6 字节）
```

## 故障排除

### 常见问题

**1. 无法获取本地 IP**
```
[ERROR] 无法获取本地 IP 地址
```
解决：确保已连接到 Wi-Fi 网络

**2. 未收到设备响应**
```
[WARN] 未收到设备响应，配网可能失败
```
检查：
- 设备是否在范围内
- 设备是否已开启 Smart Config
- BSSID 是否正确
- 是否连接到正确的 Wi-Fi 网络

**3. 配网成功但无响应**
- 路由器可能开启了 AP 隔离
- 检查设备是否真正连接到目标网络

### 调试模式

如需查看详细发送过程，可以在脚本中添加调试输出：

```powershell
# 在 Send-UDPPacket 函数中添加
Write-Host "[DEBUG] Sent $($Data.Length) bytes to $TargetAddress`:$Port" -ForegroundColor DarkGray
```

## 与 Android 版本对比

| 功能 | Android | Windows 模拟器 |
|------|---------|---------------|
| Guide Code 发送 | 支持 | 支持 |
| Datum Code 发送 | 支持 | 支持 |
| 广播模式 | 支持 | 支持 |
| 组播模式 | 支持 | 支持 |
| 设备响应监听 | 支持 | 支持 |
| AES 加密 (V2) | 支持 | 不支持（V1） |

## 技术原理

参见 [esptouch-user-guide-cn.md](docs/esptouch-user-guide-cn.md)。

## 注意事项

1. **安全**：脚本不包含任何加密，密码以明文形式编码在 UDP 数据包中
2. **兼容性**：此脚本模拟 EspTouch V1 协议，不支持 EspTouch V2 的 AES 加密特性
3. **网络**：必须连接到 2.4 GHz Wi-Fi，EspTouch 不支持 5 GHz
4. **性能**：配网成功率受环境影响，建议设备与路由器距离不要太远

## 许可证

本项目基于 Espressif 协议实现，遵循原项目 [LICENSE](../LICENSE)。