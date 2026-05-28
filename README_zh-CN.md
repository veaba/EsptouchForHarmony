# EspTouch for Android

一款用于将 ESP 设备配置连接到目标 Wi-Fi 路由器的 Android 应用。

**注意：EspTouch V2 与 EspTouch V1 不兼容**

## 技术原理

ESP-TOUCH 协议采用 Smart Config（智能配置）技术，帮助用户将 ESP8266 和 ESP32 设备连接至 Wi-Fi 网络。用户只需在手机上简单操作即可完成智能配置。

### 工作流程

由于设备初始未联网，应用无法直接向设备发送信息。通过 ESP-TOUCH 协议，具有 Wi-Fi 接入能力的手机可以向 AP 发送一系列 UDP 数据包，SSID 和密码编码在数据包长度字段中，设备接收后解析出所需信息。

## 项目结构

```
EsptouchForAndroid/
├── app/                    # 示例应用程序
├── esptouch/               # EspTouch V1 库（已弃用）
├── esptouch-v2/            # EspTouch V2 库（推荐使用）
├── docs/                   # 用户指南和图片
├── log/                    # 应用更新日志
└── build.gradle            # 根 Gradle 配置
```

## 支持的平台

- **ESP8266**：OS SDK 和 NonOS SDK
- **ESP32**：ESP-IDF

## 版本说明

| 库 | 版本 | 描述 |
|---|---|---|
| EspTouch | 1.1.1 | 旧版本，已弃用 |
| EspTouch V2 | 2.2.1 | 推荐使用，功能更完善 |

| 组件 | 版本 |
|---|---|
| App | v2.4.0 |
| minSdk | 21 |
| targetSdk | 34 |

## 功能特性

### EspTouch V1
- 支持广播和组播数据包
- 单次最多配置多台设备
- 简单密码配置

### EspTouch V2（推荐）
- 支持自定义数据（最大 64 字节）
- 支持 AES 加密（16 字节密钥）
- 支持微信 AirKiss 协议
- 提供同步状态回调
- 配网任务 90 秒超时
- 设备响应确认机制

### 限制说明
- 不支持 5 GHz 频段
- 不支持 802.11ac 协议
- 路由器开启 AP 隔离可能导致配网成功提示无法收到

## 快速开始

### 导入库

在项目根目录的 `build.gradle` 中添加 JitPack 仓库：

```gradle
allprojects {
    repositories {
        maven { url 'https://jitpack.io' }
    }
}
```

在 app 模块的 `build.gradle` 中添加依赖：

```gradle
// EspTouch V1（已弃用）
implementation 'com.github.EspressifApp:lib-esptouch-android:1.1.1'

// EspTouch V2（推荐）
implementation 'com.github.EspressifApp:lib-esptouch-v2-android:2.2.1'
```

### 使用方法

#### EspTouch V1

```java
Context context; // Application Context
byte[] apSsid = {}; // AP 的 SSID
byte[] apBssid = {}; // AP 的 BSSID
byte[] apPassword = {}; // AP 的密码

EsptouchTask task = new EsptouchTask(apSsid, apBssid, apPassword, context);
task.setPackageBroadcast(true); // true = 广播包，false = 组播包

// 设置结果回调
task.setEsptouchListener(new IEsptouchListener() {
    @Override
    public void onEsptouchResultAdded(IEsptouchResult result) {
        // 处理结果
    }
});

// 执行配网
int expectResultCount = 1;
List<IEsptouchResult> results = task.executeForResults(expectResultCount);
IEsptouchResult first = results.get(0);
if (first.isCancelled()) {
    // 用户取消
    return;
}
if (first.isSuc()) {
    // 配网成功
}

// 取消任务
task.interrupt();
```

#### EspTouch V2

```java
Context context; // Application Context
EspProvisioner provisioner = new EspProvisioner(context);

// 启动同步
EspSyncListener syncListener = new EspSyncListener() {
    @Override
    public void onStart() {}
    @Override
    public void onStop() {}
    @Override
    public void onError(Exception e) {}
};
provisioner.startSync(syncListener);

// 启动配网
EspProvisioningRequest request = new EspProvisioningRequest.Builder(context)
    .setSSID(ssid)                    // AP 的 SSID，可为空
    .setBSSID(bssid)                  // AP 的 BSSID，非空
    .setPassword(password)            // AP 的密码，开放网络可为空
    .setReservedData(customData)       // 自定义数据，最大 64 字节，可为空
    .setAESKey(aesKey)                // AES 密钥，16 字节，可为空
    .build();

EspProvisioningListener listener = new EspProvisioningListener() {
    @Override
    public void onStart() {}
    @Override
    public void onResponse(EspProvisionResult result) {}
    @Override
    public void onStop() {}
    @Override
    public void onError(Exception e) {}
};
provisioner.startProvisioning(request, listener);

// 停止配网
provisioner.stopProvisioning();

// 关闭并释放资源
provisioner.close();
```

## 配网操作步骤

1. 准备支持 ESP-TOUCH 的设备，开启 Smart Config 功能
2. 将手机连接到目标路由器（2.4 GHz 频段）
3. 打开 EspTouch 应用
4. 输入路由器 SSID 和密码（开放网络可留空密码）
5. 点击确认开始配网

## 性能分析

采用累积纠错算法确保信息发送成功率：

- **20 MHz 带宽**：104 字节数据成功率可达 95%（6 轮发送）
- **40 MHz 带宽**：72 字节数据成功率可达 83%（6 轮发送）

## 更新日志

- [应用更新日志](log/log-zh-rCN.md)
- [EspTouch 库更新日志](esptouch/ChangeLogs/log_zh.md)
- [EspTouch V2 库更新日志](esptouch-v2/ChangeLogs/log_zh.md)

## 相关文档

- [用户指南](docs/esptouch-user-guide-cn.md)
- [ESP-IDF Smart Config](https://github.com/espressif/esp-idf/tree/master/examples/wifi/smart_config)
- [ESP8266_RTOS_SDK Smart Config](https://github.com/espressif/ESP8266_RTOS_SDK/tree/master/examples/wifi/smart_config)

## 许可证

参见 [LICENSE](LICENSE)

## 发布版本

请参阅 [Releases](https://github.com/EspressifApp/EsptouchForAndroid/releases)