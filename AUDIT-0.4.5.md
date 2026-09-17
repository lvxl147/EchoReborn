# Echo Reborn 0.4.5 — 「找不到快捷指令」根因报告

**状态：已修复** — 0.4.4 的崩溃已消失，本版修数据源定位。

## 一、0.4.4 日志证明了什么（2026-09-12 13:43:18）

```
[INFO]  Shortcuts: using store /var/mobile/Containers/Data/Application/C762A96E-.../Documents
[ERROR] Shortcuts: failed to open the copied store (/var/mobile/tmp/echoreborn-shortcuts-.../Shortcuts.sqlite) and the live store read-only
[ERROR] Shortcuts: ZSHORTCUT query failed: unable to open database file
```

**先说好消息：崩溃修复生效了。** 点「重新扫描」和「添加控制项」都不再闪退。

**坏消息：`using store` 那行后面跟的是一个目录。**

```
.../C762A96E-5A17-4664-A0C6-CAC7C92D51C5/Documents
```

`Documents` 是目录，不是 SQLite 文件。所以：

1. 代码把它当成「数据库路径」返回；
2. 复制它 → 失败（目录无法复制成文件）；
3. SQLite 打开临时副本 → `unable to open database file`；
4. **真正的按内容搜索（discovery walk）从未执行。**

第 4 点是关键。日志里**没有** `Shortcuts: N container(s) [...], M store candidate(s) to probe` 这一行 —— 而那行是 walk 开始时必然打印的。**没有它，就证明搜索流程根本没被启动。**

---

## 二、根因：目录被当成数据库

### 缺陷 1：把「目录本身」加进了候选库列表

`ERShortcutDatabaseCandidates()` 里：

```objc
for (NSString *directory in @[@"Library/Application Support", @"Documents",
                              @"Library/Database", @"Library/Shortcuts", @"Library/Private Documents"]) {
    add([containerPath stringByAppendingPathComponent:directory]);   // ← 目录本身
    add([... stringByAppendingPathComponent:@"Shortcuts.sqlite"]);   // ← 这才是文件
    ...
}
```

第一行把 `.../C762A96E-.../Documents` 这样的**裸目录**放进了「数据库候选」列表。

### 缺陷 2：存在性检查对目录也返回 YES

```objc
if ([[NSFileManager defaultManager] fileExistsAtPath:candidate]) {
    return candidate;   // 目录也满足！
}
```

`-fileExistsAtPath:` **对目录返回 YES**。于是：

- 候选表按顺序遍历；
- `/var/mobile/Library/Shortcuts/Shortcuts.sqlite`（第一位，真实位置）不存在 → 跳过；
- 容器候选里，`.../C762A96E-.../Documents` **是存在的目录** → **命中并返回**；
- 搜索提前结束。

同一处逻辑在 `ERDiscoveredShortcutDatabaseCandidates()` 里也存在（`fileExistsAtPath:` 直接 return），所以连 walk 的入口也被目录短路了。

**两个缺陷叠加 = 一个存在的目录冒充了数据库，整条搜索链被终止。**

---

## 三、真实位置（权威来源）

iMazing 官方恢复指南（Shortcuts 备份恢复）明确指出，备份中的快捷指令文件位于：

> **HomeDomain → Library → Shortcuts** → `Shortcuts.sqlite`、`Spotlight.dat`

即设备上：

```
/var/mobile/Library/Shortcuts/Shortcuts.sqlite
```

这正是候选列表**第一位**。它没被命中，说明 `fileExistsAtPath:` 返回 NO —— 可能是真的不存在，也可能是 SpringBoard 沙盒拒绝 stat。**这两种情况需要完全相反的修法**，而旧日志无法区分。

因此本版新增一条决定性诊断，把这两种情况分开。

---

## 四、0.4.5 修复

### 1. 目录不再可能冒充数据库（核心）

新增并统一使用：

```objc
static BOOL ERPathIsRegularStoreFile(NSString *path) {
    if (!path.length) return NO;
    BOOL isDirectory = NO;
    if (![[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDirectory]) return NO;
    return !isDirectory;
}
```

四处「这可能就是数据库」的判断全部改为要求**正规文件**：

| 位置 | 原判断 | 现判断 |
|---|---|---|
| 候选表命中 | `fileExistsAtPath:` | `ERPathIsRegularStoreFile` |
| walk 短路检查 | `fileExistsAtPath:` | `ERPathIsRegularStoreFile` |
| walk 探测循环 | `fileExistsAtPath:` | `ERPathIsRegularStoreFile` |
| `present` 计数 | `fileExistsAtPath:` | `ERPathIsRegularStoreFile` |

并删除把裸目录加入候选表的那一行。

### 2. 候选容器不再被重复计数（22 → 44 的真相）

`ERDataContainerRoots()` 同时返回 `/var/mobile/...` 与 `/private/var/...` 两种写法，**同一台设备上这是同一个目录**。于是每个容器被找到两次：

- 0.4.2 报 22 个，0.4.4 报 44 个 —— 设备上其实是 22 个；
- 且 walk 对每个目录做了两遍。

新增 `ERCanonicalContainerPath()`，把 `/private/var/x` 折叠成 `/var/x` 仅用于**去重**（保留第一个能用的实际写法，避免把可读路径换成不可读路径）。匹配与歧义集合都按规范化键去重。

### 3. 决定性诊断

walk 开始时打印 home domain 的真实状态：

```
Shortcuts: home domain /var/mobile/Library/Shortcuts exists=? dir=? listed=? [...]
```

判读方式：

| 输出 | 含义 | 下一步 |
|---|---|---|
| `exists=0` | 目录不存在 | 该机布局不同，靠 walk 在容器里找 |
| `exists=1 dir=1 listed=0` | 目录在，但**列不出来** | 沙盒拒绝读取，需要换读取方式 |
| `listed=N` 且列表含 `Shortcuts.sqlite` | 文件就在那里 | 说明逐文件 stat 被拒，是权限问题 |

这一条把「路径不对」和「读不到」彻底分开 —— 之前三个版本都在猜这件事。

### 4. 其余

- walk 现在真的会执行，会打印 `N container(s) [...], M store candidate(s) to probe [...]` 与最终结果。
- `ERContainerHoldsShortcutStore` 复查确认已正确区分目录/文件，未改动。

---

## 五、验证

1. 安装 0.4.5，respring。
2. 设置 → Echo Reborn → 快捷指令 → 点「重新扫描」。**不应闪退。**
3. 导出日志，关注这四行：
   - `Shortcuts: home domain /var/mobile/Library/Shortcuts exists=... listed=...`
   - `Shortcuts: N container(s) [...], M store candidate(s) to probe [...]`
   - `Shortcuts: using store ...`（这次应当是一个 `.sqlite` 文件）
   - 或 `Shortcuts: scanned N sqlite file(s) ... none had a ZSHORTCUT table`

无论哪种结果，`home domain` 那一行都会直接指出下一步该修什么。

---

## 六、教训

**「存在」不等于「是文件」。** `-fileExistsAtPath:` 对目录同样返回 YES，而候选列表里本来就有目录（那是「去哪里找」的目录，不是「库本身」）。当「可能是数据库」的判断允许目录通过时，一个恰好存在的目录就会冒充数据库，并且**静默终止整条搜索链** —— 表现是「什么都没找到」，而不是报错。

判断一个路径能否当作数据库，唯一正确的问法是：**它是正规文件吗？**
