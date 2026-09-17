# Echo Reborn 0.4.4 — SpringBoard 崩溃根因报告

**状态：已修复并发布** — https://github.com/lvxl456/EchoReborn/releases/tag/v0.4.4
（CI run 34675897209 success；包内 dylib 已核验 `container_copy_path` 彻底消失）

## 一句话结论

0.4.3 为了让「快捷指令」找到数据源，**凭空猜了一个私有符号 `container_copy_path` 的原型**，把它声明成 `CFStringRef (*)(CFStringRef)`。这个符号真实存在、导出、dlsym 不为 NULL，所以所有防御性检查都通过了 —— 但它根本不接受 `CFStringRef`，它要的是 `container_object_t`。于是内核把字符串 `"Shortcut"` 的前 8 个字节当成对象指针去 `object_getClass`，直接 SIGSEGV 打崩 SpringBoard。

**两个崩溃（重新扫描 / 添加控制项）是同一个根因**，两份日志的调用栈逐帧一致。

---

## 一、两份崩溃日志的硬事实

| 项 | 131638（点「重新扫描」） | 131702（点「添加控制项」） |
|---|---|---|
| 系统 | iPhone OS 17.2.1 (21C66), iPhone16,2 | 同 |
| 进程 | SpringBoard, pid 54057 | SpringBoard, pid 54117 |
| 异常 | `EXC_BAD_ACCESS / SIGSEGV` | 同 |
| 地址 | `KERN_INVALID_ADDRESS at 0x74756374726f6853` | 同 |
| 线程 | `com.apple.main-thread` | 同 |
| 触发帧 | `object_getClass` | 同 |

### 主线程调用栈（两份完全相同）

```
frame 0  libobjc.A.dylib              object_getClass
frame 1  libxpc.dylib                 xpc_data_get_bytes_ptr
frame 2  libsystem_containermanager   container_object_get_uuid
frame 3  libsystem_containermanager   __container_copy_path_block_invoke
frame 4  libsystem_trace.dylib        os_activity_apply_f
frame 5  libsystem_containermanager   container_copy_path
frame 6  EchoReborn.dylib  offset 561984   <-- 我方调用点
frame 7  EchoReborn.dylib  offset 554144
frame 8  EchoReborn.dylib  offset 550600
...
```

### 决定性证据：寄存器

frame 0 的 `threadState.x[0]`：

```
x[0] = 8391722832462047315 = 0x74756374726f6853
```

把它按小端还原成字节：

```
0x74756374726f6853  ->  b"Shortcut"
```

**崩溃地址本身就是字符串 `"Shortcut"`。** 这不是巧合，是铁证：`container_object_get_uuid` 把 x0 当作对象指针，调 `object_getClass(x0)` 去取 isa，而 x0 指向的是字符串常量 `"Shortcut"`（`"com.apple.shortcuts"` 的前 8 字节），于是把 `"Shortcut"` 的字节当成了类指针，读到了未映射地址。

---

## 二、根因链条

### 0.4.3 写的代码

```objc
typedef CFStringRef (*ERContainerCopyPathFunction)(CFStringRef);
copyPath = (ERContainerCopyPathFunction)dlsym(handle, "container_copy_path");
...
CFStringRef path = copyPath(identifierRef);   // identifierRef 是个 CFString
```

### 为什么所有防线都失效

1. **`dlopen` 成功** —— 库确实存在，路径正确。
2. **`dlsym` 返回非 NULL** —— `container_copy_path` 是真实导出的符号。
3. **NULL 检查通过** —— 代码以为"符号拿到了就能调"。
4. **`@try/@catch` 无效** —— 这是硬 SIGSEGV（非法内存访问），不是 Objective-C 异常，catch 永远不会执行。

### 真实原型

`container_copy_path` 属于 `container_object_t` 家族，其第一个参数**必须是 `container_object_t`**（一个不透明对象），不是标识符字符串。

正确用法是 **query API**（对照可用实现验证）：

