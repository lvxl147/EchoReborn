# Echo Reborn 架构差异诊断（七个连接性模块 vs 上游）

> 诊断时间：2026-09-11
> 诊断对象：`EchoReborn/`（本地 v0.3.14，`Tweak.xm` 16763 行）
> 上游基准：`MoarTweaks/CCAster@800eed1`（本地快照 `src/MoarTweaks-Echo Reborn-800eed1/`）+ `MoarTweaks/COSMICKit@3abd724`
> 结论：**七个模块与上游不一致，根因不是命名习惯，而是"包边界 + 构建粒度 + 对类名契约"三处范式性偏差。**

---

## 一、结论（前置）

1. **上游不存在"Echo Reborn 里的 modules 目录"。** 上游的七个连接性 bundle 属于**另一个仓库、另一个包**：`MoarTweaks/COSMICKit`（包标识 `com.futur3sn0w.cosmickit`）。
2. **上游是"一个源文件 + 一个 Makefile + 七个 target"。** 你在 `EchoReborn/modules/` 里做成了"七个 `.m` + 八个 Makefile + 七个 plist 目录"。
3. **上游的 bundle 是"能独立工作的真实现"，你的 bundle 是"只用于注册标识符的空桩"。**
4. **bundle identifier 两侧完全一致**（这是唯一被正确保留的契约），因此**界面显示效果与模块的物理组织方式无关**——只要 identifier 与安装路径不变，迁移不会改变一个像素。
5. **当前真正的代码级缺陷**：`Tweak.xm:13289` 通过 `NSClassFromString(@"ERConnectivityButtonViewController")` 引用了一个**上游 COSMIC Kit 才有的类**，而你的七个桩模块**没有定义这个类**，导致该安装路径**恒为死代码**。长按行为实际由另一条自研通道（`connectivityTileProxyHeld:`，`Tweak.xm:8829`）承担。

---

## 二、逐项差异对照表

| 维度 | 上游 MoarTweaks | 你的 Echo Reborn | 是否影响界面 |
| --- | --- | --- | --- |
| 仓库/包边界 | **两包**：`echoreborn`（体验）+ `cosmickit`（模块） | **单包**：`echoreborn` 内含模块 | 否 |
| 根 Makefile | `SUBPROJECTS += prefs` | `SUBPROJECTS += prefs` **+ `SUBPROJECTS += modules`** | 否 |
| 模块目录 | `COSMICKit/Modules/Connectivity/` | `EchoReborn/modules/<key>/` | 否 |
| 源文件数 | **1 个** `ERConnectivityModules.xm`（17040 B，9 个类） | **7 个** 各 4 行的宏桩 `.m` + 1 个共享 `.h` | 否 |
| Makefile 数 | **2 个**（根 1 + 模块 1，一次声明 7 个 `BUNDLE_NAME`） | **8 个**（根 1 + `modules/` 1 + 每模块 1） | 否 |
| plist 位置 | `Modules/Connectivity/Resources/ER<Kind>Module/Info.plist` | `modules/<key>/Resources/Info.plist` | 否 |
| bundle 名 / principal class | `ERAirplaneModule` / `ERWiFiModule` / `ERAirDropModule` / `ERCellularDataModule` / `ERBluetoothModule` / `ERHotspotModule` / `ERVPNModule` | `ERConnectivityAirplaneModule` / `…WiFiModule` / `…AirDropModule` / `…CellularModule` / `…BluetoothModule` / `…HotspotModule` / `…VPNModule` | **否**（identifier 未变） |
| 共享基类 | 有：`ERConnectivityBaseModule` + `ERConnectivityButtonViewController` | **无** | **是（见第四节）** |
| 模块职责 | 驱动真实硬件（`RadiosPreferences`、`CFNetwork`）+ 提供 `CCUILabeledRoundButtonViewController` 内容 | 不驱动、不读取、不绘制（`isSelected` 恒 `NO`，无 `contentViewController`） | 否（呈现由 `Tweak.xm` 代劳） |
| bundle identifier | `com.strive.echoreborn.connectivity.<kind>` | **逐字相同** | — |
| 安装路径 | `/Library/ControlCenter/Bundles` | 逐字相同 | — |
| 包依赖 | cosmickit：`Replaces/Breaks: com.strive.echoreborn (<< 0.0.2)` | 无包间关系声明 | 否 |
| firmware 上限 | 上游两侧均为 `<< 17.0` | 你已放开为 `>= 16.0`（有意扩展 iOS 17 支持） | 否 |
| plist 尺寸声明 | `ModuleSize {columns,rows}`，无 `CCSGetModuleSizeAtRuntime` | `CCSModuleSize {Portrait,Landscape}` + `CCSGetModuleSizeAtRuntime=false` | 否（等效，见第六节） |

