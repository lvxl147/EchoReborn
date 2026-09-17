# Echo Reborn 0.4.2 整体审查报告

针对「整体检查一下，这个插件还有bug，未解决」。按四条链路逐一静态审查，以下是全部结论、证据与修复。

---

## 0. 先纠正一个我上一轮说错的结论

我上一轮说「0.4.1-5 编译失败，根因是 `self.tableView =` 对只读属性赋值」。**这个结论是错的**，证据有三条：

1. **0.4.1-5 与 0.4.1-6 的 `EchoRebornPrefs` 二进制大小完全相同**（237520 字节），符号也一致（都含 `openShortcuts` / `ERShortcutController`）。如果 0.4.1-5 编译失败，就没有这个二进制。
2. **`ERCategoryOrderController` 用完全相同的写法**（`@property (nonatomic, strong) UITableView *tableView;`，同样继承 `PSViewController`），而「分类管理」页一直正常。如果 `PSViewController.tableView` 真是只读，这个页早就编译不过了。
3. **GitHub 发布页显示 0.4.1-5 与 0.4.1-6 的下载次数都是 0**，0.4.1-4 是 1。也就是说你测试的是 **0.4.1-4**，而那个版本的 `EchoRebornPrefs` 二进制里**根本不含 `openShortcuts`**（我解包核对过，它只含 `openCategoryOrder`）——主设置页压根没有「快捷指令管理」这一行。

所以「点击没反应」的真相是：**你点的那个版本里没有这一行**（或点的是别的行）。改名 `shortcutTableView` 保留，但它是可读性改进，**不是**修复。

---

## 1. 快捷指令数据链路（已修复）

三个真实缺陷，任一成立都会让列表为空：

| # | 缺陷 | 证据 | 修复 |
|---|---|---|---|
| 1.1 | `ERCollectSQLiteFilesAt` 只接受 `.sqlite` 后缀 | Core Data 的 store 经常**无扩展名**（`Library/Shortcuts/Shortcuts`）；日志里 `scanned 1 sqlite file(s)` 与「找到 2 个容器」严重不符 | 新增 `ERLooksLikeStoreCandidate()`：接受 `sqlite/db/sqlite3/store` 及**无扩展名**，排除 `-wal/-shm/-journal` |
| 1.2 | `ERShortcutContainerPaths` 依赖 metadata plist | 越狱环境下 AppGroup 的 `.com.apple.mobile_container_manager.metadata.plist` 常读不到，容器被**全部跳过** | 读不到时回退：容器名含 shortcut/workflow，或探测 `Library/Shortcuts` 存在 / `Library/Application Support` 或 `Library/Mobile Documents` 下有名字含 shortcut 的条目 |
| 1.3 | 固定候选只拼一个文件名 | 只试 `Shortcuts.sqlite`，漏掉 `Library/Application Support/Shortcuts`（无扩展名） | 候选扩至 `Library/Application Support/Shortcuts.sqlite` \| `Shortcuts` \| `Shortcuts/Shortcuts.sqlite` |

另外把搜索深度放宽（Library 4→6、Documents 2→3、全局 3→4），并让快照输出**全部候选容器**与**实际探测过的每个文件路径**。

**可验证性**：设置页的「未显示控制项」页脚现在渲染容器列表 + 探测路径 + 状态文案（`ok` / `empty-store` / `no-database` / `no-sqlite3` / `query-failed`）。列表为空 = 插件没拿到数据（且能看出卡在哪一步）；列表有数据而控制中心不显示 = 过滤/展示问题（现在由白名单控制，你把某项移进「显示控制项」即可）。

---

## 2. 亮度/音量滑块（已修复，本轮最有价值的发现）

### 缺陷 2.1 — 关联对象挂错了对象（根因，一次解释两个症状）

`ERGestureIsSliderTracking(gesture)` 在 **gesture** 上查 `kERSliderTrackingGestureKey`，
而 `ERSliderInstallTrackingGesture` 只把这个键设在了 **slider** 上：

```objc
// 修复前
objc_setAssociatedObject(slider, &kERSliderTrackingGestureKey, tracking, ...);
// ERGestureIsSliderTracking 却查 gesture → 永远返回 NO
```

后果是**所有**依赖它的判断全部静默失效：

* `shouldReceiveTouch:` 中 `if (ERGestureIsSliderTracking(gesture)) return YES;` 失效 → 落到方法末尾的 `[view isKindOfClass:[UIControl class]] return NO`（滑块就是 UIControl）→ **观察手势被拒收，回调永不执行** → 读数只能靠 `setValue:` 的粗粒度更新 → **「百分比不实时」**。
* `shouldRecognizeSimultaneouslyWith...` 中同一判断失效 → 返回 NO → 观察手势与滑块自己的 pan **互相阻塞**，谁先 Began 谁赢 → **「拖动偶发失效」**（竞态，所以是"偶发"）。

