# Echo Reborn 项目交接文档

> 交接时间：2026-09-10 21:35 (GMT+8)
> 交接版本：**v0.3.14**（`CFBundleVersion` 28）
> 仓库：`lvxl524/Echo Reborn` · 工作目录：`C:/Users/Administrator/WorkBuddy/ios插件开发/EchoReborn/`
> 工具目录：`C:/Users/Administrator/WorkBuddy/ios插件开发/_tools/`
> 上游：`com.strive.echoreborn` 二改（iOS 16/17 的 iOS 18 风格可编辑控制中心，Theos/Logos，rootless + roothide）

---

## 1. 当前目标

本阶段的唯一目标是：**让七个自研连接性模块（飞行模式／无线局域网／隔空投送／蜂窝数据／蓝牙／个人热点／VPN）在「关闭态」的背景材质，与页面上其它原生 Control Center 磁贴完全一致，并在 2×1 布局下横向对齐。**

拆成两条可验收的子目标：

1. **背景材质一致**
   - 打开态 = 纯白 `colorWithWhite:1.0`。
   - 关闭态 = 磁贴自身的系统材质（`MTMaterialView` / `UIVisualEffectView` + CC 模糊配方），**绝不叠加任何自绘纯色**。
2. **2×1 横向对齐**
   - 以「蓝牙」为基准：先把「蓝牙」二字在其磁贴内水平居中，其下方副标题与标题左对齐，由此反推出一个共享左内边距，其余六个模块全部共用该值。
   - 只改横向、垂直位置不变。

**验收标准**：在真机 Control Center 里，关闭态的七个模块背景深度与旁边的原生磁贴（手电筒、计时器等）目视一致；2×1 下七个模块的标题与副标题左边缘落在同一条竖线上。

---

## 2. 已完成内容

本阶段共迭代 4 个版本（v0.3.11 → v0.3.14），全部已构建、已发布到 GitHub Release。

### v0.3.11 — 背景色回归全局约定 + 三模块接入 + 布局修正

- 撤销 v0.3.10 的双态 `#C7C7CC` 硬灰，关闭态改回「计时器同款灰」（`colorWithWhite:1.0 alpha:0.12` + 原生模糊），打开态纯白。
- 2×2 布局：底部文字与图标统一到 `kERSquareContentInset = 16.0` 前导内边距。
- 文案修正：蓝牙关闭态 `打开` → `关闭`；无线局域网关闭态 `Off` → `关闭`。
- 「飞行模式」「蜂窝数据」「个人热点」接入同一白/灰风格与三档排布（飞行模式黄图标 `#FFCC00`，蜂窝数据/个人热点绿图标 `#34C759`，蜂窝数据副标题为运营商卡名），均设为单实例。
- 「添加控制项」预览磁贴同步白/灰双态。

### v0.3.12 — 关闭态底色的根因修复（关键版本）

- 关闭态**不再绘制任何自绘叠色**，直接沿用磁贴自身的系统材质。
- **根因**：原生内容隐藏通道 `ERSTerHideNativeSubviews` 会把模块的 `MTMaterialView` 一并隐藏（该类不是 `UIVisualEffectView`，通道不豁免），导致 native 材质从未真正显示。v0.3.9 的「关闭态背景缺失」与 v0.3.10/0.3.11 的反复调灰，全部是这一根因的衍生症状。
- 新增 `ERRestoreConvertedTileMaterial(UIView*, BOOL visible, BOOL available)`：OFF 时显式恢复被隐藏的材质。
- 放宽材质查找 `ERFirstModuleMaterialSurface`：接受 `MTMaterialView`、名字含 `Material` 的子类、`UIVisualEffectView`，且尺寸需覆盖整块磁贴（误差 < 4pt）。
- 若确实取不到材质，补一块 Echo Reborn 自有的 `SystemUltraThinMaterialDark` 毛玻璃底（tag `181054`），任何情况下都不再出现纯色叠层。

### v0.3.13 — 修复 v0.3.12 的「背景直接没了」

- **问题**：材质查找放宽后，命中了一个**嵌在已被隐藏父容器里**的满尺寸材质；把它 un-hide 仍然不可见，且因为「找到了」导致兜底毛玻璃也没被创建 → 空背景。
- **修复**：新增 `ERConvertedTileBackgroundMaterial(UIView*)`，按「**可用性**」而非「找得到」解析——仅当模块自带材质是磁贴的**直接子视图**（`native.superview == moduleView`，父级可见、un-hide 必然生效）才沿用，否则一律使用 Echo Reborn 自有毛玻璃。
- 毛玻璃置于自绘层之下，关闭态始终有一块真实材质。