---

## 三、根本原因

### 根因 1（主因）：包边界被打破

上游 README 明确写了这次拆分：

> "The first COSMIC Kit split **moved the extra connectivity module bundles out of the Echo Reborn package** while preserving their existing bundle identifiers."

即上游的设计意图是：**Echo Reborn 只管控制中心体验（布局/编辑/添加面板/分页/缩放/呈现），COSMIC Kit 只管可独立装卸的模块 bundle。** 你在 `EchoReborn/Makefile:27` 加了 `SUBPROJECTS += modules`，把 COSMIC Kit 的职责并回了 Echo Reborn 包，于是"两包单向依赖"变成了"单包内混合"。

### 根因 2：构建粒度走了相反的路

| | 上游 | 你 |
| --- | --- | --- |
| 消除重复的手段 | **编译期复用**：同一份 `.xm` 被 7 个 target 各编一次，`_RESOURCE_DIRS` 指向 7 个只放 plist 的目录来确定 `NSPrincipalClass` | **文件级展开**：把同一份逻辑复制成 7 个目录、7 份 `.m`、7 份 Makefile |
| 结果 | 上游新增第 8 个模块 ≈ 加 2 行 Makefile + 1 个 plist 目录 | 你需要新建一整个目录并复制 Meta 文件 |

两者是互斥的组织范式，因此 "目录结构对不上" 是结构性必然，而不是配置写错。

### 根因 3：类名契约断裂（真正会引发故障的一条）

- 上游 `EchoReborn/Tweak.xm:10318`：`NSClassFromString(@"ERConnectivityButtonViewController")`
- 你的 `EchoReborn/Tweak.xm:13289`：**同一行代码，逐字相同**
- 该类的定义在**上游 COSMIC Kit**的 `Modules/Connectivity/ERConnectivityModules.xm` 里
- 你的 `modules/` 下**没有任何文件定义它**

即：`Tweak.xm` 保留了对上游模块实现的**运行时契约**，但你把契约的另一端替换成了不含该类的桩 → `ERInstallStandaloneConnectivityDetailMethod()` 在第 13290 行 `if (!cls) return;` 处静默返回，第 5597 行的调用永远无效。

### 为什么会走到这一步（动机还原）

上游把 bundle 拆出 Echo Reborn 后，会带来一个副作用：`Tweak.xm:9118–9141` 的**「添加控制项」目录是靠扫描 `/Library/ControlCenter/Bundles` 目录发现标识符的**。不装 COSMIC Kit，那 7 个标识符在列表里根本不会出现。你为了实现"装一个 deb 就有七个连接模块"的自包含体验，把 bundle 收回包内——**这是一个为了满足安装体验而做出的架构妥协，代价就是丢掉了上游的包边界**。

---

## 四、当前问题清单（按严重度排序）

| # | 问题 | 位置 | 严重度 | 影响 |
| --- | --- | --- | --- | --- |
| 1 | `ERConnectivityButtonViewController` 未定义 → 详情安装路径恒为死代码 | `Tweak.xm:13289`、调用点 `5597` | 高 | 上游设计的长按详情能力在你的构建里完全失效；两条长按通道并存（死一条、活一条），后续维护易误判 |
| 2 | 包边界打破 → COSMIC Kit 无法独立升级/替换 | `Makefile:27` | 中 | 模块更新必须与核心同发版；上游"模块独立演化"的设计意图失效 |
| 3 | 桩模块与真实实现的语义鸿沟 | `modules/*/ERConnectivity*Module.m` | 中 | 你的 bundle 被任何第三方代码直接实例化时只能画出一个静态 glyph，无状态、无响应 |
| 4 | 构建冗余（7 份 Makefile + 7 份 .m） | `modules/` | 低 | 新增模块成本高；7 份文件间易漂移 |
| 5 | `firmware (<< 17.0)` 上限与 `Replaces/Breaks` 关系缺失 | `control` | 低 | 升级路径无约束，旧版残留无法被自动替换 |

---

## 五、调整方案

### 方案 A（推荐，完全对齐上游）

