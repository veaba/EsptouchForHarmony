# ArkTS Build Errors

## arkts-limited-stdlib — 禁用标准库部分 API

**错误码**: 10605144  
**报错形**: `Usage of standard library is restricted (arkts-limited-stdlib)`

### 原因

ArkTS 限制使用部分 JavaScript 标准库 API，`Object.assign` 属于受限列表。类似受限的常见 API 还包括 `Object.keys`、`Object.values`、`Object.entries`、`Object.defineProperty` 等。

### 解决方案

用逐字段赋值替代 `Object.assign`：

```typescript
// ❌ 报错
let target = new SomeClass();
Object.assign(target, source);

// ✅ 逐字段赋值
let target = new SomeClass();
target.fieldA = source.fieldA;
target.fieldB = source.fieldB;
target.fieldC = source.fieldC;
```

### 要点

- ArkTS 禁止运行时动态拷贝对象，只允许编译期可确定的逐字段赋值
- 如果字段较多，可在类中提供 `copyFrom(other: SomeClass)` 或工厂方法集中处理
- 报错行号指向调用位置，实际修改在调用处替换即可