### v0.3.14 — 材质加深 + 2×1 对齐重做（当前版本）

- 兜底毛玻璃由 `SystemUltraThinMaterialDark` → **`SystemThinMaterialDark`**（原档在原生磁贴旁明显偏浅）。
- 新增 `ERConnectivityCompactTextLeading(UIFont*, CGFloat logicalWidth)`：由「蓝牙」二字在磁贴内居中反推共享左内边距。
- `ERLayoutOwnedCompactPresentation` 新增 `connectivityColumn` 参数：2×1 分支中连接性模块用反推内边距，非连接性模块（快捷指令/Text Size/电源/缩小模块）保持 `kERGridCellSize + 6.0` 原值。

---

## 3. 关键决策

| # | 决策 | 理由 |
| --- | --- | --- |
| 1 | **关闭态 = 磁贴自身系统材质，绝不叠任何自绘纯色** | 唯一能让自研模块与原生磁贴"长得一样"的办法；任何自绘灰都会在原生模糊旁偏色。 |
| 2 | **打开态 = 纯白 `colorWithWhite:1.0`** | 对齐 iOS 18 控制中心选中态。 |
| 3 | **材质按「可用性」解析，而非「找得到」** | 页面上可能存在嵌在隐藏父容器里的满尺寸材质；"找得到"不等于"看得见"。只有直接子视图的材质才可用。 |
| 4 | **必须有兜底毛玻璃** | 模块 bundle 是纯桩，没有自带视图；运行时材质依赖 CC 宿主，取不到时 Echo Reborn 必须自建一块，保证任何时候都有底。 |
| 5 | **2×1 对齐以「蓝牙」为基准反推共享内边距** | 若各模块各自居中，「无线局域网」「VPN」会落在不同左边，正是要消除的错位；统一值才能形成一条竖线。 |
| 6 | **swizzled 方法内禁止运行时内省** | 第三方 tweak（liquidass）interpose `class_getSuperclass` 等会导致 respring 死循环；`%ctor` 安装期才允许 `class_getInstanceMethod`。 |
| 7 | **计时器 chrome 通道 / 预览容器的 `alpha:0.12` 打底是特例** | 只为避免「分离预览」里素材变黑，**不是**关闭态通用色，勿误当全局约定。 |

---

## 4. 修改过的核心文件

### 4.1 运行时源码（高频编辑，唯一真相源）

**`EchoReborn/Tweak.xm`** — 现 **16763 行**。本阶段涉及函数与当前行号：

| 行号 | 符号 | 作用 |
| --- | --- | --- |
| 107 | `kERSquareContentInset = 16.0` | 2×2 图标与文字共享前导内边距 |
| 274 | `kERConnectivityTileMaterialTag = 181054` | Echo Reborn 自有兜底毛玻璃 tag |
| 539 | `ERConnectivityIdentifierUsesWhiteHighlight` | 七个连通性标识符均返回 YES |
| 2444–2450 | 连通性标识符 → 中文名映射 | 飞行模式/无线局域网/隔空投送/蜂窝数据/蓝牙/个人热点/VPN |
| 2739 | `ERBluetoothStatusText` | radio off→`关闭`，on 无连接→`打开`，N 连接→`N个设备已连接` |
| 2747 | `ERConnectivityStatusForIdentifier` | 各模块副标题文案 |
| 4584 | `ERFirstModuleMaterialSurface(UIView*)` | 放宽材质查找（MTMaterialView / Material 子类 / UIVisualEffectView，满磁贴尺寸） |
| 4618 | `EREnsureConnectivityTileMaterial(UIView*)` | 兜底毛玻璃（v0.3.14 为 `SystemThinMaterialDark`） |
| 4651 | `ERConvertedTileBackgroundMaterial(UIView*)` | **v0.3.13 新增**：按可用性解析材质 |
| 4716 | `ERConnectivityHighlightPlatterColor` | 白 `colorWithWhite:1.0 alpha:1.0` |
| 4720 | `ERConnectivityRestingPlatterColor` | 计时器灰 `alpha:0.12`（仅兜底/特殊用） |
| 4744 | `ERConnectivityAccentColorForIdentifier` | per-module 色调（黄/绿/系统蓝） |
| 4935 | `ERRestoreConvertedTileMaterial` | **v0.3.12 新增**：显式恢复被隐藏材质 |
| 4959 | `ERSetConnectivitySelectedSurface` | OFF 取材质、surface 仅 ON 画白、OFF `clearColor`，层次=材质底/白中/图标上 |
| 5098 | `ERConnectivityCompactTextLeading` | **v0.3.14 新增**：由「蓝牙」反推共享左内边距 |
| 5126 | `ERLayoutOwnedCompactPresentation(..., BOOL connectivityColumn)` | **v0.3.14 加参数**：2×1 分支按 `connectivityColumn` 选内边距 |
| 5448 | `ERSTerHideNativeSubviews` | 隐藏原生内容（豁免 tag≥181000 与 `UIVisualEffectView`，**不豁免 MTMaterialView** ← 根因） |
| 5473 | `ERSetModuleNativeContentHidden` | 隐藏原生内容两遍遍历入口 |
| ~5628 / ~9458 | 2×1 渲染调用点 | live / gallery，连接性磁贴传 `connectivityColumn = YES` |

