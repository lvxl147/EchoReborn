# Echo Reborn 0.4.3 — 快捷指令数据源定位失败：根因与修复

依据：`Echo Reborn-log-20260912-124711.txt`（0.4.2 实测），以及插件自身在设置页输出的诊断文案。

## 一、日志建立的硬事实

### 事实 1：22 个"候选容器"里没有一个有可读身份的快捷指令容器

`Shortcuts: 22 container(s) [...]` 列出的 22 个容器，按路径分布：

| 类型 | 数量 | 说明 |
|---|---|---|
| `Data/Application` | 3 | `C762A96E`（Shortcuts 本体）、`BF4B2037`（ShortcutsUI）、`9419391F` |
| `Shared/AppGroup` | 2 | `2A99AD61`（WorkflowKit 组）、`E5D5FE60` |
| `Data/PluginKitPlugin` | 17 | 扩展容器 |

17 个 PluginKitPlugin 是错误的直接证据：扩展（widget / 分享扩展 / 意图扩展）不持有快捷指令库。

**它们为什么被收进来**：`ERShortcutContainerPaths()` 在 metadata plist 读不出 `MCMMetadataIdentifier` 时的回退分支只做名字测试——容器名含 `shortcut` 或 `workflow` 即通过。`PluginKitPlugin/<UUID>` 是纯 UUID，本身不含这两个词，所以真正命中的是回退分支的第二个条件：

```objc
for (NSString *leaf in @[@"Library/Shortcuts", @"Library/Application Support", @"Library/Mobile Documents"]) {
    ...
    for (NSString *entry in [files contentsOfDirectoryAtPath:probe error:nil]) {
        if ([entry.lowercaseString containsString:@"shortcut"]) { matched = YES; break; }
    }
}
```

`Library/Application Support` 在任何 App 容器里都存在。只要它下面有任何一个名字里带 `shortcut` 的条目，容器就被接受。于是"名字含 shortcut"这个本意是收窄的条件，实际变成了"几乎全部容器"。

同时注意：这个回退**没有**检查 `Library/Shortcuts` 目录本身是否存在。`C762A96E` 是 Shortcuts App 本体容器，只要它曾经有过这个目录就会被收进来（而它不是数据库所在处）。

### 事实 2：28 个被探测的文件里 24 个是缓存 blob

`28 store candidate(s) to probe` 的实际构成：

| 路径形态 | 数量 |
|---|---|
| `Caches/com.apple.shortcuts/fsCachedData/<UUID>` | 24 |
| `Caches/.../Cache.db`、`HTTPStorages/.../httpstorages.sqlite` | 3 |
| `Caches/is.workflow.WFDiskCache.default/<hash>` | 1 |

`fsCachedData/<UUID>` 是 URL 加载系统的磁盘缓存，**按设计就是无扩展名的**。0.4.1-3 为了不漏掉"Core Data 可能把库命名成无扩展名的 `Shortcuts`"，把匹配规则放宽成：

```objc
return ![lower containsString:@"."];   // 无扩展名一律当候选
```

这条规则在有 24 个缓存 blob 的现实里，等于把扫描预算全部花在缓存上。真正的库就算在列表里，也排在 24 个缓存之后——而探测在命中前会先失败 24 次，每次都要复制文件 + 开库 + 查询。

### 事实 3：WARN 行列出的 66 条路径，代码从未打开过

这是本次审计发现的**结构性缺陷**，也是"数据源定位失败"的真正机制。

两条路径链路是分开的：

- `ERShortcutDatabaseCandidates()` — 手工拼路径。0.4.2 上容器是 22 个，每个容器 3 条相对路径，共 **66 条**。这 66 条就是 WARN 行打印的内容。
- `ERDiscoveredShortcutDatabaseCandidates()` — 实际被 `ERShortcutsDatabasePath()` 打开的那个列表。它**先**递归遍历全部容器（深度 6，含 Caches），把结果放前面，**再**追加 `ERShortcutDatabaseCandidates()`。