**目标形态：恢复"两包"结构，Echo Reborn 侧回到上游原貌。**

```
ios插件开发/
├── EchoReborn/                     ← 回到上游形态：SUBPROJECTS += prefs
│   ├── Makefile                 ← 删除 SUBPROJECTS += modules
│   ├── Tweak.xm                 ← 一行不改（v0.3.14 原样）
│   ├── control                  ← 追加与 cosmickit 的关系
│   └── prefs/
└── COSMICKit/                   ← 新建，照搬上游骨架
    ├── Makefile                 ← SUBPROJECTS += Modules/Connectivity
    ├── control                  ← com.futur3sn0w.cosmickit
    └── Modules/Connectivity/
        ├── ERConnectivityModules.xm          ← 合并现有 7 个桩
        ├── Makefile                            ← 7 个 BUNDLE_NAME，一个文件
        └── Resources/ER<Kind>Module/Info.plist × 7
```

**执行步骤**

1. 新建 `COSMICKit/`（独立目录，或独立仓库 `lvxl524/COSMICKit`），按上表落 4 类文件。
2. 把现有 `modules/ERConnectivityModule.h` 的内容与 7 个 4 行 `.m` 合并为**单个** `ERConnectivityModules.xm`。
3. `Modules/Connectivity/Makefile` 用上游写法：7 个 `BUNDLE_NAME` 共用同一 `.xm`，`_RESOURCE_DIRS` 各指一个 plist 目录。
4. `EchoReborn/Makefile` 删除第 24–27 行的 `SUBPROJECTS += modules` 及其注释；删除 `EchoReborn/modules/` 整目录。
5. `EchoReborn/control` 增加 `Recommends: com.futur3sn0w.cosmickit`（或 `Depends:`，见第七节决策点 1）。
6. `.github/workflows/build.yml` 增加 cosmickit 的构建与产物上传（同 workflow 两个 job，或复用矩阵）。
7. 校验：沿用 `_tools/verify_v03XX_deb.py` 的符号门禁，对两个 deb 分别跑。

### 方案 B（最小改动，只对齐目录与构建形态，保留单包）

- 把 `modules/` 改名为 `Modules/Connectivity/`
- 7 个 `.m` + 8 个 Makefile → 1 个 `.xm` + 2 个 Makefile（7 个 `BUNDLE_NAME`）
- plist 迁至 `Resources/ER<Kind>Module/`
- **保留** `SUBPROJECTS += modules`（仍打成一个 deb）

结果：目录结构、构建粒度、命名与上游一致；仅"包边界"一条保留差异（且是你显式想要的）。

### 不变量（两个方案都必须逐字满足，否则界面会变）

| 项 | 必须保持的值 |
| --- | --- |
| `CFBundleIdentifier` ×7 | `com.strive.echoreborn.connectivity.{airplane,wifi,airdrop,cellular,bluetooth,hotspot,vpn}` |
| 安装路径 | `/Library/ControlCenter/Bundles` |
| `CFBundleExecutable` ⇄ `NSPrincipalClass` | 二者必须同名，且类必须在 bundle 内可实例化 |
| 默认尺寸 | 1×1，`CCSGetModuleSizeAtRuntime = false` |
| `CFBundleDisplayName` | 中文名（飞行模式/无线局域网/隔空投送/蜂窝数据/蓝牙/个人热点/VPN） |
| `Tweak.xm` | v0.3.14 内容一字不改（呈现层是界面的唯一来源） |
| 偏好键 | `COSMICDuplicateFamilies` 不改名（已保存布局依赖它） |

> 依据：界面完全由 `Tweak.xm` 的呈现层产生（`ERFirstModuleMaterialSurface`/`EREnsureConnectivityTileMaterial`/`ERConvertedTileBackgroundMaterial`/`ERSetConnectivitySelectedSurface`/`ERLayoutOwnedCompactPresentation` 等，见 HANDOVER §4.1）。bundle 只承担两件事：**在扫盘目录里存在**、**principal class 可实例化不崩溃**。

---

## 六、需要特别评估的两处风险

### 风险 1（高）：对齐类名会让一条死代码"复活"

若采纳上游类名（`ERWiFiModule` 等）并补齐 `ERConnectivityBaseModule` + `ERConnectivityButtonViewController`：