### 4.2 版本与元数据

- **`EchoReborn/control`**：`Version: 0.3.14`（本阶段逐版递增）。
- **`EchoReborn/prefs/Resources/Info.plist`**：`CFBundleShortVersionString = 0.3.14`，`CFBundleVersion = 28`。
- **`EchoReborn/VERSIONING.md`**：迭代计数表已更新至「15 | 0.3.14」行；规则为「每 10 次迭代次版本 +1，未满 10 次只递增 `CFBundleVersion`，修订号恒 0」。
- **`EchoReborn/modules/<key>/ERConnectivity<Key>Module.m|.h`**：七个模块（airdrop/airplane/bluetooth/cellular/hotspot/vpn/wifi）均为**纯桩**（`.m` 仅 3 个宏 + include `ERConnectivityModule.h`），**不建任何视图/材质**。
- **`EchoReborn/.github/workflows/build.yml`**：GitHub Actions macOS runner + Theos，产物含 rootless(arm64) 与 roothide(arm64e) 两种 deb。

### 4.3 工具目录 `_tools/`

- **发布说明**：`release_body_v0311.md` ~ `release_body_v0314.md`。
- **符号校验器**：`verify_v0311_deb.py` ~ `verify_v0314_deb.py`（v0.3.14 新增 `sizeWithAttributes:` 门禁，证明对齐改动编入二进制）。
- **出图脚本**：`render_bg_candidates.py` + `echoreborn_off_bg_candidates.png`（A–F 白叠加候选，用户选 **A**）；`render_off_bg_expected.py` + `echoreborn_off_bg_expected.png`（手电筒参照）；`render_off_material_ramp.py` + `echoreborn_off_material_ramp.png`（四档材质深度：A UltraThin / **B Thin[v0.3.14]** / C Material / D Chrome）。
- **构建产物**：`v0314_out` / `v0314_rootless` / `v0314_roothide` / `v0314_release`；发布件 `echoreborn_0.3.14_iphoneos-arm64.deb`、`echoreborn_0.3.14_iphoneos-arm64e.deb`。
- **API 工具（Node，模块化）**：`gh_api.js`（导出 `request/json/download/TOKEN`，非 CLI）、`push.js`、`download.js`、`release.js`、`wait.js`、`logs.js`。
- **PAT 文件**：`C:/Users/Administrator/liquidpatch_pat.txt`（`gh_api.js` 读取）。

---

## 5. 测试与验证结果

### 5.1 机器校验（符号门禁）

每版均用 `verify_v03XX_deb.py` 对发布 deb 做静态校验，通过项包括：

- 七个连通性 bundle 存在、plist 有效。
- 连通性标识符命名空间 `com.strive.echoreborn.connectivity` 存在。
- per-module 强调色常量、副标题字串（含「不可被发现」「N个设备已连接」等）存在。
- **v0.3.14 专项**：`sizeWithAttributes:` 存在（全 tweak 仅新对齐助手调用它，可证明对齐改动已编入）。
- **安全门禁**：`class_getSuperclass` 等禁止符号仍然缺失（防注销死循环）；`class_getInstanceMethod` 仅允许出现在安装期 `%ctor`。
- 校验结果：各版 **40/40 或 41/41 通过，0 失败**。

