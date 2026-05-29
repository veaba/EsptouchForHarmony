# ArkTS Build Errors & Fixes

## 1. No recursive type aliases / indexed signatures

**Error:**
```
Object literals cannot be used as type declarations (arkts-no-obj-literals-as-types)
Indexed signatures are not supported (arkts-no-indexed-signatures)
```

**Cause:** ArkTS 不支持递归 type alias 和索引签名类型。

```typescript
// BAD
type JSONValue = string | number | boolean | null | JSONValue[] | { [key: string]: JSONValue };
let obj: Record<string, JSONValue> = JSON.parse(json) as Record<string, JSONValue>;
```

**Fix:** 用 interface 替代，属性设为可选。

```typescript
// GOOD
interface DeviceStatusJson {
  status?: number;
  ip?: string;
  mac?: string;
}
let obj: DeviceStatusJson = JSON.parse(json) as DeviceStatusJson;
let status: number = obj.status ?? -1;
```

## 2. decodeWithStream deprecated

**Error:**
```
'decodeWithStream' has been deprecated.
```

**Fix:** 用 `decode()` 替代 `decodeWithStream()`。

```typescript
// BAD
util.TextDecoder.create('utf-8').decodeWithStream(new Uint8Array(message));

// GOOD
util.TextDecoder.create('utf-8').decode(new Uint8Array(message));
```

## 3. JSON.parse 返回值处理

ArkTS 中 `JSON.parse()` 返回 `Object`，不能直接用 `obj['key']` 访问。需要先转为具体 interface 再访问属性。

## 4. 对象字面量必须对应显式声明的类或接口

**Error:**
```
Object literal must correspond to some explicitly declared class or interface (arkts-no-untyped-obj-literals)
```

**Cause:** ArkTS 禁止无类型对象字面量。即使对象字面量的结构匹配某个 interface，也不能直接用 `= { ... }` 赋值给变量——必须创建一个具体的 class 实现 interface，再用 `new` 构造。

**典型场景：** 回调监听器（listener）在 `aboutToAppear()` 中创建时，习惯写成对象字面量。

```typescript
// BAD — ArkTS 编译报错
private deviceMonitorListener: DeviceMonitorListener | null = null;

aboutToAppear(): void {
  let self = this;
  this.deviceMonitorListener = {
    onDeviceOnline(status: DeviceStatus): void { self.handleDeviceOnline(status); },
    onDeviceOffline(status: DeviceStatus): void { self.handleDeviceOffline(status); },
    onMonitorError(error: Error): void { self.appendLog(`Error: ${error.message}`); }
  };
}
```

**Fix:** 创建一个 `implements` interface的具体 class，然后用 `new` 实例化。

```typescript
// GOOD — 用具体 class + constructor 回调
class DeviceMonitorListenerImpl implements DeviceMonitorListener {
  private onDeviceOnlineCb: (status: DeviceStatus) => void;
  private onDeviceOfflineCb: (status: DeviceStatus) => void;
  private onMonitorErrorCb: (error: Error) => void;

  constructor(
    onDeviceOnline: (status: DeviceStatus) => void,
    onDeviceOffline: (status: DeviceStatus) => void,
    onMonitorError: (error: Error) => void
  ) {
    this.onDeviceOnlineCb = onDeviceOnline;
    this.onDeviceOfflineCb = onDeviceOffline;
    this.onMonitorErrorCb = onMonitorError;
  }

  onDeviceOnline(status: DeviceStatus): void { this.onDeviceOnlineCb(status); }
  onDeviceOffline(status: DeviceStatus): void { this.onDeviceOfflineCb(status); }
  onMonitorError(error: Error): void { this.onMonitorErrorCb(error); }
}

// 在组件中使用
aboutToAppear(): void {
  this.deviceMonitorListener = new DeviceMonitorListenerImpl(
    (status: DeviceStatus): void => { this.handleDeviceOnline(status); },
    (status: DeviceStatus): void => { this.handleDeviceOffline(status); },
    (error: Error): void => { this.appendLog(`Error: ${error.message}`); }
  );
}
```

**要点：**
- ArkTS 中**所有对象字面量**都必须有对应的显式 class 或 interface 声明
- 回调模式：用 constructor 箭头函数捕获 `this`，避免 `self` 变量
- Class 定义放在 `@Component struct` **外面**（与组件同文件），和现有的 `ProvisioningListenerImpl` / `APProvisioningCallbackImpl` 保持一致

## 5. decode 同样已被弃用

**Error:**
```
'decode' has been deprecated.
```

**Fix:** 用 `decodeToString()` 替代 `decode()`。

```typescript
// BAD
let text: string = util.TextDecoder.create('utf-8').decode(new Uint8Array(message));

// GOOD
let decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
let text: string = decoder.decodeToString(new Uint8Array(message));
```

**注意：** `decodeWithStream()` 和 `decode()` 均已弃用，统一用 `decodeToString()`。