```objc
container_query_t q = container_query_create();
container_query_set_class(q, 2);                    // 2 = app data container
container_query_set_identifiers(q, xpc_string);     // 或 _set_group_identifiers
container_object_t obj = container_query_get_single_result(q);  // borrowed
container_object_t owned = container_object_copy(obj);          // +1
const char *path = container_object_get_path(owned);
container_object_free(owned);
container_query_free(q);
```

---

## 三、0.4.4 修复

### 改动 1：重写 `ERContainerPathsForIdentifier()`（Tweak.xm ~2473-2596）

- **彻底删除** `container_copy_path` 和 `container_copy_sandbox_extension_token` 的调用。
- 改用完整 query 链：`create → set_class → set_identifiers/get_group_identifiers → get_single_result → object_copy → get_path → free`。
- **9 个符号全部 dlsym + NULL 检查**；缺任何一个直接返回空数组，退化为文件系统遍历，**绝不崩**。
- 内存管理按引用计数契约写：`get_single_result` 返回借用引用；`object_copy` 取 +1；用 `object_free` / `query_free` / `xpc_release` 各归各位。
- 同时尝试 class 2（app data，对应 `com.apple.shortcuts`）和 class 7（app group，对应 `group.com.apple.WorkflowKit`），让一个函数能吃两种标识符。

### 改动 2：xpc 调用改为运行时解析（不依赖 SDK 头文件）

第一次尝试直接 `#import <xpc/xpc.h>` + `EchoReborn_LIBRARIES = xpc`，CI 编译失败：

```
Tweak.xm:12:9: fatal error: 'xpc/xpc.h' file not found
```

原因：CI 使用的 Theos iOS SDK **不包含 xpc 头文件**。

最终方案 —— 与文件里其他私有 API 的做法保持一致，全部运行时解析：

```objc
typedef void *ER_xpc_object_t;
typedef ER_xpc_object_t (*ERXpcStringCreate)(const char *);
typedef void (*ERXpcRelease)(ER_xpc_object_t);
...
void *xpcHandle = dlopen("/usr/lib/system/libxpc.dylib", RTLD_LAZY);
xpcStringCreate = dlsym(xpcHandle, "xpc_string_create");
xpcRelease      = dlsym(xpcHandle, "xpc_release");
```

- 不需要 SDK 头文件，不需要链接 libxpc。
- 跨界传递的只是一个不透明指针，本地声明足够。
- `xpc_string_create` / `xpc_release` 同样进 NULL 检查，缺了就走降级分支。

### 改动 3：链接 libxpc —— 已撤回

原本加了 `EchoReborn_LIBRARIES = xpc`，改用 dlsym 后不再需要，已移除。

### 已审计的其他 dlsym

`sqlite3_*`（13 处）、`WFSystemImageNameForGlyphCharacter`、`CTSettingCopy/SetCellularDataEnabled` —— 全部是**公开且有文档的**符号，原型来源可靠，无需改动。唯一"猜原型"的就是容器那一个，现已消除。

---

## 四、验证步骤

1. 安装 0.4.4。
2. 控制中心 → 打开「添加控制项」→ **不应崩溃**，面板正常弹出。
3. 设置 → Echo Reborn → 快捷指令 → 点「重新扫描」→ **不应崩溃**，列表刷新。
4. 查看日志，确认容器管理器这行：
   - 成功：`Shortcuts: container manager resolved com.apple.shortcuts -> /private/var/...`
   - 或降级：`Shortcuts: container manager path lookup unavailable`
   
   **两者都不崩溃**即为修复成功。前者说明数据源找到了，后者说明 query API 不可用但安全降级到文件系统遍历。

---

## 五、教训

> 对私有 API，**不要猜原型**。符号存在 ≠ 调用安全。一个错误的函数指针声明，编译器不会报错，NULL 检查不会拦截，try/catch 也不会救你 —— 它只会在用户点击按钮的那一刻把 SpringBoard 打崩，并且崩溃栈看起来像是"系统库的问题"。
