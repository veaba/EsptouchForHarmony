# EspTouch V2 与 V1 协议对比

## 概述

EsptouchForAndroid 项目包含两套 SmartConfig 配网协议实现：`esptouch`（V1）和 `esptouch-v2`（V2）。V2 在编码方式、安全性、数据格式和 API 设计上均有较大改进。

## 1. 数据编码方式

| 维度 | V1 | V2 |
|------|----|----|
| 编码原理 | GuideCode + DataCode，每个 DataCode 用 3 个 9-bit 编码（control byte + CRC + data + sequence header） | 统一用 UDP 包长度编码数据，不同长度的包代表不同含义 |
| 同步包 | GuideCode（4 个固定 U8 值: 515, 514, 513, 512），通过 `ByteUtil.genSpecBytes()` 生成包体 | `getSyncPacket()` 生成固定 1048 字节长度的空包 |
| 序列大小包 | 无独立序列大小包 | `getSequenceSizePacket(size)` 包长 = 1072 + size - 1 |
| 序列包 | DataCode 中嵌入 sequence header 字段 | `getSequencePacket(sequence)` 包长 = 128 + sequence |
| 数据包 | 每字节拆成高低 4-bit + CRC，6 字节一组，3 个 9-bit 表示 | `getDataPacket(data, index)` 包长 = `(index << 7) \| (1 << 6) \| data`，6-bit 数据编码到包长中 |

### V1 编码细节

V1 的 `DataCode` 格式如下：

```
control byte | high 4 bits | low 4 bits
1st 9bits:     0x0            crc(high)     data(high)
2nd 9bits:     0x1            sequence header
3rd 9bits:     0x0            crc(low)      data(low)
```

每个 DataCode 长度为 6 字节 (`DATA_CODE_LEN = 6`)，index 最大为 127。

### V2 编码细节

V2 通过 UDP 包长度传递信息，数据被拆分为 6 字节一组，每组按位展开：

- 每组 6 字节数据展开为 7 或 8 个数据包（取决于是否需要携带 CRC）
- 每个数据包的长度编码了 6-bit 信息：5-bit 数据 + 1-bit 索引

## 2. 安全性

| 维度 | V1 | V2 |
|------|----|----|
| AES 模式 | **ECB** 模式 (`AES/ECB/PKCS5Padding`)，IV 为 null | **CBC** 模式 (`AES/CBC/PKCS5Padding`)，支持随机 IV |
| 安全版本 | 仅一种 | `SECURITY_V1`(1) 和 `SECURITY_V2`(2)，V2 额外生成 20 字节随机 AES IV |
| 加密范围 | 仅加密密码 | 密码 + reserved data 一起加密 |
| AES Key | 通过 `ITouchEncryptor` 接口注入 | Builder 模式设置，必须为 16 字节 |
| CRC 校验 | CRC8 | CRC8（多项式 0x8C，初始值 0x00），对 Head 和每个序列段分别校验 |

### V2 安全版本差异

- **SECURITY_V1**: AES CBC 模式，IV 为全零（16 字节）
- **SECURITY_V2**: AES CBC 模式，随机生成 20 字节 IV，随数据包一起发送

## 3. 协议数据格式

### V1 数据格式

```
totalLen(1B) + pwdLen(1B) + ssidCRC(1B) + bssidCRC(1B) + totalXOR(1B) + IP(4B) + password + ssid + bssid
```

- BSSID 数据按每 4 个位置穿插插入
- `EXTRA_HEAD_LEN = 5`，`EXTRA_LEN = 40`

### V2 数据格式

**Head（6 字节）：**

| 偏移 | 字段 | 说明 |
|------|------|------|
| 0 | ssidInfo | 低 7 位 = SSID 长度，bit7 = SSID 是否需要编码 |
| 1 | pwdInfo | 低 7 位 = 密码长度，bit7 = 密码是否需要编码 |
| 2 | reservedInfo | 低 7 位 = reserved 长度，bit7 = reserved 是否需要编码 |
| 3 | bssidCrc | BSSID 的 CRC8 校验值 |
| 4 | flag | bit0: IPv4/IPv6, bit1-2: 加密版本, bit3-4: App 端口标记, bit6-7: 协议版本 |
| 5 | headCrc | Head 前 5 字节的 CRC8 校验值 |

**完整数据流：**

```
Head(6B) + password + passwordPadding + reservedData + reservedPadding + aesIV(0或20B) + ssid + ssidPadding
```

### V2 新增 reserved data

V2 支持 `reservedData` 字段（最大 64 字节），允许 App 开发者携带自定义数据传递给设备。

## 4. 端口设计