所以实际顺序是：先遍历 22 个容器 → 得到 28 个候选（全是缓存）→ 只有当这 28 个都不命中时才轮到那 66 条。日志显示 `scanned 28 sqlite file(s) ... none had a ZSHORTCUT table`，且 28 个候选全部 `fileExistsAtPath` 失败（只有 0 个真正被打开），遍历在附加 66 条之前就已经把预算用尽。

结论：**插件把"未找到"的结论建立在一批从未被 stat 的路径上**。库即使躺在 `/var/mobile/Library/Shortcuts/Shortcuts.sqlite`——一个 0.4.2 硬编码在候选表第一位的路径——也没有被检查过一次。

### 事实 4：22 个容器本身很可能是系统读不到的

证据：`C762A96E` 在事实 2 里明明有 `Library/Caches/com.apple.shortcuts/Cache.db` 和 `Library/HTTPStorages/com.apple.shortcuts/httpstorages.sqlite`（遍历能看到），但 66 条候选里针对它的 `Library/Shortcuts/Shortcuts.sqlite`、`Documents/Shortcuts.sqlite`、`Library/Application Support/...` 全部 `fileExistsAtPath` 失败。这批候选里包含了 `Library/Application Support` 这个**几乎必然存在**的目录，它也不存在。

同时 `MCMMetadataIdentifier` 对 22 个容器全部读不出——包括 Shortcuts App 自己的容器。这说明该进程对容器 metadata 的读取被拒绝，很可能对整个 Data 分区的一致读取也被拒绝。

### 事实 5：日志本身不可靠

日志中 `Shortcuts:` 行的时间戳是 `12:46:19`（本地），而 `[PREFS]` 行是 `04:46:02 +0000`——两套时区，同一次 rescan 被记成两个时间。更重要的是 `ERLogRecord` 的落盘策略：非 ERROR 级别只在缓冲累计到 `kERLogFlushInterval = 8` 时才刷一次：

```objc
gERLogFlushCounter++;
BOOL urgent = [level isEqualToString:@"ERROR"];
if (urgent || gERLogFlushCounter >= kERLogFlushInterval) { ... }
```

日志尾部没有任何 ERROR，说明末尾若干条 INFO/WARN 从未落盘。日志文件写入本身也没有任何失败回退。

---

## 二、修复（0.4.3）

### 修复 1：报告集合与探测集合合并为同一集合

`ERDiscoveredShortcutDatabaseCandidates()` 顺序反转——显式候选表**先**，容器遍历**后**：

```objc
append(ERShortcutDatabaseCandidates());          // 阶段 1：已知位置，先试
for (NSString *candidate in ERShortcutDatabaseCandidates()) {
    if (fileExists(candidate)) return ordered;    // 命中即返回，不做遍历
}
... 容器遍历，结果 append(walked)                   // 阶段 2：仅当阶段 1 全空
```

配套地，`ERShortcutsDatabasePath()` 现在把**存在性判定**也计入 `gERShortcutProbedPaths`。于是"日志里报的"与"代码打开过的"不可能再分叉：报告即探测，探测即报告。

### 修复 2：容器按内容识别，不再按名字

`ERShortcutContainerPaths()` 重写为三段：

- **Pass 0**：直接问容器管理器要路径（`container_copy_path`，dlopen 解析，原型正确声明，返回 `+1 CFStringRef`）。查 `com.apple.shortcuts`、`group.com.apple.WorkflowKit`、`com.apple.ShortcutsUI` 等。这是唯一既能给出归属又能给出可用路径的来源。
- **Pass 1**：metadata plist 归属匹配（保留，但不再有名字回退）。
- **Pass 2**：仅当 Pass 0/1 全空时，对 metadata 不可读的容器逐个做内容判定。