### 5.2 CI 构建与发布

- 工作流：`.github/workflows/build.yml`（macOS + Theos）。
- CI run 记录：`34494586410`（`be85507c`，**completed / success**）、`34493185001`、`34491743594`、`34489037757` **均 success**。
- Release：v0.3.14（id `386425255`）、v0.3.13（`386389549`）、v0.3.12（`386378637`）、v0.3.11（`386358294`）。

### 5.3 视觉验证

- 出图对照：`echoreborn_off_bg_candidates.png` 用来让用户确认白叠加档位 → 用户选定 A 后进入 v0.3.12+；`echoreborn_off_material_ramp.png` 用于让用户目视比较四档材质深度 → v0.3.14 取 B（Thin）。
- **真机验收仍待用户完成**：材质深度是否满意、2×1 竖线是否对齐，需用户上机确认。

---

## 6. 已知问题

1. **滑块实时读数缺陷未处理**（用户明确「暂不处理，后续单独跟进」）。这是当前最大遗留项。
2. **关闭态材质深度可能需要继续调档**：v0.3.14 取 `SystemThinMaterialDark`。若上机后仍偏浅，按档位顺序调整唯一枚举值：`SystemUltraThinMaterialDark`（最浅）→ `SystemThinMaterialDark`（当前）→ `SystemMaterialDark` → `SystemChromeMaterialDark`（最深）。
3. **七个模块 bundle 是纯桩**：无自带视图/材质，运行时材质完全依赖 CC 宿主提供；因此必须保 `ERSTerHideNativeSubviews` 的 `MTMaterialView` 豁免和兜底毛玻璃两条腿。
4. **2×1 对齐仅覆盖七个连接性模块**：快捷指令 / Text Size / 电源 / 缩小模块保留原内边距；若后续要求全模块统一，需再扩参数。
5. **网络环境不稳定**：本次核对时 `api.github.com` 返回 HTML 拦截页（400），无法实时拉取 Release/CI。工具链本身正常（`gh_api.js` 走 `rejectUnauthorized:false` + 302 跟随），属于环境/代理问题，需恢复网络后再自动化发布。

---

## 7. 尝试过但失败的方案

| 方案 | 版本 | 结果 | 原因 |
| --- | --- | --- | --- |
| 关闭态也铺 `#C7C7CC` 硬灰（双态同灰） | v0.3.10 | **失败** | 硬灰在原生模糊旁严重偏色，用户反馈「背景颜色不对」。 |
| 关闭态铺「计时器灰」`colorWithWhite:1.0 alpha:0.12` | v0.3.11 | **失败（作为最终解）** | 仍是自绘叠色，与其它模块的材质对不齐；用户反馈「还是不够深」。 |
| 仅按「找得到材质」沿用 native 材质 | v0.3.12 | **失败** | 命中了嵌在隐藏父容器里的满尺寸材质，un-hide 仍不可见，且兜底毛玻璃未创建 → 「背景直接没了」。 |
| 用 `SystemUltraThinMaterialDark` 作兜底 | v0.3.12/13 | **失败（偏浅）** | 深色材质最浅档，在原生磁贴旁明显偏浅。 |
| 各模块各自居中 + 相同数值内边距 | v0.3.11 及之前 | **失败** | 各模块文字宽度不同，各自居中导致左边缘错位。 |
| 批量改调用点时误写电源 SF Symbol 为 `@"Power"` | v0.3.14 制作中 | 已当场修正 | 大小写敏感，`@"Power"` 会导致图标空白；已回正为 `@"power"`。 |

---

## 8. 下一步执行顺序

1. **【第一优先】等待真机验收反馈**
   - 请用户上机安装 `echoreborn_0.3.14_iphoneos-arm64.deb`（rootless）或 `_arm64e.deb`（roothide）。
   - 确认两件事：① 关闭态背景深度是否与原生磁贴一致；② 2×1 下七个模块左边缘是否成一条竖线。