- 好处：`Tweak.xm:13289` 的契约被修复，行为与上游一致。
- **风险：该路径当前是死的，一旦复活，`ERInstallStandaloneConnectivityDetailMethod()` 会给新类装上 `presentedViewControllerForContentModuleDetailClickPresentationInteractionController:`，长按行为可能改变** → 与"界面显示效果完全不变"冲突。

**必须二选一：**
- (a) **不实现该基类/控制器**，只保留 7 个模块类 → 死代码维持现状，界面绝对不变；
- (b) 实现并**上机专项验证长按行为**（与 v0.3.14 逐帧对比）后再合入。

### 风险 2（低）：plist schema 差异

上游用 `ModuleSize {columns,rows}`，你用 `CCSModuleSize {Portrait,Landscape}` + `CCSGetModuleSizeAtRuntime=false`。两者在各自目标系统上等效。**建议保留你的键**（已被 v0.3.x 各版验证），并把它标注为**有意的偏离**，而不是回退成上游写法。

---

## 七、执行前需确认的三个决策点

1. **包边界**：方案 A（拆两包，真正对齐）还是方案 B（保单包，只对齐形态）？
2. **类名**：采用上游名（`ERWiFiModule`…）还是保留现名（`ERConnectivityWiFiModule`…）？
3. **编译策略**：一个 `.xm` 被 7 个 target 各编一次（上游做法，每个 bundle 含全部类，会有 duplicate class 日志噪音），还是用每 target `-D` 宏只编一个类（更干净，但偏离上游）？

第 1、2 项确定后即可动手；第 3 项只影响二进制干净度，默认取"与上游一致"。

---

## 八、执行记录（2026-09-11）

### 已确认的三项决策

| 决策点 | 结论 |
| --- | --- |
| 包边界 | **拆为两包**：新建 COSMIC Kit 独立包，Echo Reborn 回到上游单核形态 |
| 模块类名 | **改用上游名**：`ERAirplaneModule` / `ERWiFiModule` / `ERAirDropModule` / `ERCellularDataModule` / `ERBluetoothModule` / `ERHotspotModule` / `ERVPNModule`（cellular 特别注意是 `CellularData`） |
| 编译策略 | **与上游一致**：1 个 `.xm` 被 7 个 target 各编一次，每个 bundle 含全部 7 个类，由 plist 的 `NSPrincipalClass` 选定 |

### 实际改动清单

**新增 `ios插件开发/COSMICKit/`**

| 文件 | 说明 |
| --- | --- |
| `Makefile` | `SUBPROJECTS += Modules/Connectivity`（含 common.mk 先于 aggregate.mk 的注释） |
| `control` | `com.futur3sn0w.cosmickit` 0.0.1，`Depends: firmware (>= 16.0)`，`Replaces/Breaks: com.strive.echoreborn (<< 0.3.15)` |
| `README.md` / `.gitignore` / `.github/workflows/build.yml` | 双 scheme（rootless/roothide）CI，产物命名 `com.futur3sn0w.cosmickit_*_iphoneos-arm64[_arm64e]_<scheme>.deb` |
| `Modules/Connectivity/ERConnectivityModules.xm` | 单源文件 7 类；方法体用 `ER_CONNECTIVITY_BODY(SYMBOL, ACCENT)` 宏逐类展开；刻意不定义基类与 ButtonViewController（见下"保留的有意偏离"） |
| `Modules/Connectivity/Makefile` | 7 个 `BUNDLE_NAME` 共用同一 `.xm`；`_RESOURCE_DIRS` 各指一个 plist 目录；`_INSTALL_PATH = /Library/ControlCenter/Bundles` |
| `Modules/Connectivity/Resources/ER<Kind>Module/Info.plist` ×7 | 保留现有键位（`CCSModuleSize` 1×1 + `CCSGetModuleSizeAtRuntime=false` + `MinimumOSVersion 16.0` + 中文 `CFBundleDisplayName`），仅 `CFBundleExecutable` / `CFBundleName` / `NSPrincipalClass` 改为上游类名 |

**修改 `EchoReborn/`**

| 文件 | 改动 |
| --- | --- |
| `Makefile` | 删除 `SUBPROJECTS += modules` 及原注释，替换为指向 COSMIC Kit 的说明 |
| `modules/` | **整目录删除**（已备份：`_tools/backup_CCAster_modules_20260911.tar.gz`，38 个文件） |
| `control` | `Version: 0.3.15`；`Depends` 追加 `com.futur3sn0w.cosmickit` |
| `prefs/Resources/Info.plist` | `CFBundleShortVersionString 0.3.15` / `CFBundleVersion 29` |
| `VERSIONING.md` | 追加迭代 16 行 |
| `Tweak.xm` | **一字未改** |