**修复**：同时在 gesture 上写入标记（两个关联都设），并加注释说明为什么必须是两处。

顺带说明：我一度加了「按 `allTargets` 匹配 coordinator」的兜底，随后**立即删除**——因为 Echo Reborn 的翻页手势、编辑退出手势、模块拖拽手势**全部**以 coordinator 为 target，按 target 匹配会把它们全判成滑块观察器，反而破坏翻页与拖拽。已用精确的单键判断替代。

### 缺陷 2.2 — 归属判定过严，MRU 滑块判负

`ERSliderBelongsToAdjustmentModule` 要求视图链上的 `accessibilityLabel` 含 brightness/volume。
iOS 17 的亮度滑块是私有类 `MRUContinuousSliderView`，**它的 label 常为 nil**（label 挂在父级，某些构建上父级也没有）。
判负 → 观察手势**根本不安装** → 同样表现为读数滞后。

**修复**：把**类名**纳入判定（视图链与 responder 链都收集），并对两个 MediaControls 滑块类做**精确类名**匹配（`MRUContinuousSliderView` / `MRUVolumeSliderView`）。刻意不用 `mruslider` 这类前缀子串，避免把 MediaControls 的其它 MRU 滑块（进度条、路由选择器）卷进来。

### 缺陷 2.3 — 拖动中被重复初始化导致数值跳变

* `ERSliderReadoutBegin` 在**同一滑块正在跟踪**时仍会重跑，把 `LastDeltaY` 重置为 0 → 下一个样本的 `step` 吞掉整段位移 → 跳变。
  **修复**：同一滑块已跟踪时直接 early-return，完全不碰进行中的状态。
* `ERSliderReadoutTrackGesture` 的 `Began` 分支**无条件**把 live value 重置为系统 `value`，而此时 `Begin` 刚播过种、display link 可能已推进 → 读数被打回滞后值。
  **修复**：仅当 `LiveValue < 0`（确实没播过种）才读系统值。
* 中途进入（漏掉 Began）时把 `LastDeltaY` 设为 **0**，而 `deltaY` 已是累积值 → 首帧跳。
  **修复**：锚定为**当前** `translation.y`。

---

## 3. 设置面板入口（无需修复）

逐字段核对 `Root.plist`：

```
index 6  PSButtonCell  '液态玻璃'      action=openGlass:          ← 正常
index 8  PSButtonCell  '分类管理'      action=openCategoryOrder:  ← 正常
index 10 PSButtonCell  '快捷指令管理'  action=openShortcuts:      ← 与上面两个完全同构
```

`openShortcuts:` 的实现与 `openGlass:` / `openCategoryOrder:` 同构：`PSViewController` 基类、自建 UITableView、由 `ERRootListController` 手工 push、不走 PSLinkCell（避免跨 bundle 类查找）。`prefs/Makefile` 的 `EchoRebornPrefs_FILES` 含 `ERShortcutController.m`，`Resources/` 由 `EchoRebornPrefs_RESOURCE_DIRS` 整个拷入 bundle，`Root.plist` 会随包发布。

**结论：这条路径没有缺陷。** 唯一改动是把 `title` 也在 push 处设置一次（与另外两页一致，防御 view 未加载的时序）。

---

## 4. 崩溃与稳定性（本轮改动引入的两处隐患，已自查修掉）

* 删除了 `allTargets` 兜底（见 2.1），它既是热路径开销也是**误判源**。
* `ERSliderBelongsToAdjustmentModule` 新增了类名收集，但 `ERSliderInstallTrackingGesture` 的「已安装」守卫在归属判定**之前**，所以每个滑块至多算一次，不在 layout 热路径上重复。
* 括号平衡校验通过（最终 depth = 0，无负值行）。
* `ERShortcutPublishSnapshot` 的 `writeToFile:atomically:YES` 在多线程并发下安全（临时文件名唯一），目录由 `ERLogEnsureDirectory` 幂等创建。

---

## 5. 验证清单

装上 0.4.2 后请按顺序确认：

1. **设置 → Echo Reborn → 快捷指令管理**：能进入，页脚显示「找到 N 个候选容器」与「检查过的文件（M）」。
   * 列表为空 → 把页脚的容器/路径内容发我，这是数据源问题，我能直接定位。
   * 列表有数据 → 把某条移入「显示控制项」，回控制中心「添加控制项」应出现。
2. **亮度/音量**：长按控制中心的亮度（或音量）大模块，**缓慢**拖动，百分比应**连续**跟随手指，不跳变；松手后停在正确值。反复快速拖动多次，均应生效（此前是偶发）。
3. **不影响其它交互**：翻页横滑、编辑模式拖拽模块、缩放手柄，行为应与 0.4.1 一致。

---

## 6. 交付

版本 **0.4.2**，commit `55ca4c3`。CI 仍保留门禁：若 deb 里不含 `EchoRebornPrefs` 则直接 `::error::` 失败（避免再次出现「构建绿灯但面板没更新」）。