2. **据反馈调材质档位**（若偏浅）：只改 `EREnsureConnectivityTileMaterial` 里的枚举值，往下依次 `SystemMaterialDark` → `SystemChromeMaterialDark`，每改一次出一次 ramp 对照图。
3. **处理滑块实时读数缺陷**（用户已挂起的独立任务）。
4. **其余视觉收尾**：按需统一非连接性模块的 2×1 内边距。
5. **发布流程（每次迭代固定动作）**：
   - 递增 `control` 的 `Version` 与 `Info.plist` 的 `CFBundleShortVersionString` / `CFBundleVersion`；
   - 在 `VERSIONING.md` 追加迭代行；
   - 写 `_tools/release_body_v03XX.md`；
   - `node push.js` → 等 CI（若 `wait.js` 卡死，用 `gh_api.js` 查 `actions/runs` 确认状态，勿死等）→ `download.js` 取产物 → `release.js` 发布；
   - 写 `verify_v03XX_deb.py` 并对 deb 跑符号校验，确认 0 失败。

---

### 快速定位备忘

```
工作目录   C:/Users/Administrator/WorkBuddy/ios插件开发/EchoReborn/
工具目录   C:/Users/Administrator/WorkBuddy/ios插件开发/_tools/
主源文件   EchoReborn/Tweak.xm        (16763 行)
版本文件   EchoReborn/control、EchoReborn/prefs/Resources/Info.plist、EchoReborn/VERSIONING.md
CI         EchoReborn/.github/workflows/build.yml
PAT        C:/Users/Administrator/liquidpatch_pat.txt
```

**全局唯一背景真相**：打开 = 纯白；关闭 = 磁贴自身系统材质（取不到则 Echo Reborn 自有 `SystemThinMaterialDark` 毛玻璃）；**任何时候都不叠自绘纯色**。

---

## 9. 【2026-09-11 追加】架构对齐上游：七个连接性模块迁出至 COSMIC Kit

上一节写于 v0.3.14 交接时，其中 §4.2 提到的 `EchoReborn/modules/` 七个纯桩 bundle **已不存在**。经与上游 `MoarTweaks/CCAster@800eed1` + `MoarTweaks/COSMICKit` 对比确认：上游根本没有 `EchoReborn/modules/` 这层——七个连接性 bundle 属于**另一个包** `com.futur3sn0w.cosmickit`。本次（迭代 16，v0.3.15）已按上游拆分完成迁移：

- **新增 `../COSMICKit/`**：上游骨架原样落地（`Modules/Connectivity/` 下 1 个 `ERConnectivityModules.xm` + 1 个 Makefile 声明 7 个 `BUNDLE_NAME` + 7 个只放 plist 的 Resources 目录），类名改用上游名（`ERWiFiModule` 等，cellular 是 `ERCellularDataModule`）。
- **Echo Reborn 回到上游单核形态**：`Makefile` 移除 `SUBPROJECTS += modules`，`modules/` 整目录删除（备份在 `_tools/backup_CCAster_modules_20260911.tar.gz`），`control` 的 `Depends` 追加 `com.futur3sn0w.cosmickit`，版本升至 0.3.15。
- **`Tweak.xm` 一字未改**，v0.3.14 的全部呈现层逻辑与行号表继续有效。
- **不变量**：7 个 `CFBundleIdentifier`（`com.strive.echoreborn.connectivity.*`）、安装路径、中文显示名、1×1 默认尺寸逐字不变 → 界面零像素变化。
- **关键红线**：COSMIC Kit 刻意**不定义** `ERConnectivityButtonViewController`——定义它会让 `Tweak.xm:13289` 那条死代码复活并改变长按行为。校验脚本 `_tools/verify_split_deb.py` 把这条设为硬门禁。
- 完整论证、逐项差异表与发布步骤见 `ARCHITECTURE-DIAGNOSIS.md`（第七、八节）。

**本次发布结果（2026-09-11 完成）**

- Echo Reborn **v0.3.15**：https://github.com/lvxl524/EchoReborn/releases/tag/v0.3.15
- COSMIC Kit **v0.0.1**（新建仓库 `lvxl524/COSMICKit`）：https://github.com/lvxl524/COSMICKit/releases/tag/v0.0.1
- CI 双 scheme 全绿；对**已上传资产**重新下载复核：split 校验 rootless/roothide 各 11/11，源码等价性 9/9，资产大小 4/4 MATCH。
- 发现并解决的两个发布工具坑：① `push.js` 只增不删，拆包必须用新增的 `push_mirror.js`（`sha: null` 删除远端 `modules/`）；② 下载 Release 资产必须带 `Accept: application/octet-stream`，否则拿到的是资产 JSON 元数据（约 1.5 KB）。
- 详情见 `ARCHITECTURE-DIAGNOSIS.md` 第九、十节。