### 保留的有意偏离（均已论证）

1. **`ERConnectivityButtonViewController` 不定义** —— 定义它会让 `Tweak.xm:13289` 的死代码复活、改变长按行为，违背"界面完全不变"。校验脚本将此设为硬门禁。
2. **强调色保留现状**（飞行模式橙、蜂窝数据/个人热点绿、其余蓝），不用上游的全蓝 —— 磁贴真实配色由 `ERConnectivityAccentColorForIdentifier` 负责。
3. **plist 键位保留现版**（`CCSModuleSize` + `CCSGetModuleSizeAtRuntime=false`），不回退为上游的 `ModuleSize {columns,rows}` —— 已被 v0.3.x 各版验证。
4. **`CFBundleDisplayName` 保留中文**（目录标签与「添加控制项」名称的来源），`CFBundleName` 改为类名（上游风格；`Tweak.xm:9135` 注释明确忽略该键）。

### 验证

- 新增 `_tools/verify_split_deb.py`，两种模式：
  - `baseline <旧 echoreborn deb>`：固化拆分前契约。
  - `split <新 echoreborn deb> <新 cosmickit deb>`：Echo Reborn 侧 0 个 ControlCenter bundle + identifier 字面量齐全；COSMIC Kit 侧 7 个 bundle 的 identifier/显示名/尺寸/`MinimumOSVersion` 与基线逐项一致；模块 dylib 含各自 SF Symbol 且**不含** `ERConnectivityButtonViewController`。
- **baseline 模式已用 `v0314_release/echoreborn_0.3.14_iphoneos-arm64.deb` 实测通过（7 passed, 0 failed）**，契约记录与真实产物完全吻合。
- split 模式待下一次 CI 构建出 deb 后运行（见下）。

### 下一步（发布 v0.3.15 + COSMIC Kit 0.0.1 时）

1. Echo Reborn 仓库 push → CI 出 `echoreborn_0.3.15_*.deb`；COSMIC Kit 仓库（新建 `lvxl524/COSMICKit` 或先本地打包）出 `cosmickit_0.0.1_*.deb`。
2. 对两个 deb 跑 `python verify_split_deb.py split <echoreborn.deb> <cosmickit.deb>`，必须 0 失败。
3. Release 同时发布两个包，说明文案写明：**升级顺序无要求**——cosmickit 的 `Breaks` 会先移除旧 Echo Reborn，新 Echo Reborn 的 `Depends` 会拉入 cosmickit，dpkg 自动收敛。
4. 真机验收：七磁贴外观、2×1 竖线对齐、长按面板与 v0.3.14 逐帧一致（长按路径本版本零改动，应完全相同）。
5. 上机后如出现 duplicate class 日志（预期内、与上游一致），确认仅为日志噪音即可；若某机型异常，回退方案是改用每 target `-D` 宏只编一个类（见第七节决策点 3）。

---

## 九、上屏一致性审计（"显示效果 = 源代码"门禁，2026-09-11）

要求：**最终显示效果必须与源代码严格一致**。为此建立了三层门禁，前两层已在本机通过：

### 第 1 层：源码等价性审计（✅ 已通过，9 passed / 0 failed）

脚本 `_tools/verify_source_equiv.py`，可随时重跑（无需设备、无需构建，只依赖备份包与 COSMICKit 源树）。三项门禁：

| 门禁 | 结果 | 证明内容 |
| --- | --- | --- |
| 类表 | OK | 新 `.xm` 恰好定义 7 个迁移类，SF Symbol 与强调色与旧桩**逐字一致**（飞行模式 `airplane`/橙、蜂窝数据 `antenna.radiowaves.left.and.right`/绿、热点 `personalhotspot`/绿、wifi/airdrop/bluetooth/vpn 蓝） |
| 方法体 | OK | 四个选择器（`iconGlyph` / `selectedColor` / `isSelected` / `setSelected:`）与全部语义点（`switch.2` 兜底、`isSelected` 恒 `NO`、空实现 + `__unused`、`ACCENT` 参数）两侧均在 |
| plist | OK | 7 份 Info.plist 与旧版**仅** `CFBundleExecutable` / `CFBundleName` / `NSPrincipalClass` 三个键不同（即类名更换本身）；`CFBundleIdentifier`、中文显示名、`CCSModuleSize` 1×1、`CCSGetModuleSizeAtRuntime=false`、`MinimumOSVersion 16.0` 逐字节相同 |

