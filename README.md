# EsptouchForHarmony

基于 EspTouch V2 协议的 HarmonyOS (ArkTS, API 12+) 应用，用于 ESP32/ESP8266 等乐鑫设备的 WiFi 智能配网。

[![HarmonyOS](https://img.shields.io/badge/HarmonyOS-API%2012%2B-blue)](https://developer.harmonyos.com)
[![SDK](https://img.shields.io/badge/SDK-6.0.0(20)-purple)](https://developer.harmonyos.com)
[![License](https://img.shields.io/badge/License-Apache--2.0-green)](LICENSE)

---

**1. app-smart-config-esptouch**:

![app-smart-config-esptouch.png](app-smart-config-esptouch.png)

**2.the esp32 device join wifi:**

![esp32-s3-join-wifi-successful](esp32-s3-join-wifi-successful.png)

## 概述

EsptouchForHarmony 是对 [EsptouchForAndroid](https://github.com/EspressifApp/EsptouchForAndroid) 的 HarmonyOS 实现，使用 ArkTS 语言开发，基于 `ESP-TOUCH V2` 协议，通过 UDP 广播方式将 WiFi 凭据（SSID 和密码）发送到 ESP32/ESP8266 设备，实现智能配网。

本应用同时包含**配网 HAR 库**和**示例 App**，可作为独立应用使用，也可将配网能力集成到其他 HarmonyOS 项目中。

### 技术原理

`ESP-TOUCH` 协议通过 Smart Config 技术实现配网。

#### 工作流程

ESPTouch 的核心思路是"旁路监听"：

```
             +----------+     (已连接)    +-------------+
             |  手机    | ◄───WiFi────►  | TP-Link 路由器 |
             +----------+                | (目标WiFi网络) |
                  │                      +-------------+
                  │ UDP广播                      │
                  │ (ESPTouch协议)                │
                  │ 数据编码在包长度中              │
                  ▼                               ▼
             +----------+                  连接成功后
             | ESP32    │ ───────────────► 也接入目标WiFi
             | (混杂模式)|   获得SSID+密码
             +----------+
```

1. **手机**已连接在目标 WiFi（作为 STA）
2. **ESP32** 未连接任何网络，打开射频芯片处于**混杂模式（promiscuous mode）**，监听空中的所有 802.11 无线帧
3. **手机**通过 UDP 广播发送数据包，SSID、密码、BSSID 等信息**编码在数据包的长度字段中**（而非包内容）
4. **ESP32** 抓取这些无线帧，解析包长度，还原出 WiFi 凭据
5. **ESP32 切换为 STA 模式**，用获取到的 SSID 和密码连接目标 WiFi

#### 为什么必须手动输入 WiFi 密码？

应用通过 `wifiManager.getLinkedInfo()` API 可以**自动获取**当前 WiFi 的 **SSID 和 BSSID**，但操作系统出于安全考虑，**不允许应用读取已保存的 WiFi 密码**（如果任何应用都能读取 WiFi 密码，恶意应用可窃取所有已保存凭据）。因此，密码必须由用户手动输入。

#### 两种配网模式

| 模式 | ESP32 角色 | 手机角色 | 密码来源 |
|------|-----------|---------|---------|
| **ESPTouch（Manual 标签页）** | 混杂模式（sniffer） | 目标 WiFi 的 STA | 用户手动输入 |
| **AP Provisioning（QR Scan 标签页）** | AP（热点，如 `esp32-s3-wifi`） | 连接 ESP32 的 AP | 扫描 WiFi 二维码自动解析 |

- **不支持 5 GHz 频段** — 请确保手机连接的是 2.4 GHz WiFi
- **不支持 802.11ac 协议**

---

## 项目结构

```
EsptouchForHarmony/
├── entry/                                        # 主应用模块 (entry HAP)
│   └── src/main/ets/
│       ├── entryability/                         # Ability 入口
│       ├── pages/                                # UI 页面
│       │   └── Index.ets                         # 主页面 (QR 扫描 + 手动配网)
│       └── esptouch/                             # EspTouch V2 核心库
│           ├── provision/                        # 配网核心逻辑
│           │   ├── IEspProvisioner.ets           # 配网器接口 + 协议常量
│           │   ├── EspProvisioner.ets            # 公开外观类
│           │   ├── EspProvisionerImpl.ets        # 核心实现 (UDP 收发)
│           │   ├── EspProvisioningRequest.ets    # 配网请求 + Builder
│           │   ├── EspProvisioningParams.ets     # 数据包生成算法
│           │   ├── EspProvisioningListener.ets   # 配网监听接口
│           │   ├── EspProvisioningResult.ets     # 配网结果
│           │   ├── EspSyncListener.ets           # 同步监听接口
│           │   ├── TouchAES.ets                  # AES-CBC 加密封装
│           │   ├── TouchCRC.ets                  # CRC8 校验
│           │   ├── TouchNetUtil.ets              # 网络工具函数
│           │   ├── TouchPacketUtils.ets          # 数据包构建
│           │   └── TouchPermissionException.ets  # 权限异常类
│           └── scan/                             # QR 码扫描
│               └── QRCodeParser.ets              # WiFi QR 码解析器
├── AppScope/                                     # 应用全局配置
├── build-profile.json5                            # 应用级构建配置
└── hvigor/                                       # Hvigor 构建配置
```

---

## 开发环境要求

| 项目 | 要求 |
|------|------|
| HarmonyOS SDK | API 12+ (SDK 6.0.0) |
| 应用模型 | Stage 模型 |
| IDE | DevEco Studio 5.0+ |
| 构建工具 | Hvigor |

---

## 权限声明

应用需要以下权限（已在 `module.json5` 中声明）：

| 权限 | 用途 |
|------|------|
| `ohos.permission.INTERNET` | UDP 网络通信 |
| `ohos.permission.GET_WIFI_INFO` | 读取当前 WiFi 的 SSID/BSSID/IP |
| `ohos.permission.CAMERA` | 扫描 WiFi QR 码（运行时申请） |
| `ohos.permission.GET_NETWORK_INFO` | 获取网络状态信息 |

---

## 功能特性

### 双模式配网

| 特性 | ESPTouch 模式 (Manual) | AP 配网模式 (QR Scan) |
|------|----------------------|----------------------|
| 协议 | ESP-TOUCH V2 Smart Config（UDP 广播） | AP 热点模式（TCP 直连） |
| 密码来源 | 用户手动输入 | 扫描 WiFi QR 码自动解析 |
| 设备状态 | 混杂模式嗅探 | 开启 AP 热点（如 `esp32-s3-wifi`） |
| 数据通道 | UDP 端口 7001/7002/18266+ | TCP 192.168.4.1:8080 |
| 适用场景 | 已知 WiFi 密码 | 有 WiFi QR 码 |
| 加密支持 | AES-CBC（Security V1/V2） | JSON 明文 + TCP |

### ESPTouch V2 配网（Manual 标签页）

- **同步阶段 (Sync)**: 广播 1048 字节空同步包，让设备发现配网器
- **配网阶段 (Provision)**:
  - 构建包含 SSID、密码、BSSID、自定义数据的头包 + 数据包
  - 支持 AES-CBC 加密（Security V1: 全零 IV；Security V2: 20 字节随机 IV）
  - CRC8 校验（poly=0x8c）保证数据完整性
  - 数据包按 15ms 间隔发送，45 秒后切换为 100ms，总超时 90 秒
  - 收到设备响应后发送 ACK 确认包
  - 多端口尝试绑定（18266/28266/38266/48266），端口索引编码到 flag
- **设备状态监听**: UDP 7001 端口监听设备 WiFi 连接状态（IP/MAC/SSID/失败原因）
- **多设备支持**: 通过 BSSID 去重，每发现一个新设备触发 `onResponse` 回调
- **可选 AES 密钥**: 支持 16 字节自定义 AES 密钥输入

### AP 配网（QR Scan 标签页）

- **QR 码扫描**: 基于系统 ScanKit 解析标准 WiFi QR 码（`WIFI:T:WPA;S:SSID;P:PWD;;`）
- **AP 连接引导**: 提示用户连接 ESP32 AP 热点，自动检测连接状态
- **TCP 凭据传输**: JSON 协议发送 `{cmd, ssid, password, auth}` 到 ESP32
- **Keepalive 保活**: 每 10 秒发送 `{cmd: "ping"}` 维持 TCP 连接
- **自动回连检测**: 配网完成后引导并检测用户重新连接目标 WiFi
- **阶段可视化**: 实时展示 6 个配网阶段（WAITING_AP → CONNECTING_TCP → SENDING_CREDS → WAITING_CONFIRM → RECONNECTING → DONE）

### 通用功能

| 功能 | 说明 |
|------|------|
| **WiFi 信息自动获取** | 通过 `wifiManager.getLinkedInfo()` 自动读取当前 SSID/BSSID/IP，免去手动输入 |
| **设备管理** | 查看已配网设备列表，显示 BSSID 和 IP 地址 |
| **连接测试** | 对已配网设备进行 TCP 端口扫描（80/8080/443），验证设备可达性 |
| **复制 IP** | 一键复制设备 IP 地址到剪贴板 |
| **实时日志面板** | 终端风格日志输出，带时间戳，支持一键复制和清空 |
| **相机权限管理** | 运行时动态申请相机权限，扫描完成后自动释放相机 |

---

## 构建与运行

### 通过 DevEco Studio

1. 用 DevEco Studio 打开项目根目录
2. 等待项目同步完成
3. 连接 HarmonyOS 设备或启动模拟器
4. 点击 `Run` 按钮运行

### 通过命令行

```bash
# 构建 HAP
hvigorw assembleHap

# 构建 HAR（库模式）
hvigorw --mode module -p module=entry@default assembleHar
```

---

## 使用说明

### QR 码扫描配网

1. 启动应用，默认进入 **QR Scan** 标签页
2. 点击 `Start Camera` 开启相机
3. 将标准 WiFi QR 码对准扫描框
4. 确认扫描到的 WiFi 信息
5. 点击 `Provision` 开始配网
6. 等待设备响应

### 手动配网

1. 切换到 **Manual** 标签页
2. 查看当前连接的 WiFi 信息
3. 点击 `Start Sync` 广播同步包，发现设备
4. 在设备列表中选择目标设备
5. 输入 WiFi 密码（可选 AES 密钥和 Security V2）
6. 点击 `Start Provision` 开始配网

---

## HAR 库集成

如需将配网能力集成到其他 HarmonyOS 项目，可直接引用 `entry` 模块中的 `esptouch/` 源码：

```typescript
import { EspProvisioner } from '../esptouch/provision/EspProvisioner';
import { EspProvisioningRequestBuilder } from '../esptouch/provision/EspProvisioningRequest';

let provisioner = new EspProvisioner();
let request = await new EspProvisioningRequestBuilder()
  .setPassword(new util.TextEncoder().encode('wifi-password'))
  .build();

provisioner.startProvisioning(request, {
  onStart: () => {},
  onResponse: (result) => { console.log(`Device: ${result.bssid}`); },
  onStop: () => {},
  onError: (err) => { console.error(err.message); }
});
```

---

## 常见问题

**Q: 配网器没有发现设备？**
A: 确保 ESP32 已运行 EspTouch V2 固件且处于 Smart Config 模式；确保手机连接的是 2.4 GHz WiFi；检查防火墙是否阻挡了 UDP 7001/7002 端口。

**Q: 配网 90 秒超时后会怎样？**
A: 配网会自动停止，并触发 `onStop` 回调。

**Q: 支持同时发现多个设备吗？**
A: 支持。`onResponse` 回调会对每个不重复的设备 BSSID 触发一次。

**Q: 配网完成后如何测试设备连接？**
A: 在设备列表中点击设备旁的 `Actions` 按钮，选择 `Test Connection`，应用会尝试 TCP 连接设备的 80/8080/443 端口。

---

## 致谢

- [EsptouchForAndroid](https://github.com/EspressifApp/EsptouchForAndroid) — 原始 Android 版 EspTouch 库和应用
- [ESP-IDF Smart Config](https://github.com/espressif/esp-idf/tree/master/examples/wifi/smart_config) — ESP32 端 Smart Config 示例