内容判定 `ERContainerHoldsShortcutStore()` 只认 Core Data 自己的痕迹：`Library/Shortcuts/Shortcuts.sqlite(-wal/-shm)`、`.Shortcuts.sqlite_SUPPORT`、`Documents/Shortcuts.sqlite`、`Library/Application Support/Shortcuts.sqlite` 等。缓存容器无法满足其中任何一条——识别依据是内容，不是名字。

### 修复 3：去掉无扩展名规则，从目录层剪掉缓存

```objc
static BOOL ERPathIsPurgeableCache(NSString *path);      // /caches/ /httpstorages/ /fscacheddata /tmp/
static BOOL ERLooksLikeStoreCandidate(NSString *fileName); // 仅 .sqlite/.db/.sqlite3/.store
static BOOL ERDirectoryIsWorthWalking(NSString *name);     // 遍历前排除 Caches/HTTPStorages/fsCachedData
```

无扩展名的 `Shortcuts` 库的覆盖由**具名候选**补回，而不是靠通配。24 个误报由此从构造上消失，不再依赖后续过滤。

### 修复 4：候选表覆盖库真实的落点

在容器的每一个 `Library/Application Support`、`Documents`、`Library/Database`、`Library/Shortcuts`、`Library/Private Documents` 下，都按 `Shortcuts.sqlite`、`Shortcuts`、`Workflow.sqlite`、`WorkflowKit.sqlite` 四种名字探测。这样"找到了容器"更可能直接变成"找到了库"；找不到则退回内容扫描。

### 修复 5：日志写入失败回退到 NSLog

`ERLogAppendLines()` 现在区分主日志写入成功/失败，失败时把这几行镜像到 `NSLog`（带上限 2000 行，避免坏文件变成风暴）。主路径仍然不用 NSLog（它会同步阻塞 SpringBoard 主线程），只有文件已经不可用时才走这条路。

### 修复 6：一次性文件系统可读性探测

新增探针在每次进程内首次求值容器时记录，对每个容器根：

```
Shortcuts: fs probe <root> exists=? dir=? listed=N statable=M
Shortcuts: container manager path lookup available/unavailable
```

以及失败行现在报"候选路径 N 条，其中存在 M 条"。这两个数字是决定性的：**列不出 vs 列得出但 stat 不了 vs 都能**，分别指向路径错、读被拒、逻辑错三种完全不同的修法。0.4.2 的日志没有能力区分它们，这就是反复猜路径的原因。

### 修复 7：设置页文案可判别

`ERShortcutController` 的 `no-database` 文案改为按 `candidatePresent` 分支：0 条存在 → 指向读取权限/路径；>0 条存在 → 指向读取失败。`discoveryDetail` 增加"候选路径 N 条，其中存在 M 条"。用户在手机上就能读到结论，不必等日志往返。

---

## 三、验证步骤

1. 安装 0.4.3，打开设置 → 液态玻璃 → 快捷指令（或直接进快捷指令管理页）。
2. 点右上角「重新扫描」。
3. 读取页面上这一段，它直接给出判定：
   - `插件已成功获取到 N 条快捷指令` → 已修好。
   - `候选路径 N 条，其中存在 M 条` + `M = 0` → 读取被拒，需要看 `fs probe` 行的 `statable`。
   - `M > 0` → 路径对了、读取失败，看 `no readable store` 行。
4. 导出日志，检查新增行：
   - `fs probe ...` — 容器根是否可列、条目是否可 stat。
   - `container manager path lookup available/unavailable` — 容器管理器是否可用。
   - `no container identity matched and no container held a store by content (N examined)` — 是否为"真的没有"。
   - 若命中：`located the store by scanning at <path>` 或 `using store <path>`。

## 四、仍未解决的问题

`iOS 17 上快捷指令 Core Data 库的确切路径` 依然没有被确证。本修复不依赖这个答案：它同时覆盖"路径已知但没被检查"（修复 1 已确证并修好）和"路径未知"（修复 2/3/4 + 修复 6 让它可被搜索到、可被读出来）。若 0.4.3 仍失败，修复 6 的探针会给出此前无法取得的判定依据。