另核实：`EchoReborn/Tweak.xm` 修改时间为 2026-09-10 23:13（v0.3.14 构建时），本次迁移**未触碰**——呈现层（磁贴背景材质、图标、文字、布局、长按面板）与 v0.3.14 源码完全相同。

### 第 2 层：产物契约校验（脚本就绪，待 CI 产物）

脚本 `_tools/verify_split_deb.py`（baseline 模式已用真实 0.3.14 deb 实测 7/7 通过）。CI 出包后执行：

```sh
python _tools/verify_split_deb.py split <新echoreborn.deb> <新cosmickit.deb>
```

断言：Echo Reborn deb 0 个 ControlCenter bundle 且 7 个 identifier 字面量仍在；COSMICKit deb 的 7 个 bundle identifier/显示名/尺寸/最低系统与基线一致；模块 dylib **不含** `ERConnectivityButtonViewController`（死代码保持死状态 → 长按行为不变）。

### 第 3 层：真机逐帧对比（唯一的人工确认项）

1. 同一设备、同一手势，录 v0.3.14 与 v0.3.15 + cosmickit 各一次。
2. 判定：七磁贴开/关底色深度、图标、中文文案、2×1 竖线对齐逐帧一致；长按面板弹出路径无差异。
3. 唯一预期差异：Console 中 duplicate class 日志（每 bundle 含全部 7 类，与上游行为一致），仅日志噪音，不产生任何视觉影响。

### 一致性链条总结

```
源码层  verify_source_equiv.py   9/9 ✅  新旧源码逐字等价（除类名）
产物层  verify_split_deb.py      待 CI   deb 内容与源码、与基线一致
真机层  录屏逐帧 A/B             待用户  上屏效果与源码最终确认
```

三层全绿 ⇔ 「显示效果与源代码一致」成立。任何后续改动只要重跑第 1、2 层脚本即可自动守住这条红线。

---

## 十、发布记录（2026-09-11）

| 项 | 值 |
| --- | --- |
| Echo Reborn | **v0.3.15** — https://github.com/lvxl524/EchoReborn/releases/tag/v0.3.15 （release id 386571126） |
| COSMIC Kit | **v0.0.1** — https://github.com/lvxl524/COSMICKit/releases/tag/v0.0.1 （release id 386570967，新建仓库 `lvxl524/COSMICKit`） |
| Echo Reborn commit | `e3829e9d067689c3d91a4ec0eec7219203148d1a`（含远端 `modules/` 30 个路径删除） |
| COSMIC Kit commit | `847052c8d7794348c866b6941c3bd5289f31457e` |
| CI runs | Echo Reborn `34521506469`、COSMIC Kit `34521398369` —— 均 rootless + roothide 双绿 |

### 发布产物

| 包 | rootless | roothide |
| --- | --- | --- |
| `com.strive.echoreborn_0.3.15_iphoneos-arm64_*.deb` | 415,934 B | 418,364 B |
| `com.futur3sn0w.cosmickit_0.0.1_iphoneos-arm64_*.deb` | 7,038 B | 6,962 B |

### 发布后复核（对已上传资产重新下载校验，非本地产物）

```
verify_split_deb.py  split  rootless  →  11 passed, 0 failed
verify_split_deb.py  split  roothide  →  11 passed, 0 failed
verify_source_equiv.py                →   9 passed, 0 failed
download_release_assets.js            →  4/4 资产大小 MATCH
```

即：**GitHub 上供下载的 deb，与本地源码、与 v0.3.14 基线三方一致。**

### 新增/复用的发布工具（`_tools/`）

| 脚本 | 用途 |
| --- | --- |
| `push_mirror.js` | 镜像推送：本地目录 → 远端单提交，**并用 `sha: null` 删除远端已不存在的文件**（`push.js` 只增不删，这是拆包必需的） |
| `download_release_assets.js` | 从 Release 下载资产（必须带 `Accept: application/octet-stream`，否则返回资产 JSON 元数据而非二进制） |
| `verify_split_deb.py` / `verify_source_equiv.py` | 上文第二、三层门禁 |
| `push.js` / `wait.js` / `download.js` / `release.js` / `logs.js` | 原有流水线，复用 |