| 维度 | V1 | V2 |
|------|----|----|
| 目标端口 | 单一端口（由 `IEsptouchTaskParameter` 配置） | `DEVICE_PORT = 7001` |
| ACK 端口 | 无独立 ACK 端口 | `DEVICE_ACK_PORT = 7002` |
| App 监听端口 | 单一端口 | `APP_PORTS = {18266, 28266, 38266, 48266}`，多端口尝试绑定 |
| 端口标记 | 无 | 绑定成功的端口索引编码到 Head 的 flag 中（bit3-4） |

## 5. 通信流程

### V1 流程

```
1. 生成 EsptouchGenerator（内含 GuideCode + DatumCode）
2. 循环发送：
   a. 发送 GuideCode（持续 timeoutGuideCode 毫秒）
   b. 发送 DataCode（逐段发送）
3. 同时异步监听 UDP 响应
4. 收到正确响应后验证 BSSID 和 IP
5. 累计足够的响应次数后返回结果
```

### V2 流程

```
1. startSync 阶段：持续发送 1048 字节同步包（间隔 100ms）
2. startProvisioning 阶段：
   a. 生成 EspProvisioningParams（包含完整数据包列表）
   b. 发送数据包（间隔 15ms，超时后半程改为 100ms）
   c. 同时监听设备响应（端口 APP_PORTS 之一）
3. 收到设备响应后：
   a. 解析 BSSID
   b. 发送 ACK 确认包到 DEVICE_ACK_PORT
4. 超时 90 秒后自动停止
```

## 6. API 设计

### V1 API

```java
// 同步阻塞式，必须在子线程调用
EsptouchTask task = new EsptouchTask(apSsid, apBssid, apPassword, context);
task.setPackageBroadcast(true);
task.setEsptouchListener(listener);
List<IEsptouchResult> results = task.executeForResults(expectResultCount);
task.interrupt(); // 取消
```

- 阻塞式调用，`executeForResults()` 返回后才得到结果
- 任务只能执行一次（`mIsExecuted` 检查）
- 通过 `IEsptouchTaskParameter` 配置超时、间隔等参数

### V2 API

```java
// 异步回调式
EspProvisioner provisioner = new EspProvisioner(context);

// 阶段 1：同步
provisioner.startSync(listener); // 可选
provisioner.stopSync();

// 阶段 2：配网
EspProvisioningRequest request = new EspProvisioningRequest.Builder(context)
    .setSSID(ssid)
    .setBSSID(bssid)
    .setPassword(password)
    .setReservedData(customData)    // V2 新增
    .setAESKey(aesKey)
    .setSecurityVer(securityVer)    // V2 新增
    .build();
provisioner.startProvisioning(request, listener);
provisioner.stopProvisioning();

provisioner.close(); // 释放资源
```

- 异步回调，通过 `EspProvisioningListener` 接收结果
- Sync 和 Provisioning 分离，可独立控制
- Builder 模式构建请求参数
- 支持 `Closeable` 接口，需手动关闭释放资源

## 7. 包结构对比

| 维度 | V1 | V2 |
|------|----|----|
| 包名 | `com.espressif.iot.esptouch` | `com.espressif.iot.esptouch2.provision` |
| 核心类 | `EsptouchTask` / `__EsptouchTask` | `EspProvisioner` / `EspProvisionerImpl` |
| 数据生成 | `EsptouchGenerator` + `DatumCode` + `DataCode` + `GuideCode` | `EspProvisioningParams` + `TouchPacketUtils` |
| 网络工具 | `UDPSocketClient` + `UDPSocketServer` | 直接使用 `DatagramSocket` |
| 加密 | `ITouchEncryptor` 接口 + `TouchAES` | `TouchAES`（内部类） |

## 8. 其他差异

| 维度 | V1 | V2 |
|------|----|----|
| IPv6 支持 | 仅 IPv4 | Head 的 flag bit0 标识 IPv4/IPv6 |
| 字符编码检测 | 无 | 自动检测数据是否包含非 ASCII 字符（`checkCharEncode`），影响 padding 因子（5 vs 6） |
| 数据填充 | 无随机填充 | 使用随机字节填充（padding），增强安全性 |
| 配网超时 | 由 `IEsptouchTaskParameter` 配置 | 固定 90 秒发送超时 + 2 秒接收超时 |
| 响应去重 | 通过 BSSID 判断是否已存在 | 使用 `HashSet<String>` 存储 mResponseMacs 去重 |
| 多设备支持 | 通过 `expectTaskResultCount` 控制期望结果数 | 通过 `EspProvisioningListener.onResponse` 持续回调，支持多设备 |
