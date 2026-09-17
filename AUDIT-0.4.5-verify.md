# AUDIT: 快捷指令数据源根因核实（v0.4.5 / 日志 Echo Reborn-log-20260912-135814.txt）

> 目的：按用户要求"核实到底是什么问题"，基于 0.4.5 版本在设备上产生的日志做收敛分析。
> 状态：**仅核实，未改动代码，未发版。** 等待用户审查结论后再决定下一步。

---

## 一、本日志已确认"已修复"的项（0.4.4 + 0.4.5 生效）

| 历史问题 | 对应修复 | 本日志证据 |
|---|---|---|
| SpringBoard 崩溃（0.4.3 点"重新扫描/添加控制项"） | 0.4.4 改用 container query API | 全程**无崩溃** |
| 容器被 `/var` 与 `/private/var` 双计（44 个） | 0.4.5 `ERCanonicalContainerPath` 去重 | 日志显示 **22 container(s)** |
| 目录冒充数据库（`using store .../Documents`） | 0.4.5 `ERPathIsRegularStoreFile` | 日志**无** `using store` 行 |
| 搜索链根本没启动 | 0.4.5 日志/判定修复 | 日志打印 "22 container(s), 508 store candidate(s) to probe" 与 "scanned 508 sqlite file(s) ... none had a ZSHORTCUT table" |

**结论**：扫描逻辑本身现在是正确的、完整跑完的。问题不再是"代码 bug 导致没去扫"。

---

## 二、真正剩下的根因（本日志把问题收敛到唯一一点）

关键日志行（13:58:04 那次完整扫描）：

```
Shortcuts: 22 container(s) [...] 508 store candidate(s) to probe [...]
Shortcuts: home domain /var/mobile/Library/Shortcuts exists=0 dir=0 listed=0 [none]
Shortcuts: home domain /private/var/mobile/Library/Shortcuts exists=0 dir=0 listed=0 [none]
Shortcuts: scanned 508 sqlite file(s) under the Shortcuts container(s) and none had a ZSHORTCUT table
Shortcuts: no readable store; 0 of 508 candidate path(s) exist.
```

- 文档化主路径 `/var/mobile/Library/Shortcuts` 在 SpringBoard 里 `exists=0`（两种前缀都一样）。
- 22 个容器递归深扫出 **508 个 `.sqlite`**，逐个打开查 `ZSHORTCUT` 表 → **0 命中**。
- 那两个 AppGroup 容器（`2A99AD61-...`、`E5D5FE60-...`）是 22 个的一部分；代码在 `ERShortcutContainerPaths`（2779–2783）**已显式查询 `group.com.apple.WorkflowKit`**，所以真库位置本应包含在内。

**结论**：Shortcuts 数据库**既不在任何被枚举的容器里，也不在 SpringBoard 能看到的 home domain 路径上**。

---

## 三、被日志掩盖的关键歧义（这是"六七个版本没解决"的真正卡点）

`home domain exists=0` **无法区分两种根因**：

- **(A) 路径错 / 布局变**：本 iOS 版本上 Shortcuts 库根本不在此路径（或容器管理器对 SpringBoard 没返回 `group.com.apple.WorkflowKit` 容器）。
- **(B) 沙盒拒绝**：库就在那，但 SpringBoard 的 sandbox / entitlement 拒绝访问（`EACCES`）。`NSFileManager fileExistsAtPath:` 对"无权限"同样返回 NO，与"不存在"不可区分。

0.4.5 加的诊断块（Tweak.xm 3128–3139）注释里写明"要区分拒绝 vs 缺失"，但实现有缺陷：
1. 用的是 `fileExistsAtPath:`，**拿不到 errno**（ENOENT vs EACCES 已丢失）；
2. 只在 `exists` 为真时才调 `contentsOfDirectoryAtPath:error:`，被拒时 `error` 根本没被记录。
→ 注释声称的区分能力**实际没有实现**，这是一条诊断盲区。

> 同样问题也存在于 `fs probe`（2770 附近）：用 `fileExistsAtPath:` + `contentsOfDirectoryAtPath:error:nil`（error 被丢弃），无法判断 root 是"不存在"还是"列不出"。

---

## 四、为什么这决定修复方向南辕北辙（必须先把方向定清楚）

- **若是 (A) 路径/容器问题**：需要确认容器管理器是否真的把 `group.com.apple.WorkflowKit` 容器返回给 SpringBoard。若 SpringBoard 不是该 group 成员、容器管理器不对其开放，则 22 个容器里根本没有真库 → 修复方向是"换一种能拿到正确 group 容器的方式"。
- **若是 (B) 沙盒问题**：库就在那但 SpringBoard 读不到 → **"在 SpringBoard 内直接读 SQLite"这条路从根本上被堵死**，继续在扫描/匹配逻辑上打补丁毫无意义，必须改用别的机制（经 Shortcuts 自身进程 / Intents / 带正确 entitlement 的特权 helper）。

两种情况的修复手段完全不同，所以**在拿到确凿 errno 数据前，任何"再发一个版本试试"都是盲动**。

---

## 五、下一步建议（待用户审查确认后再执行）

1. **先补诊断，不补功能**：用 `stat()` / `access()` 拿 `errno`，把 `exists=0` 拆成 `ENOENT` / `EACCES`；`contentsOfDirectoryAtPath:error:` 的 error 必须记录；`fs probe` 同样补 errno。
2. **显式验证 WorkflowKit AppGroup**：打印容器管理器对 `group.com.apple.WorkflowKit` 是否返回路径、返回路径的 `stat` errno、以及该路径下能否列目录 / 找到 `Shortcuts.sqlite`。
3. 区分清楚 (A) 还是 (B) 后，再设计对应修复（(A) 修定位、(B) 改架构）。

---

## 待用户裁决

请审查以上结论，并确认：
- 同意"先补 errno 诊断、不急着发版"的策略；或
- 你认为偏向 (A) 或 (B) 某一侧，授权我直接针对该侧做最小验证改动。

**未获确认前，不会修改 Tweak.xm，不会推送/发布新版本。**
