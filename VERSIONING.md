| 91 | 1.0.9-191 | 基于 190 按用户要求删除：① backboardd 渲染说明 footer ② 锁屏快捷按钮（QuickActions.Enabled 玻璃注入子系统：assoc keys/qa helpers/inject/remove/reconcile/%hook UIVisualEffectView，保留 Soko 缩进特性）③ 渐变阴影+字体颜色模式+渐变颜色1-5+选择背景（ERDIGradientColors/ERColorAtStop/cols 块/辉光 if-else/ERPreferenceStringFor 死代码一并清除）④ 锁屏时间组（开关+6滑杆）+选择字体（190 中已是死设置，仅删 UI）。版本 1.0.9-191/1001041。 |
| 92 | 1.1.1 | 系统增强两功能失效修复诊断：录屏无延迟（ctor CC-RECORD 块）与隐藏锁屏音乐（%hook CSCoverSheetViewController）均挂在主开关 Enabled 门之后，实测两功能日志全零而 DI 类（不受该门控）正常——主开关被 cfpresd 判为 NO 嫌疑最大。ctor 增加主开关读值/CC-RECORD 初始化标记，音乐胶囊钩子增加 MC-HIT 命中标记。版本 1.1.1/1001042。 |
| 93 | 1.1.2 | 录屏无延迟 iOS 27 适配探测：实锤 SBControlCenterController 已无 startRecordingCountdown（has=0）。扫描定时器改静态持有+心跳日志；ctor 新增 CC-PROBE（SBCC 全部含 ecord 方法 + 全类表含 Recording 类名），下一轮日志确定新钩点。版本 1.1.2/1001043。 |
| 94 | 1.1.3 | 录屏无延迟第二轮探测：设备实为 iOS 17.2；SBControlCenterController 173 方法零 ecord（老钩点彻底消失）。新增 CC-PROBE2：对含 Recording/ScreenRecord 类名的类枚举含 ecord/ountdown/tart 的方法，锁定 SBRecordingIndicatorManager 等新候选。版本 1.1.3/1001044。 |
| 95 | 1.1.4 | 录屏新钩点时间线：RCPScreenRecorder（start/stopRecording）日志钩子（msgSendSuper 透传），定位按钮按下→倒计时→startRecording 的时间间隔；扫描心跳确认无任何类再有老方法。版本 1.1.4/1001045。 |
| 96 | 1.1.5 | 修复 1.1.4 崩溃循环：RCP 钩子从 objc_msgSendSuper 转发（父类无实现 → unrecognized selector → SpringBoard 崩溃循环进安全模式）改为标准 MSHookMessageEx orig 捕获透传，行为零改动仅日志。版本 1.1.5/1001046。 |
| 97 | 1.1.6 | 崩溃循环真凶修复：1.1.4/1.1.5 的崩溃并非 RCP msgSendSuper（背锅），而是 60s 扫描器在后台线程对懒加载新类 RPControlCenter* 自动 MSHookMessageEx，与主线程使用竞态崩溃。扫描器降级为只记录候选类名+方法清单（绝不自动挂钩）。版本 1.1.6/1001047。 |
| 98 | 1.1.7 | 稳定版：彻底删除 60s 后台全类扫描（三连崩溃元凶：后台线程触碰懒加载类触发 +initialize 的 UIKit/CA 副作用 → QuartzCore 后台断言 abort，崩溃栈三版一致）。RCP 安全日志钩子保留。版本 1.1.7/1001048。 |
| 99 | 1.1.7-1 | 探测版：QABTN 定时器内嵌 CC-BTN-PROBE（控制中心打开时扫描 SBControlCenterWindow 的 UIControl，打印类名/target/Action 含 ecord|Record 的控件）——定位 iOS 17.2 录屏按钮的事件接收者。版本 1.1.7-1/1001049。 |
| 100 | 1.1.7-2 | 录屏无延迟正式适配：对照 CCRecordNoDelay 0.1.0 逆向实锤，iOS 17.2 宿主 = RPControlCenterClient（RPControlCenter 家族，1.1.5 日志截断的 RPControlCen 即它）。ctor 主线程挂 RPControlCenterClient + SBControlCenterController 双宿主，3s 主队列延迟重试兜底懒加载；无延迟路径 startRecordingWithHandler:/startRecord 与参考插件一致。版本 1.1.7-2/1001050。 |
| 101 | 1.1.7-3 | 双探测：① MC-FULLDUMP 锁屏 8s 后全窗口全视图无过滤 dump（抓 iOS 17.2 系统音乐卡片真名——关键词表全落空）；② CC-PROBE3 列 RPControlCenterClient/SBControlCenterController 的 dismiss 方法与 sharedInstance 入口（参考插件用 dismissAnimated: 收起，实测 RPCC 不响应，找正确落点）。版本 1.1.7-3/1001051。 |
| 102 | 1.1.7-4 | 录屏收起时序实现（用户需求：点录屏→先收起 CC→收起后开录，不录到 CC 画面）：① 立即 SBCC sharedInstance dismissAnimated:YES 收起（1.1.7-3 探测实锤的落点）② 0.4s 后才 startRecordingWithHandler/startRecord 开录。MC-FULLDUMP 保留（等用户锁屏音乐状态抓卡片真名）。版本 1.1.7-4/1001052。 |
| 103 | 1.1.7-5 | MC-FULLDUMP 改写独立文件 /var/mobile/Library/Accessibility/echoreborn-mcful.log（主日志轮转吞掉大 dump 的教训；fopen "w" 每 respring 覆盖；上限提至 1200 行、尺寸门 40x10）。版本 1.1.7-5/1001053。 |
| 104 | 1.1.7-6 | MC-FULLDUMP 可重试 3 次（每次锁屏触发，8s 后执行；文件改追加累积，解锁态 dump 不覆盖锁屏态）。1.1.7-5 实测：dump 落在解锁态（SBCoverSheetWindow HID）。版本 1.1.7-6/1001054。 |
| 105 | 1.1.7-7 | 隐藏锁屏音乐正式修复（iOS 17.2 实锤规则）：系统音乐卡 = NCNotificationListView 内顶部 Live Activity 卡（402×167@y571），识别特征 CSActivityItemContentView（宽>380/高120-220）+ 子树含 _UIScenePresentationView → 隐藏其所在 NCNotificationListCell，开关关闭自动恢复。版本 1.1.7-7/1001055。 |
| 106 | 1.1.8-1 | 音乐胶囊左/右滑动切歌：开关 MusicCapsule.SwipeEnabled（底部组件页音乐胶囊卡片内、启用下方，默认关）；胶囊视图挂左/右滑动手势（默认禁用，开关控制启停），手势触发 MRMediaRemoteSendCommand NextTrack=4/PreviousTrack=5（与播放暂停同通道，SBMediaController 兜底）；手势只在胶囊视图上（hitTest 天然限制范围）。版本 1.1.8-1/1001056。 |
| 107 | 1.1.8-2 | 三修：① 手势无反应根因 = 胶囊 hitTest 对空白处返回 nil 透传，swipeEnabled 时改返回胶囊自身（触摸可达手势）；② 隐藏失效根因 = 切歌后系统重建媒体卡（新 cell 可见），refresh 收到 MR 变更后 0.6s/1.6s 两次再断言隐藏；③ 滑动开关行加 SF Symbol 图标 arrow.left.arrow.right。版本 1.1.8-2/1001057。 |
| 108 | 1.1.8-3 | 音乐胶囊液态玻璃背景：液态玻璃页新增“底部控件”开关（MusicCapsule.LiquidGlassEnabled 默认关）；开 = 胶囊背景 LGLiveBackdropView（控制中心同款渲染，lgTrackGlass 注册）；关 = 深色原始态；去浅色：UIBlurEffectStyle Regular→SystemUltraThinMaterialDark 固定深色。版本 1.1.8-3/1001058。 |
| 109 | 1.1.8-4 | 胶囊玻璃不渲染修复：lgTrackGlass 材质视图参数由 nil 改为胶囊自身（VolumeHUD 同款），玻璃圆角/连续曲率/masksToBounds 对齐 clipView，创建帧改用 clipView.bounds。版本 1.1.8-4/1001059。 |
| 110 | 1.1.8-5 | 玻璃诊断文件化：apply 状态写 mcful.log（创建失败/成功/帧/隐藏态/背景色全记录）；layoutSubviews 液态帧跟随。版本 1.1.8-5/1001060。 |
| 111 | 1.1.8-6 | 胶囊玻璃根因修复：LGCreateRegisteredGlass 按宿主注册表校验前缀，MusicCapsule 不在表内 → 工厂拒绝返回 nil。改用合法宿主 ControlCenter（filter echoreborn.liquidglass.cc，即用户指定的控制中心渲染），lgTrackGlass 同步。版本 1.1.8-6/1001061。 |
| 112 | 1.1.8-7 | 两处补：① 模块管理子页左侧图标不显示 —— iOS 17.2 原生 PSSwitchCell 不渲染 specifier 的 iconImage，新增运行时子类 ERModuleIconSwitchCell（refreshCellContentsWithSpecifier 里显式写 imageView + 自绘靠左布局）并给模块行指定 cellClass；② 快捷指令行 glyph 兜底次序修正（先 sparkles 再文本字形）。版本 1.1.8-7/1001062。 |
| 113 | 1.1.8-8 | 快捷指令图标根因定位与修复：实测快照数据 —— 有图标的行 glyph=0xE82D/0xE877/0xF086 等可用；16 行素色方块的 glyph 全是 0xF000（映射不出来），而旧兜底会「画 glyph 字符本身」，0xE000~0xF8FF 私有区画出来是全透明图，反而盖掉 sparkles 兜底。改为对齐「快捷指令」App 的取图次序：自定义图片 > ZSYMBOLNAME 符号名 > ZEMOJI > glyph 映射 > sparkles（文本兜底只允许 ch<0xE000）。扫描器新增：读 SYMBOL/EMOJI 列、自定义图片写 shortcut-icons/<uuid>.png、ZSHORTCUTICON 表结构+样例行 dump、数据库整库复制到日志目录供本地 sqlite 分析、图标来源命中统计；探针改为枚举 WorkflowKit 全部 Icon/Workflow 类方法面 + WFDatabase 方法面 + 实测 glyph→符号映射。版本 1.1.8-8/1001063。 |
| 114 | 1.1.8-9 | 颜色解析根因修复（本次截图实测发现）：数据库颜色是 0xRRGGBBAA 无符号 32 位，读成 long long 后高位为负（如 0xA9A9A9FF = -1448498689），旧判断 value<=0 直接判「无颜色」→ 这些行/磁贴一律退回默认蓝。改为按 32 位掩码取值（等于 0 才算无颜色）。同步修 Tweak.xm 的 ERShortcutColorFromValue 与 ERShortcutIconImage（优先 ZSYMBOLNAME 符号名）。 |
| 115 | 1.1.8-10 | 快捷指令图标真根因（本地拉回 Shortcuts.sqlite 实锤）：ZSHORTCUTICON 只有 ZBACKGROUNDCOLORVALUE + ZGLYPHNUMBER 两列（无符号名、无图片）；探针实测 glyph 0xF000 → app.2.stack.3d，但该符号在 iOS 17.2 上 systemImageNamed 取不到图。而这 16 行全部是「来自 App / 云端链接」的快捷指令 —— 11 行带 ZASSOCIATEDAPPBUNDLEIDENTIFIER（com.xiaomi.mihome / com.byd.BYDi / com.opa334.CraneApplication），5 行 source=ShortcutSourceCloudLink。因此真图标 = 关联 App 的图标（与 Actra 的 bundleIdentifier + _applicationIconImageForBundleIdentifier:format:scale: 一致）。取图次序改为：自定义图片 > 符号名 > glyph 映射 > 关联 App 图标（满铺）> wand.and.stars（Actra 兜底）。扫描器新增读 ZASSOCIATEDAPPBUNDLEIDENTIFIER。设置页与 Tweak.xm 控制中心磁贴同步。版本 1.1.8-10/1001065。 |
| 116 | 1.1.8-11 | 关联 App 图标取图链路加宽 + 逐条诊断：UIImage _applicationIconImageForBundleIdentifier:format:scale: 遍历 format 0..12；再退 LSApplicationProxy iconDataForVariant: 0..4；再退 KVO icon/iconImage/primaryIconData。每个 bundleId 与每条快捷指令各记一条日志（iconapp: / iconrow:），用于确认还有哪些没落地（11 条有 bundleId、5 条 ShortcutSourceCloudLink 无 bundleId）。版本 1.1.8-11/1001066。 |
| 117 | 1.1.8-12 | 0xF000 真图标落定（用户指正 + 设备 CoreGlyphs 实锤）：用户明确「这些不是 App 快捷指令，全部是快捷指令 App 自己的系统图标」，并给出截图 —— 图标选择器「符号」分组的第一个图标（两个 45° 圆角方块上下叠放描边）。本地核对设备 CoreGlyphs.bundle：symbol_order.plist 共 6153 个符号，**没有 app.2.stack.3d**（WorkflowKit 字形表却返回它），而 name_aliases.strings 里写着 square.2.stack.3d -> square.2.layers.3d —— SF Symbols 已把这族符号改名，name_availability.plist 里 square.2.layers.3d 属于 2022（iOS 16+，本机存在）。因此 0xF000 是「占位字形」：有绑定 App 就取 App 图标，没有绑定（图图记账截屏记账/截屏问豆包/盒子兑换主题-夕颜/验证码提取/双马尾）就画 square.2.layers.3d。新增 ERShortcutSymbolCandidates 候选链（原名 → .stack.3d 换 .layers.3d → app. 前缀换 square. → 0xF000 专属 square.2.layers.3d），systemImageNamed 逐个试，谁先出图用谁；Tweak.xm（控制中心磁贴 120×120）与设置页（40×40）同源同逻辑，图标尺寸不变。另加一次性可视化自检：候选链逐个渲染成 _candN.png、每一行最终图标渲染成 _rowNN.png 落到 shortcut-icons/，配合 symchain/symcand/rowshot 日志直接看图核对。版本 1.1.8-12/1001067。 |
| 118 | 1.1.8-13 | 图标改为「识别」而不是「打补丁」（用户要求：以后还会新增快捷指令，不能一条一条适配）。上一版给 0xF000 写死 square.2.layers.3d 仍是特例，已删除。改为对齐 Actra 的做法——**直接让 WorkflowKit 自己把图标画出来**：扫描器（在设置进程，能读 Shortcuts 库）dlopen WorkflowKit + CoreData，用 `WFDatabase -initWithStoreDescription:runMigrationsIfNecessary:useLockFile:error:`（runMigrations/useLockFile 传 NO，只读、不改动用户数据库）打开 `/var/mobile/Library/Shortcuts/Shortcuts.sqlite`，再 `-sortedVisibleWorkflowsByName` 拿全部 workflow，对每条取 `attributionIcon / symbolName / bundleIdentifier`，并用 NSInvocation 调 `attributionIconWithSize:scale:rounded:`（rounded=YES/NO 各取一张）拿到 UIImage。自动分辨它给的是「完整圆角图标」还是「透明底前景符号」：采样四角/四边中点/中心的 alpha，中心不透明且四边中点≥3 个不透明判为完整块（iconFull=YES，直接满铺），否则当前景（画在快捷指令自己的底色上）。落盘 shortcut-icons/<uuid>.png 供设置页读，同时把同一张 PNG 以 iconPNG 写进 plist 供控制中心（SpringBoard 读不到文件）使用。「快捷指令」App 画什么我们就贴什么——系统符号、关联 App 图标、还是字形表里叫不出名字的符号，全部自动识别，不再有按 glyph 分情况的代码；glyph→SF Symbol 只保留通用的「改名兜底」（原名字 → .stack.3d 换 .layers.3d → app. 前缀换 square.），作为 WorkflowKit 不可用时的后备。版本 1.1.8-13/1001068。 |
| 119 | 1.1.8-14 | WFDatabase 接口探测（纯诊断）：1.1.8-13 实测 WFDatabase 能建起来但 `sortedVisibleWorkflowsByName` 取不到列表。探针改为：两条入口各建一个库对象（`+defaultDatabase` 与 `initWithStoreDescription:runMigrationsIfNecessary:useLockFile:error:`），把 WFDatabase 全部「无参、像取列表」的方法逐个实调并打印返回类型/条数，命中的第一条 workflow 再 dump 类名、图标相关方法面、attributionIcon 系列签名。同时日志再次实锤 glyph 0xF000 → `app.2.stack.3d` 而 `systemImageNamed:` 取不到图。版本 1.1.8-14/1001069。 |
| 120 | 1.1.8-15 | 图标解析收拢到一处 + 去掉「占位字形」这个伪概念（本次图证 + 逻辑修正）。① 图证：把候选符号渲染出来对比，`square.2.stack.3d` / `square.2.layers.3d` 画出来正是用户截图里箭头所指的「两个 45° 圆角方块上下叠放」，确认目标符号就是它；同时发现 1.1.8-13 把 0xF000 当「占位字形」直接跳过符号链，导致这几行白掉到 wand.and.stars —— 已去掉该分支。② 架构：图标解析**只发生在扫描器一处**（`ERResolveShortcutIcon`），规则完全按数据分情况、不含任何按 glyph 的分支：① WorkflowKit 渲染结果 → ② 用户自定义图片 → ③ 有 ZASSOCIATEDAPPBUNDLEIDENTIFIER 就取该 App 图标 → ④ 字形→系统符号（通用改名候选链：原名字 / `.stack.3d`→`.layers.3d` / `app.`→`square.`）→ ⑤ wand.and.stars；结果落成一张 PNG（`iconPNG` 发布给控制中心、`<uuid>.png` 给设置页）并带 `iconFull`（完整圆角块=满铺 / 白色前景符号=叠底色）。③ App 图标加「完整圆角方块」校验（采样四角/四边中点/中心 alpha）：同一 bundleId 的 format/variant 里常有单色符号版，校验不过就换下一个取法，修掉 1.1.8-13 里米家/比亚迪图标被画成单色描边的问题。④ 设置页与 Tweak.xm 删掉全部重复的取图逻辑（符号名映射/App 图标/文本字形），只负责按 `iconFull` 画图；Tweak.xm 缓存键改按 uuid+iconFull+图长。版本 1.1.8-15/1001070。 |
| 121 | 1.1.8-16 | 修 1.1.8-15 的编译失败：prefs 目标开了 -Werror，收拢解析逻辑后 `ERWriteShortcutIconFile` 变成未使用函数（-Wunused-function）直接报错。删除该函数。功能与 1.1.8-15 完全相同（1.1.8-15 因此没有产出可用 deb）。版本 1.1.8-16/1001071。 |
| 122 | 1.1.8-17 | 修复打开快捷指令子页面闪退（用户反馈，崩溃报告 Preferences-2026-10-15-030904.ips 实锤：`viewDidLoad → _dispatch_once_callout → objc_retain` EXC_BAD_ACCESS）。两个元凶都在我加的诊断代码里：① ERWFKitProbeOnce 会把 WFDatabase 上所有「无参、像取列表」的方法逐个实调——其中 `remoteContextDidSave` 是 block 属性、`createLibraryFromCurrentDatabaseSnapshot` 会触发 CoreData 快照，`@try/@catch` 拦不住 EXC_BAD_ACCESS；② 扫描器里的 WorkflowKit 通道（WFDatabase + sortedVisibleWorkflowsByName）——探针已实锤该系统上取不到列表，纯属死代码却仍会执行。**两处全部删除**，同时删除 viewDidLoad 里的探针调用。保留的是已图证正确的确定性链路：自定义图片 → 关联 App 图标（带「完整圆角方块」校验）→ 字形→系统符号（通用改名候选链）→ wand.and.stars。另外给每条快捷指令的图标解析包 @try/@catch，异常只记日志不再拖垮 Preferences。版本 1.1.8-17/1001072。 |
| 123 | 1.1.8-18 | 设置页信息架构改造（用户三项需求 + 图标放大）。① 图标：磁贴大小不变（40×40pt，即用户截图里的 53×53px），只把符号**真实墨迹**放大到宽 86% / 高 95% 并居中 —— 新增 ERInkBoundsOfImage 量墨迹包围盒（SF Symbol 画布内边距差异极大，同一个绘制系数下不同符号占比能从 35% 到 60%，所以必须按墨迹算而不是拍系数），按 iconFile 缓存；**只改设置页绘制代码，扫描器产出的 PNG 与 Tweak.xm 一行未动，控制中心磁贴因此完全不变**。② 删除右上角「重新扫描」及 rescan:。③ 扫描提速：删掉 ERCopyStoreForDiagnostics（每次打开都复制 11.3MB Shortcuts.sqlite + 3.5MB WAL，是「慢一拍」的头号元凶）与 ERDumpIconSchema；ERShortcutLog 改为复用 NSFileHandle（原来每条日志都开合一次文件，一次扫描近百条）；viewDidLoad 改为先用缓存秒画列表、把扫描推到下一个 runloop 回合再跑。④ 信息架构：主页只剩「显示控制项（N）」单个分区、纯展示（不打钩、不响应点击，加入/移除逻辑以 ERShortcutPersistVisible C 函数形式保留备用）；右上角改「添加」，新增 ERShortcutAddController 子页面 —— 顶部固定 UISearchBar（只过滤未显示列表，支持名称/uuid 前缀匹配 + 取消按钮）、下面是「未显示控制项（N）」、点一条即写入 visibleUUIDs 并弹回主页；空状态：主页「点击右上角添加的快捷指令」、添加页「没有可添加的快捷指令」；诊断信息（扫描时间/状态摘要/数据库路径/容器与探测明细）抽成 4 个 C 函数，整体搬到添加页 footer、位于未显示控制项下方。版本 1.1.8-18/1001073。 |
| 124 | 1.1.8-19 | 三项微调（用户反馈）。① 图标过于大：按用户要求缩小 1/5，墨迹目标从宽 86%/高 95% 改为 69%/76%（磁贴本身大小仍不变）。② uuid 文字发白：`secondaryLabelColor` 在白底下太浅，主页与添加页的 detailTextLabel 统一改为 `UIColor.labelColor`，主次关系靠字号区分。③ 搜索框位置：之前用 `addSubview` + 手写 frame 放在 view 的 y=0，但这个页面的 view 是整屏的（会伸到导航栏底下），搜索框被导航栏压住一大半、手指点到状态栏区域，完全不能用。改为表格的 `tableHeaderView` —— 表格的内容 inset 系统已经算好（主页正是这么正常显示的），表头视图天然落在导航栏下面、也就是用户红框标出的位置；取消按钮改到 viewDidLoad 再打开（视图未入窗口时设置经常不渲染）。版本 1.1.8-19/1001074。 |
| 125 | 1.1.8-20 | 两项修复（用户反馈 + 视频参考）。① 搜索框样式与交互：参考用户提供的越狱插件列表视频，搜索框**不要背景** —— `searchBarStyle = UISearchBarStyleMinimal` + `backgroundImage = [UIImage new]` + `setSearchFieldBackgroundImage:[UIImage new]`，只剩放大镜与占位文字直接贴在分组背景上；「取消」二字改为**只在点击输入框开始编辑时出现**（`searchBarTextDidBeginEditing:` 打开、`searchBarTextDidEndEditing:` 与 `searchBarCancelButtonClicked:` 收起），静止状态不显示。② 主页文字发白根因修复：实测 1.1.8-19 名称文字最暗像素只有 119 灰而旧版是纯黑（0,0,0），uuid 两版一致（118 vs 115）—— 真凶是上一版给主页行设了 `userInteractionEnabled = NO`，UIKit 会把**禁用单元格**里的文字整体调暗。改回 `userInteractionEnabled = YES`，用「didSelect 空实现 + `selectionStyle = None`」达到"点了没反应"的纯展示效果；主页与添加页的空状态行同样不再禁用；两个 label 显式 `alpha = 1.0`。版本 1.1.8-20/1001075。 |
---

# 1.1.9 · 「快捷方式」新分类（打开 App / 自定义链接）

与「快捷指令」并排的第二个用户自定义控制项分类。分三批交付，本批次只做设置页。

| 126 | 1.1.9-1 | 「快捷方式」第一批（设置页）。根页「控制项分类」卡片在「快捷指令」下方插入「快捷方式」入口（`erIcon: link.circle.fill` / `erIconColor: blue`，`openLinks:` 手推，同另外几个入口绕开 Preferences 跨 bundle 类查找）。新增 `prefs/ERLinkController.m/.h`（已加入 prefs/Makefile）：主页 `ERLinkController` 只显示已添加的快捷方式、空状态「点击右上角添加快捷方式」、右上角「添加」、左滑删除；子页 `ERLinkAddController` 顶部为无背景搜索框（只过滤 App 列表、取消按钮仅输入时出现）→「创建链接」行 → 已安装 App 列表（`LSApplicationWorkspace` 的 `allInstalledApplications`/`allApplications`/`installedApplications` 逐个试，带图标与本地化名称，点一下即添加并去重）。「创建链接」弹窗按用户截图实现：`UIAlertController` + 3 输入框（名称/图标（选填）/网址或 URL Scheme）+ 4 按钮（保存/从文件导入图标/从相册导入图标/取消），文件走 `UIDocumentPickerViewController`、相册走 `PHPickerViewController`，导入的图片落盘 `link-icons/`。数据存共享偏好域 `LinkCatalog`（uuid/name/type(app|link)/bundleId/url/iconKind/iconValue/color），同时落 `links.plist` 快照并发 `com.strive.echoreborn/ReloadLinks` 通知。图标解析四类：SF 符号 → 白色前景；bundleId → App 图标（带「完整圆角方块」校验，避免取到单色符号版）；图片 URL → 下载；本地文件 → 落盘；每条渲染一张 120×120 成品 PNG（`iconFile`+`iconFull`）供后续控制中心直接复用。行图标沿用墨迹 69%/76% 缩放那套。版本 1.1.9-1/1001076。 |
| 127 | 1.1.9-2 | 修 1.1.9-1 的编译失败（4 处，全在新增的 ERLinkController.m）：① `ERLinkImportImageFromURL` 定义在 `ERLinkImportImageFromImage` 之前却调用后者 → C 函数隐式声明报错，调整定义顺序；② `ERLinkAddController` 只写了 `@class` 前向声明，而 `addLink:` 要 alloc/init、设 title、push，编译期必须看到完整 `@interface` → 把完整接口声明移到 `@implementation ERLinkController` 之前；③ `ERLinkImportImageFromURL(url)` 被误写成 ObjC 消息语法；④ `initWithDocumentTypes:inMode:` 自 iOS 14 废弃，而本工程开 `-Werror` 直接失败 → 用 `#pragma clang diagnostic` 局部按掉 `-Wdeprecated-declarations`（两个目标系统上都还可用，不值得为此引 UniformTypeIdentifiers）。功能与 1.1.9-1 完全相同（1.1.9-1 未产出可用 deb）。版本 1.1.9-2/1001077。 |
| 128 | 1.1.9-3 | 修 1.1.9-2 的编译失败（仅一处）：`ERLinkAddController` 的 `@interface` 里漏声明 `-initWithExisting:`，而 `ERLinkController.addLink:` 要调它。补上声明。功能与 1.1.9-2 完全相同（1.1.9-2 未产出可用 deb）。版本 1.1.9-3/1001078。 |

| 129 | 1.1.9-4 | App 详情页交互重做：① 添加子页 App 行图标统一归一化为 40×40 圆角（新增 `ERLinkAppCellIcon`，与「创建链接」图标同尺寸），行尾改为 `DisclosureIndicator`；② 点击 App 不再直接添加/弹回，而是 push 新增的 `ERLinkAppDetailController`（参考 Actra）：单个 inset-grouped section（同一张卡片）——第一行 App 头部（左 App 图标 + 右 App 名称加粗），第二行「打开 <App名>」快捷方式条目，页脚提示文案；③ 对号交互：条目点击一次 → 用 `ERLinkMakeAppEntry` 生成条目（渲染 120×120 图标落盘）写进 `LinkCatalog` 并显示对号 ✓，再次点击 → 从目录移除该 App 全部条目并删除图标文件、取消对号，状态持久化在共享偏好域，重进页面正确回显；④ 主页完全不变（左滑删除、纯展示）。版本 1.1.9-4/1001079。 |
| 130 | 1.1.9-5 | App 详情页改为展示**该 App 真实的快捷方式**（主屏 Quick Actions）。逆向 Actra（libActra.dylib 符号）确认数据源：SpringBoard 内 `SBApplication` 的 `staticApplicationShortcutItems` / `dynamicApplicationShortcutItems`（即长按图标弹出的 UIApplicationShortcutItem，静态来自 App Info.plist、动态来自运行时注册），Actra 再经 Darwin 通知 + 快照发给设置页。实现：① Tweak.xm 新增 `ERAppShortcutCatalogPublish`（`SBApplicationController.applications` 逐个取 bundleId/localizedName/两类 shortcut items，取 `type`+`localizedTitle`，静态去重优先），写共享偏好域 `AppShortcutCatalog` 并广播 `com.strive.echoreborn/AppShortcutsCatalog`；设置页发 `RequestAppShortcuts` 触发，SpringBoard 启动 8s 后也自扫一次；② 设置页 `ERLinkAppShortcutsForBundle`：先读快照，兜底 `LSApplicationProxy` → Info.plist `UIApplicationShortcutItems` 静态项；③ 详情页重做：删掉「打开 App」行，卡片内直接列出该 App 真实快捷方式（每行小图标 28×28 + 标题，头部 App 图标 32×32——页内图标整体缩小一档，仅此页面），点击条目 → 写入 `LinkCatalog`（新增 `type: appShortcut`，按 bundleId+shortcutType 定位）显示对号 ✓，再点取消并删图标文件；无快捷方式时空状态「该应用没有可用的快捷方式」；④ 添加页/主页不变。版本 1.1.9-5/1001081。 |
| 131 | 1.1.9-6 | 修 App 详情页取不到快捷方式。根因：1.1.9-5 装机后只重启了 Preferences，SpringBoard 里没有重新注入，目录发布器从未运行，快照恒为空；百度地图的 Quick Actions 属运行时注册的动态项，静态兜底也拿不到 → 空状态。加固三处：① `ERAppShortcutCatalogPublish`：`applications` 为空时试 `allApplications`，仍为空 8s 后自动重试一次；扫描计数诊断（共 N 个应用、M 个有 shortcut 属性）写日志；② `ERLinkAppShortcutsForBundle`：读快照前先 `CFPreferencesAppSynchronize` 强刷 cfprefsd 缓存；快照命中/缺失、兜底条数全部写 `echoreborn.log`（PREFS-LINK）便于远程诊断；③ 详情页 `viewWillAppear` 拿不到时自动补拉两次（3s/7s，离开页面即停），每次先重发 RequestAppShortcuts。**装机需重启 SpringBoard**（`killall -9 SpringBoard`）才生效。版本 1.1.9-6/1001082。 |
| 132 | 1.1.9-7 | 详情页仍空的排查与加固：`defaults read` 在设备上确认 AppShortcutCatalog（57 个应用，微信/美团/YouTube 均带真实动态项）已写入共享偏好域、读取通道正常 → 怀疑个别导航场景 `viewWillAppear:` 未触发导致从未加载。修复：`viewDidLoad` 也拉取一次（reloadShortcuts + 发请求 + 重试）；空状态行改为自诊断文案（目录尚未发布 / 目录 N 个应用但不含该 App 可先打开一次 / 条目为空），下次用户截图即可直接定位断点。版本 1.1.9-7/1001083。 |
| 133 | 1.1.9-8 | ① 添加页拆两张卡片：第一张「创建链接」+ 有快捷方式的应用，第二张「其他应用」，卡内按名称 A→Z（不按条目数）；有/无依据 SpringBoard 快照的 AppShortcutCatalog 键集合；② 只显示桌面上有的 App：Tweak.xm 新增 `ERAppShortcutPublishHomeScreenApps`（SBIconController → iconModel → leafIcons → SBApplicationIcon.application.bundleIdentifier），写共享偏好域 `HomeScreenApps`，添加页用「已安装 ∩ 桌面集合」过滤（集合为空则不过滤兜底），电视提供商/用户认证等不在桌面的系统组件不再出现；③ 详情页头部行可点击 = 添加/取消「打开 App」条目（type: app，头部行带对号），下方快捷方式行对号交互不变，抽公共 `removeCatalogEntriesOfKind:shortcutType:`；④ 页内图标统一 30×30（头部与条目一致）；⑤ 百度地图修复：发布器对 SB 属性拿不到条目的 App 改读其 Info.plist 静态 `UIApplicationShortcutItems` 兜底（新增 `ERAppShortcutStaticItemsFromInfoPlist`）。版本 1.1.9-8/1001084。 |
| 134 | 1.1.9-9 | 装机 1.1.9-8 后远程核验：目录 57 应用正常，但 `HomeScreenApps` 从未写入、且全机 25 个带静态快捷方式的 App 有 22 个不在目录（含百度地图 com.baidu.map，其 Info.plist 实有 4 个静态项）。定位两个断点：① SpringBoard 里 `LSApplicationProxy.infoDictionary` 对部分 App 取不全 → 改用 `objectForInfoDictionaryKey:`（LSBundleProxy 正牌接口）取 `UIApplicationShortcutItems`，并保留 infoDictionary 二次兜底（`ERAppShortcutStaticItemsFromProxy`）；② SBApplicationController 列表覆盖不全 → 新增 `LSApplicationWorkspace.allInstalledApplications` 全量安装代理表（bundleId→proxy），扫描后补扫目录缺失的静态项应用；③ `HomeScreenApps` 空集合时 15s/30s/45s 重试链（SB 刚启动图标模型未就绪），收到目录请求通知时也重刷。版本 1.1.9-9/1001085。 |
| 135 | 1.1.9-10 | 1.1.9-9 装机后发布器不落盘（respring/整机重启均无写入，无日志可看）→ 改为诊断版：`ERAppShortcutDiagSet` 把发布器每步进度（ctor 注入心跳 / publish_start / sb_apps / ws_proxies / static_only / catalog_n / home_screen / home_retry / publish_error）写进 `NSUserDefaults` 标准域（键前缀 `appShortcuts.`），远程读 prefs 即可定位断点。功能与 1.1.9-9 相同。版本 1.1.9-10/1001086。 |
| 136 | 1.1.9-11 | 诊断落点改到自有域（roothide 连 SpringBoard 自己的 com.apple.springboard.plist 都隐藏，Diag 写 NSUserDefaults 读不到）→ `ERAppShortcutDiagSet` 改用 `CFPreferencesSetAppValue` 写 `com.strive.echoreborn.preferences` 的 `Diag.*` 键；详情页空状态按要求改为统一简洁文案「该应用没有可用的快捷方式」（不再展示目录规模等自诊断文字）。版本 1.1.9-11/1001087。 |
| 137 | 1.1.9-12 | Diag 显示发布器完整跑完但两个断点：static_only=0（SB 里 objectForInfoDictionaryKey:/infoDictionary 对全部 373 个代理都取不到静态项）、home_retry=3（SBIconController 图标路径拿空）。修复：① 静态项增加第三层兜底——绕过 LS 缓存直接读磁盘：`proxy.bundleURL` + `CFBundleCopyInfoDictionaryForURL`；② 桌面图标多路径：leafIcons → allIcons → applicationIcons 键（iconModel 优先、iconListModel 兜底），失败路径写 `icon_path` 诊断键；③ 百度地图专项诊断键（baidu_objkey / baidu_info / baidu_info_shortcuts）。版本 1.1.9-12/1001088。 |
| 138 | 1.1.9-13 | 1.1.9-12 Diag 两大真凶：① `publish_error = -[_LSDataBackedPropertyList count]`——SB 里 `objectForInfoDictionaryKey:` 返回 LS 内部 data-backed 包装对象，直接当数组用会崩掉整个发布（HomeScreenApps 自 1.1.9-8 起从未写出的根因）；② `icon_path = none`——SBIconController/iconModel 都在但 leafIcons/allIcons/applicationIcons 全空。修复（对齐 Actra 逆向结论）：① 新增 `ERAppShortcutUnwrapPlist`（NSArray/NSDictionary 直接用；NSData 用 NSPropertyListSerialization 反序列化；包装对象试 plist/underlyingPlist/plistData/data 选择器再反序列化），静态项三条取法全部先解包；② 图标探测重写：候选模型 iconModel/iconListModel/iconManager(+其 iconModel/model/currentIconModel)，每模型探测 leafIcons/allIcons/visibleLeafIcons/visibleIcons/icons/applicationIcons（字典取键、数组取 application.bundleIdentifier），命中记录 `icon_model_class`/`icon_sel`，未命中记录模型类名清单；③ 百度诊断记录包装类名 `baidu_objkey_class`。版本 1.1.9-13/1001089。 |
| 139 | 1.1.9-14 | 1.1.9-13 Diag：`baidu_objkey=nil`（SB 里 LS 的 objectForInfoDictionaryKey/infoDictionary 对 shortcut 键返回包装对象，infoDictionary 调用即抛 count 异常），且取法2一抛异常整函数提前 return → 磁盘兜底永远执行不到。修复：① 三条取法各自独立 @try 互不阻断；② `ERAppShortcutUnwrapPlist` 对集合先做 count 安全测试（包装类继承集合类型但没实现 count 的坑）；③ 图标探测新增 iconLists/rootFolder/allIconLists 选择器、容器放宽 count 响应即用；④ 百度诊断块整体 @try。版本 1.1.9-14/1001090。 |
| 140 | 1.1.9-15 | 百度已修复（catalog 57→85，磁盘 Info.plist 兜底生效）；剩 HomeScreenApps 仍空（SBHIconManager/SBIconModel 九个选择器全空）。① 详情页无条目时不再显示任何占位/诊断文字行（用户要求删除）；② 图标探测加细分诊断 `icon_probe`（每模型×每选择器：是否响应/返回类型/数量/异常），一次装机即可定位 iOS 17 桌面图标集合的正确取法。版本 1.1.9-15/1001091。 |
| 141 | 1.1.9-16 | `icon_probe` 细分诊断揭示真因：`SBIconModel.leafIcons` 其实返回 NSSet（253 个）/visibleLeafIcons 250 个，但 `ERAppShortcutCollectBids` 只认 NSArray/NSDictionary，NSSet 被跳过 → 一直 no-hit。修复：容器判断加 NSSet；删除已完成使命的百度专项诊断块（其 infoDictionary 调用会抛包装类异常）。HomeScreenApps 预计本版落盘，「其他应用」卡片的桌面过滤随之生效。版本 1.1.9-16/1001092。 |
| 142 | 1.1.9-17 | 「添加」页改三张卡片：① 创建链接（独立卡）② 有快捷方式 ③ 其他应用；同时删掉空卡片的占位文案行（「没有可添加的应用 / 没有匹配的应用」不再显示，空卡片就是空行）。版本 1.1.9-17/1001093。 |
| 143 | 1.1.9-18 | 根因修复：push9_5.py 一直没推 prefs/*.m（ERLinkController.m 等），导致 -15/-16/-17 的设置页改动（空态文字删除、三卡片）从未进 CI 编译，设备上跑的一直是仓库旧文件。本版把 ERLinkController.m / ERShortcutController.m / ERRootListController.m 加入推送清单重推；同时修正 Info.plist 漏改的 CFBundleShortVersionString。版本 1.1.9-18/1001094。 |
| 144 | 1.1.9-19 | Batch 2 控制中心磁贴：快捷方式与快捷指令**共用 32 个槽位模块**（槽位绑定先查 ShortcutSlotAssignments 再查 LinkSlotAssignments，认领时两家族一起算占用）。槽位 bundle（ERShortcutModule.h）双查绑定：快捷方式条目渲染白色单色剪影（app/appShortcut 用 App 图标白色剪影，symbol 用 SF 符号，兜底 link 符号），点击写 LinkRunRequest + 广播 RunLink。Tweak.xm：ERLink* 槽位助手；ERCategoryForIdentifier/ERFriendlyNameForIdentifier 按 LinkCatalog 绑定分流；画廊新增「快捷方式」分区（排第三方插件前）；shortcutTileProxyTapped 分流；RunLink 监听 + ERRunLinkEntry（link→openURL / app→FBSOpenApplicationService / appShortcut→SBSApplicationShortcutItem+activateShortcut:）；ERCategoryOrderController 默认分类加「快捷方式」。版本 1.1.9-19/1001095。 |
| 145 | 1.1.9-20 | 磁贴可见但点击无反应 → 执行链路诊断：ERAddDiagSet 写 Diag.* 到自身偏好域（SFTP 可读）；erAddControlSheetDidSelectIdentifierCore 记 Diag.Add/AddResult；addShortcutSlotToControlCenter 记 Diag.SlotSaved；shortcutTileProxyTapped 链接分支记 Diag.ProxyTap.<slot>（type/bid/url 或 NO-RECORD）；ERRunLinkEntry 记 Diag.Run.<uuid8> + .url/.app/.sc；ERLinkOpenApp 记 Diag.FBS；ERShortcutModule.h reloadBinding 包 @try（异常兜底 link 符号）并在末尾写 Diag.Slot.<N> 渲染状态。版本 1.1.9-20/1001096。 |
| 146 | 1.1.9-21 | 诊断数据落地：ProxyTap/Run 全部到达，故障在执行体——① app 类型：`fbs NO`，因 FBSOpenApplicationService openApplication: 第一参须为 FBSOpenApplicationRequest 对象而传了 NSString（异常被 @catch 吞掉）；② appShortcut 类型：`sel=0`，iOS 17 SBIconController 不响应 activateShortcut:withBundleIdentifier:forIconView:。修复：app 统一走 FBSSystemService openApplication:options:withResultHandler:（吃 bundleId 字符串），兜底 FBSOpenApplicationRequest+FBSOpenApplicationService；appShortcut 改为把 SBSApplicationShortcutItem 塞进启动 options 的 __ActivateApplicationShortcutItem 键随应用启动（与桌面快捷菜单同机制）。版本 1.1.9-21/1001097。 |
| 147 | 1.1.9-22 | Diag.FBS=`sys service=1 sel=0`：iOS 17 FBSSystemService 不响应 openApplication:options:withResultHandler:，且兜底分支零输出（FBSOpenApplicationRequest 疑似缺失）。改多候选链：A=FBSOpenApplicationService+FBSOpenApplicationRequest（类方法/实例 init 双取法）→ B=FBSSystemService 两种签名 → C=SBApplicationController+SBUIController activateApplication(Animated):withOptions:；每步结果记 Diag.FBS / Diag.FBSCls，一次装机确定可用路径。版本 1.1.9-22/1001098。 |
| 148 | 1.1.9-23 | Diag.FBS=`A-cls0 svc=1 req=0 / B-skip s1=0 s2=0 / C-skip app=1 ui=1 s1=0 s2=0`：iOS 17 上 FBSOpenApplicationRequest 类不存在、FBSSystemService/SBUIController 的 open/activate 选择器全部缺失。不再盲猜：ctor 增加 ERLinkProbeAPIs 运行时方法表探测，把 FBSOpenApplicationService/FBSSystemService/SBUIController/SBSLaunchApplicationService/FBSOpenApplicationRequest 的 open/activate/launch 相关方法名（实例+类方法）全部导出到 Diag.P.* 诊断域，下一版按真实 selector 定向修复。版本 1.1.9-23/1001099。 |
| 149 | 1.1.9-24 | 方法表探测命中 iOS 17 真实接口：FBSOpenApplicationService 有 hd_openApplication:optionsDictionary:completion: / openApplication:withOptions:completion:；FBSSystemService 实为 openApplication:options:withResult:（此前败在选择器名 withResultHandler:）；SBUIController 有 activateApplication:fromIcon:location:activationSettings:actions:；FBSOpenApplicationRequest 类确实不存在。执行链按此重写：A1(hd_)→A2→B→C，命中即发，全程记 Diag.FBS。版本 1.1.9-24/1001100。 |
| 150 | 1.1.9-25 | 电话磁贴点击 → 安全模式：A1(hd_openApplication:optionsDictionary:completion:) 崩 SpringBoard（崩在返回前，Diag.FBS 无记录）。移除 A1，顺序改 B(FBSSystemService openApplication:options:withResult:) → C(SBUIController activateApplication:fromIcon:...) → A2(FBSOpenApplicationService openApplication:withOptions:completion:)；每个候选调用前先写 X-try 诊断，再崩可定位。版本 1.1.9-25/1001101。 |
| 151 | 1.1.9-26 | ① appShortcut 只打开 App 不进页面：`__ActivateApplicationShortcutItem` 裸字典被无视。改双层：第一层读 App 磁盘 Info.plist 的 UIApplicationShortcutItems，匹配 type 后取 userInfo 深链 URL 直接 openURL（记 Diag.Run.*.ui）；第二层 options 改用 FBSOpenApplicationOptions optionsWithDictionary: 正式构造再走启动链。② 新磁贴落在最早有空位的页：addShortcutSlotToControlCenter 只写 enabled 列表、布局交原生（原生填第一个空位页）。补上与普通模块同款定位——从当前可见页 ERDerivedVisiblePageForOverlay 起 ERGuaranteedPagedSlot 找位、写 ModuleGridOrigins（记 Diag.SlotPlace）。版本 1.1.9-26/1001102。 |
| 152 | 1.1.9-27 | 诊断：SlotPlace 生效（p3 start=3 当前页）；appShortcut 没反应根因是 B 路径只吃 NSDictionary，传 FBSOpenApplicationOptions 对象抛 NSInvalidArgumentException，退到 C 又静默无效。修复：① 第二层恢复传裸字典（-25 已验证可开 App）；② 深链探测加 LSApplicationProxy static/dynamicApplicationShortcutItems 来源（磁盘 Info.plist 无 UIApplicationShortcutItems 的系统 App 从这里取 type/userInfo URL）。版本 1.1.9-27/1001103。 |
| 153 | 1.1.9-28 | LS static/dynamicApplicationShortcutItems 在 SB 进程为空（.ui 全 no-items）→ 深链路走不通。从 Actra 逆向字符串锁定 iOS 17 桌面快捷菜单真实激活接口：SBIconController activateShortcutForApplication:type:userInfo:completion:（activateShortcut:withBundleIdentifier:forIconView: 的继任者，直接吃 SBApplication+type+userInfo）。appShortcut 执行改为：深链 URL → Actra 同款激活接口（记 Diag.Run.*.act）→ 开 App 兜底。版本 1.1.9-28/1001104。 |
| 154 | 1.1.9-29 | Diag.Run.*.act=sel-missing：-28 只查了 SBUIController 是否响应 activateShortcutForApplication:type:userInfo:completion:。老前辈 activateShortcut:withBundleIdentifier: 一直挂在 SBIconController 上，新接口大概率同样。改为 SBIconController 与 SBUIController 双查（记 try/sent <类名>）。版本 1.1.9-29/1001105。 |
| 155 | 1.1.9-30 | Diag.Run.*.act=both-sel-missing：新接口 activateShortcutForApplication:type:userInfo:completion: 在 SBIconController/SBUIController 上都不存在（Actra 很可能自己挂了分类）。① 新增 ERActClsProbe 全类枚举（objc_copyClassList）：谁实例响应新/旧 activateShortcut selector、名字带 Shortcut 的类及其 shortcut 方法名，写入 Diag.P.ActCls.*；② appShortcut 分支补试老接口 activateShortcut:withBundleIdentifier:forIconView:（SBSApplicationShortcutItem+bundleId+nil，记 old-try/old-sent）。版本 1.1.9-30/1001106。 |
| 156 | 1.1.9-31 | -30 装上即安全模式：Diag.P.* 全在、ActCls 一个没有 → 崩在 ctor 里同步的 ERActClsProbe 全类枚举内部（ctor 时 SB 刚起，objc_getClassList 全量遍历太重）。改为 ctor 后 3 秒、UTILITY 后台队列、objc_getClassList+分段 Stage 进度（copy→loop n/total→dump→done）+每段 autoreleasepool。若后台段再崩，Stage 值可直接定位崩溃段。版本 1.1.9-31/1001107。 |
| 157 | 1.1.9-32 | -31 仍崩：Stage=list total=103460，未到 loop 4000 → 崩在循环内前 4000 类，疑 instancesRespondToSelector/method 表扫描踩到异常类。收缩为两遍：第一遍只读 class_getName（每 10000 写 names n/total 进度），只对名字含 Shortcut/IconController/Workspace/Activat 的候选类做响应检查与方法扫描（几十~几百个）。版本 1.1.9-32/1001108。 |
| 158 | 1.1.9-33 | -32 稳定（done classes=103469，不再安全模式）。枚举结论：全 SB 无类响应新旧 activateShortcut selector（Actra 自实现）；发现 SBMultitaskingApplicationShortcutService 的 performShortcutAction:forBundleId…（系统级执行 App 快捷操作接口）。本版：① 磁贴界面按 type 区分——副标题 link=一键直达/appShortcut=快捷跳转/app=打开应用（无绑定回退点击运行）；图标 appShortcut=bolt.fill、app=square.grid.2x2.fill、link 保持现状（设置页不动）；② 探测补 SBMultitaskingApplicationShortcutService/SBApplicationShortcutStore(Manager)/ActraApplicationShortcutApplication 的实例+类方法表及 Sel 响应（P.ActCls.Svc1..4）。版本 1.1.9-33/1001109。 |
| 159 | 1.1.9-34 | 用户确认界面改动成功（副标题三文案+两新图标）。appShortcut 仍只开 App。策略变更：让用户用 Actra 跳一次，SpringBoard 里挂纯日志钩子还原真实路径——%hook SBMultitaskingApplicationShortcutService（performShortcutAction:forBundleIdentifier: 记 action 对象、fetchSupportedShortcutActions…记 bid）与 FBSSystemService openApplication:options:withResult:（记 options 字典），写 Diag.JT.*；另导 Service 完整实例方法表（P.Svc1.I.Full）。版本 1.1.9-34/1001110。 |
| 160 | 1.1.9-35 | 用户用 Actra 对米家跳转 4 次全部直达，但 -34 的 Diag.JT.* 零命中 → Actra 没走 SBMultitaskingApplicationShortcutService/FBSSystemService openApplication:options:withResult:。扩大追踪：FBSSystemService 补 clientPort 重载、FBSOpenApplicationService 两个 withOptions 变体、SBUIController activateApplication:fromIcon:location:activationSettings:actions: 与 _activateApplicationFromAccessibility:、LSApplicationWorkspace openApplicationWithBundleURL:；Svc1 完整方法表改在 3s 探测里导（ctor 写 no-hit）。版本 1.1.9-35/1001111。 |
-35 编译修复后归入本版。| 161 | 1.1.9-36 | -35 CI 失败：LSApplicationWorkspace openApplicationWithBundleURL: 返回 BOOL，%orig 未 return（-Wreturn-type）。改为 return (BOOL)%orig;（仅编译修复，逻辑同 -35）。 |
| 162 | 1.1.9-37 | 突破：-36 JT 命中——Actra 米家跳转走 FBSOpenApplicationService openApplication:withOptions:completion:，options 为 FBSOpenApplicationOptions{__Actions={UIHandleApplicationShortcutAction info:BSSettings{shortcutItem=SBSApplicationShortcutItem}}, __LaunchOrigin=SBSLaunchOriginShortcutItem, __PromptUnlockDevice=1, __ActivateSuspended=0}；此前失败的根因是我们走 FBSSystemService+裸字典 __ActivateApplicationShortcutItem（SB 只开 App 不执行 action）。Actra 侧引用 activateShortcut* 两 selector 但实例级枚举查无 → 本版枚举补类方法级检查（[(id)cls respondsToSelector:]），并导出 ActraShortcutActionModule/SBMainWorkspace/SBIconController 方法表（Svc5..7）。版本 1.1.9-37/1001113。 |
| 163 | 1.1.9-38 | -37 探测：类方法级也无响应（New/Old 仍 none）→ Actra 不是调 activateShortcut*。金矿：SBMainWorkspace 有 _handleUserActionRequest:options:activationSettings:origin:withResult: / _handleTrustedOpenRequestForApplication:…（__Actions 构建点候选），SBIconController 有 _launchFromIconView:withActions:modifierFlags:（带动作启动）。JT 补挂这两个类的钩子抓真实参数格式，用户用 Actra 跳一次即可还原。版本 1.1.9-38/1001114。 |
| 164 | 1.1.9-39 | -38 JT 完整抓到 Actra 米家直达链路：SBMainWorkspace _handleTrustedOpenRequestForApplication:options:activationSettings:origin:withResult:，opts={__Actions=[UIHandleApplicationShortcutAction(info=BSSettings{shortcutItem})], __ActivateSuspended=0, __LaunchOrigin=SBSLaunchOriginShortcutItem, __PromptUnlockDevice=1}；另证实系统服务层会清洗未知 options 键（我们 QQ 跳转到达 MainWS 时 opts 已成空）。实现：appShortcut 最优先层进程内直调该入口——BSMutableSettings 塞 shortcutItem 构 info，UIHandleApplicationShortcutAction initWithInfo:/init+setInfo: 构 action，SBActivationSettings 塞 fromTrustedSystemServiceRequest=YES，BProcessHandle currentProcessHandle/processHandleForPID: 构 origin；构件记 .tr parts，全部就绪才调用。另导 Helper 类方法表（P.Helper.*）备用。版本 1.1.9-39/1001115。 |
| 165 | 1.1.9-40 | -39 CI 失败：.tr parts 格式串 %@ 配 bool 参数（-Wformat）。改 %d。逻辑同 -39。版本 1.1.9-40/1001116。 |
| 166 | 1.1.9-41 | -40 装机后 Helper 探测：BProcessHandle=cls-nil（真名 BSProcessHandle，JT 日志即 BSProcessHandle）、BSMutableSettings 写入方法是 setObject:forSetting:（非 forKey:）。修正 .tr 构件：info/settings 用 setObject:forSetting:（保留 forKey: 兜底）、origin 类名改 BSProcessHandle（currentProcessHandle/processHandle/mainProcessHandle/processHandleForPID: 依序尝试）；探测补 P.Helper.BSPH(.I) 类+实例方法表。版本 1.1.9-41/1001117。 |
| 167 | 1.1.9-42 | -41 实测 .tr=parts item=0 info=1 action=1(init(no-info)) —— 快捷项 scInit 不可用致 item=nil；且 UIHandleApplicationShortcutAction 无 setInfo:（Actra 也不构造该对象，其走桌面上下文菜单完成回调由系统建）。修正：① 快捷项照第三层已验证兜底（alloc/init+setType:+setLocalizedTitle:）；② trusted 入口改传旧版键 __ApplicationShortcutItem=快捷项（此前 __ActivateApplicationShortcutItem 是错误键名，被系统清洗成空 opts），__Actions 由 SpringBoard 自建。版本 1.1.9-42/1001118。 |
| 168 | 1.1.9-43 | -42 点磁贴即安全模式（roothide 无崩溃日志可查）：裸 NSDictionary 直调 trusted 入口必崩（只吃 FBSOpenApplicationOptions 对象）。改为运行时找 optionsWithDictionary:/initWithDictionary: 构造真对象，找不到一律跳过该层；探测补 FBSOpenApplicationOptions 类+实例方法表（P.Helper.FBSOpts*）。版本 1.1.9-43/1001119。 |
| 169 | 1.1.9-44 | -43 探测：FBSOpenApplicationOptions 无类构造器，实例有 setDictionary:；BSProcessHandle 类方法 processHandle 存在（origin 构造已通）。trOpts 改 alloc init + setDictionary:（兜底 initWithDictionary:），找不到照旧跳过。版本 1.1.9-44/1001120。 |
| 170 | 1.1.9-45 | 1001121 | trusted 调用两项修正：result 回调不再传 nil（-44 实锤进入 MainWS 处理器后崩溃，真实调用均带结果块）；settings 改为内层 BSMutableSettings{fromTrusted=Yes} + 运行时探测包裹（setSettings:/setBackingSettings: 等），诊断 .tr 增加 setHow 与 result |
| 171 | 1.1.9-46 | 1001122 | -45 实锤：trusted 调用抛 NSInvalidArgumentException 被 @catch 拦截（不再崩溃）。-46 在 EXC 诊断里追加 reason 与 callStackSymbols 前 8 帧（.stk0..7），定位非法参数 |
| 172 | 1.1.9-47 | 1001123 | -46 栈实锤：处理器对 activationSettings 调 boolForActivationSetting:（仅 SBActivationSettings 实现），传 BSMutableSettings 抛 unrecognized selector。-47 改回直接传 SBActivationSettings（-44 类型）+ -45 的真实 result 块，二者合并；并转储 SBActivationSettings 含 ctivat 的方法名（.tr actSet-methods） |
| 173 | 1.1.9-48 | 1001124 | -47 实锤：传 SBActivationSettings 时处理器越过校验进入深层代码硬崩（@try 拦不住、诊断未落盘）。-48 改回 -46 的 BSMutableSettings + 运行时 class_addMethod 注入 boolForActivationSetting:（er_bsBoolForActivationSetting，恒 YES），让调用通过校验继续 |
| 174 | 1.1.9-49 | 1001125 | -48 栈实锤：boolForActivationSetting: 注入放行后，处理器对 options 调 bs_boolForKey:（BSSettings 系），FBSOpenApplicationOptions 未实现。-49 options 改用 BSMutableSettings 传四键（bs_* 全套），FBSOpenApplicationOptions 路线降为兜底 |
| 175 | 1.1.9-50 | 1001126 | -49 栈实锤：BSMutableSettings 也没有 bs_boolForKey:（bs_* 族在 iOS 17 两个类上都缺）。-50 注入完整 bs_* 方法族（boolForActivationSetting:/bs_boolForKey:/bs_objectForKey:/bs_stringForKey:），实现从关联字典取值；settings 与 options 都挂各自字典 |
| 176 | 1.1.9-50b | 1001127 | -50 编译失败修复：objc_get/setAssociatedObject 的 key 改为 static char（const void*）；BOOL 返回值方法类型编码修正为 B@:@。逻辑与 -50 一致 |
| 177 | 1.1.9-51 | 1001128 | 全链复盘：__ApplicationShortcutItem 键只存在于我们自己的调用；真实调用（Actra）用 __Actions+action。-51 options 切 __Actions=@[UIHandleApplicationShortcutAction(info=shortcutItem)]，action 构造补 _setInfo: 尝试；__ApplicationShortcutItem 降为 action 缺失时兜底 |
| 178 | 1.1.9-52 | 1001129 | 长按桌面抓包实锤：真实调用 action 带 responder<_BSActionResponder active:YES>（SpringBoard 内构造、无 mach port），origin 即 SpringBoard 自身。-52 构建 _BSActionResponder（alloc init + activate/begin/start）并经 setResponder:/_setResponder: 挂到 action；scItem 补 setLocalizedSubtitle:@""；诊断新增 resp= |
| 179 | 1.1.9-53 | 1001130 | 用户选定方案 A：直调 MainWS 彻底停用（-39..-52 反复深层硬崩根因 = 进程内伪造 action 缺系统侧 responder 通道）。-53 改走 Actra 实测的服务层：FBSSystemService openApplication:options:withResult: + 真 FBSOpenApplicationOptions 携带 __Actions（BSAction 安全编码可穿透），编码失败服务层报错不崩桌面 |
| 180 | 1.1.9-54 | 1001131 | -53 实锤：服务层 XPC 编码伪造 action 直接 abort（诊断未落盘）。切换方案 B：appShortcut 走 URL Scheme 映射直达（内置 QQ 扫一扫 mqqapi://qrcode/scan_qrcode，prefs 键 AppShortcutURLMap 可扩展，键 "bundleId|type" 或 "type"）；系统动作伪造调用（-39..-53）全线停用（.tr=sys-disabled），未收录应用回退"打开应用" |
| 181 | 1.1.9-55 | 1001132 | 逆向乌贼手势实锤：其调用 activateShortcut:withBundleIdentifier:forIconView: 于 iconManager（SBIconController.iconManager）；-37 全类探测漏扫 SBIconManager（筛选词 IconController 未命中）。-55 新增最优先层：SBIconController.iconManager（兜底 SBIconManager sharedInstance/sharedService）activateShortcut(SBSApplicationShortcutItem, bundleId, nil)；诊断 .act2 |
| 182 | 1.1.9-56 | 1001133 | -55 实锤 iconManager 不响应 activateShortcut:...。-56 修正版探测 ERAct2Probe：ctor 后 3s 用 class_getInstanceMethod/class_getClassMethod（纯 C，不触发 +initialize，避开 -31 崩溃源）扫全部类找该选择器响应者（Diag.P.Act2.Done）；运行层对候选类（含 SBShortcutItemSimulator）试 sharedInstance 系并直调，诊断 .act2 |
| 183 | 1.1.9-56b | 1001134 | -56 编译修复：探测体抽成普通 C 函数 ERAct2ProbeImpl（老 clang 在 block 内 @try 捕获变量有 bug），优先级常量改 DISPATCH_QUEUE_PRIORITY_DEFAULT。逻辑不变 |
| 184 | 1.1.9-56c | 1001135 | 探测加固：Start/Scan(每2000类)/Hit(命中即时落盘)诊断；空类跳过；延迟 3s→8s 避开启动高峰。首次 CI roothide job 因 GitHub API 网络超时失败(非编译错)，已重跑成功；-56b 装机后不稳已回滚 -55 |
| 185 | 1.1.9-56d | 1001136 | 按镜像探测替代全量扫描：56b/56c 全量 objc_copyClassList 扫描在 SpringBoard 引导后必崩（-55 无探测稳定；设备上无 .ips 崩溃日志可查）。改为 objc_copyClassNamesForImage 只扫 SpringBoard 主程序+非系统 dylib（tweak 注入镜像），objc_lookUpClass 不触发 +initialize；Img/Scan/Hit 分步落盘 |
| 186 | 1.1.9-57 | 1001137 | A 路结案：56d 按镜像探测 hits=0——iOS17 全镜像（SpringBoard 主程序+全部 tweak dylib）无 activateShortcut:withBundleIdentifier:forIconView: 响应者，系统直启路径确认封死，乌贼同款调用亦死代码。转快捷指令方案（快面板同款 WorkflowKit：WFWorkflowRunRequest+WFWorkflowRunnerClient runWorkflow:title:）。-57 新增 ERWFProbe：安全按镜像扫主程序+tweak dylib，列出方法名含 unWorkflow/hortcutRun 的 类:方法（Diag.P.WF.*，11s 延迟） |
| 187 | 1.1.9-57b | 1001138 | WF 探测白名单扩展：57 结果 imgs=5 hits=0 是因 WorkflowKit/VoiceShortcutClient 属系统框架被过滤；本轮把这两个镜像加入扫描白名单，拿 runWorkflow 确切方法签名 |
| 188 | 1.1.9-58 | 1001139 | 57b imgs=5 证实 SpringBoard 未加载 WorkflowKit（懒加载）。-58 改为主动 dlopen WorkflowKit+VoiceShortcutClient，直接倒 WFWorkflowRunnerClient/WFWorkflowRunRequest/WFWorkflowRunningContext/WFWorkflowDatabaseRunDescriptor/SBShortcutsService/VCSVoiceShortcutClient/VoiceShortcutClient/WFApplication 完整方法表（Diag.P.WF.C.<类名>.<段>） |
| 189 | 1.1.9-58b | 1001140 | 按用户要求移除全部 URL 映射（-54 方案B：内置 QQ 扫一扫 mqqapi 映射 + AppShortcutURLMap prefs 扩展 + 调用点）。快捷方式磁贴不再走 URL 通道；WorkflowKit 方法表探测保留（-58） |
| 190 | 1.1.9-59 | 1001141 | 查看 keyboardX(TypeX) 实现：快捷方式动作 = SBApplicationController 取真实 item（dynamic/static 按 type 匹配）→ 调 SBIconView 类方法 activateShortcut:withBundleIdentifier:forIconView:（respondsToSelector+签名守卫）。-59 照抄：新增最优先 QA 层（.qa 诊断）+ ctor 定向诊断 Diag.P.QA。未用其任何代码，仅复刻调用方式 |
| 191 | 1.1.9-60 | 1001142 | 快捷方式直达打通确认（-59 TypeX 同款路径，用户实测完美抵达）。新增「自动复制验证码」：系统增强页锁屏音乐上方加无标题卡片（图标+开关，键 SMSCodeCopyEnabled）；SpringBoard 侧挂 BBServer 三方法（publishBulletin/publishBulletinRequest/_publishBulletinRequest:forSectionID:），过滤 MobileSMS 分区，关键词+4-8位数字提取（排除年份/小数），按 bulletinID 去重，剪贴板 180s 过期本地写入。键盘X 同款思路自研实现 |
| 192 | 1.1.9-61 | 1001143 | 统一删除修复：Tweak.xm 新增 ReloadLinks 观察者 + ERLinkReconcileAfterCatalogChange（清理 LinkSlotAssignments 失效绑定、撤 duplicate-families/grid 持久化、syncOwnedDuplicateModules 重建覆盖层），左滑删除后控制中心磁贴同步消失 |
| 193 | 1.1.9-62 | 1001144 | 自定义快捷方式子页面：点击磁贴行进入（类型只读/改名/图标输入框+选择按钮/替换按钮复用添加流程原位换目标保留槽位）；卡片2 红色删除；图标选择页（搜索+SF符号池）；新增 symbolOverride 字段（ERShortcutModule.h 优先使用，磁贴与子页面两处同步）；ERLinkPersistCatalog 追加 ReloadPrefs 广播 |
| 194 | 1.1.9-63 | 1001145 | 自定义页按反馈改版：右上角「保存」统一生效（修改先暂存）；第3行名称在左/输入框最大化撑满/选择按钮放大/预览移最右；底部改左右双卡片（恢复默认+删除快捷动作，行高48）；第4行隐藏目标id、替换按钮改大且修掉被覆盖不显示的bug |
| 195 | 1.1.9-74 | 1001156 | 找回 1.1.8-9 误回退丢失的四组代码（对照仓库 1.1.8-6 版本逐块移植）：① 音乐胶囊左右滑动切歌（MusicCapsule.SwipeEnabled + NextTrack/PreviousTrack + hitTest 触摸修复）；② 胶囊液态玻璃背景（MusicCapsule.LiquidGlassEnabled「底部控件」开关 + LGLiveBackdropView + SystemUltraThinMaterialDark 固定深色 + 帧跟随）；③ 隐藏系统锁屏音乐（1.1.7-7 iOS17.2 实锤规则 CSActivityItemContentView→NCNotificationListCell + 1.1.8-2 切歌后 0.6s/1.6s 再断言 + MC-HIT/FULLDUMP 诊断）；④ 录屏无延迟（1.1.7-4 先收起 CC 0.4s 后开录时序 + 1.1.5 RCP-TIMELINE MSHookMessageEx 日志钩子 + ctor 主开关读值日志）。版本 1.1.9-74/1001156 |
| 196 | 1.1.9-75 | 1001157 | ① 录屏无延迟修复：ctor 挂载块换回 1.1.8-6 实锤版——宿主=RPControlCenterClient（1.1.7-2 逆向确认，SBControlCenterController 已无 startRecordingCountdown；1.1.9-74 错还原了 1.0.9-175 旧块导致钩子从未命中、点录屏 CC 不收起），主线程挂钩 + 3s/10s 主队列重试兜底，删除危险的 60s 后台类扫描（1.1.5/1.1.6 竞态事故教训）；② 胶囊玻璃点播放安全模式修复：reloadPrefs 只在开关变化或玻璃未创建时 applyBackgroundStyle（旧语义在播放通知→refresh→reloadPrefs 链路中于媒体卡入场动画事务里反复 applyFilters）；③ 胶囊玻璃边缘残影修复：layoutSubviews 帧变化时禁隐式动画并立即 applyFilters 重采样；版本 1.1.9-75/1001157 |
| 197 | 1.2.0-1 | 1002001 | 新功能·桌面胶囊手势：根页「系统增强」上方同卡片新增「手势管理」入口（detail 推入，icon hand.tap/teal）；新子页 ERGestureController（prefs/ERGestureController.h/.m）——卡片1 搜索胶囊总开关（HomeScreen.SearchPill.Enabled），卡片2 上/下/左/右滑四行（ERGestureValueCell 自绘行 + 圆角下拉框，选项 无动作+第1页…第N页，最多显示8行可滚动，选择即写即生效），卡片3 震动反馈（开关默认开 + 轻/中/重三档 ERSegmentedCell 复用）；Tweak.xm 侧主线程 5s 周期扫描识别搜索胶囊（类名含 Search+胶囊尺寸闸门）挂四向 UISwipeGestureRecognizer（不影响单击）、SBIconController 翻页选择器运行时候选链探测（setCurrentIconListIndex: 等4项+缓存）、iconLists 探测页数写入 HomeScreen.PageCount、触发时按档位 UIImpactFeedback；版本 1.2.0-1/1002001 |
| 198 | 1.2.0-2 | 1002002 | 修闪退：ERGestureValueCell 自定义 cellClass 必须实现三参 init（initWithStyle:reuseIdentifier:specifier:，ERSegmentedCell 同款）——两参版走基类构造导致自绘控件未建、refresh 链 SIGABRT；refresh 的 super 调用加 @try 兜底（1.0.8-29 同款教训）；构建错误修复（ERSPGHaptic 消息语法、contentEdgeInsets -Werror 压制） |
| 199 | 1.2.0-4 | 1002004 | 闪退诊断版②：崩溃记录器挂到 bundle 构造函数（__attribute__((constructor))，bundle 一加载即装 NSSetUncaughtExceptionHandler+信号处理器，无论崩在哪都能落盘 NSException name/reason——系统 .ips 无 reason，堆栈显示异常在 Preferences.framework+UITableView cell 加载区抛出且无我们 bundle 的帧，说明 ERGestureController 代码从未执行）；ERRootListController 全链路面包屑（root specifiers build start/systemIndex/手势行插入/done/erGestureEntrySpecifier begin/done）；两份日志落 /var/mobile/Documents/EchoReborn-prefs.log 与 EchoReborn-crash.txt |
| 200 | 1.2.0-5 | 1002005 | 闪退诊断版③：1.2.0-4 构造函数代码在设备 bundle 里存在（grep -a 实锤）但 Preferences 进程一个字节未写出，判定 Preferences 沙盒拦写 /var/mobile/Documents；ERGPrefsLog/ERGCrashWrite 改多路径兜底（Documents → /var/tmp → NSTemporaryDirectory 沙盒 tmp），全败时 NSLog 落系统日志；SSH 复测 mobile 可写 Documents（write test OK），故若 Preferences 未沙盒则 Documents 应能写出 |
| 201 | 1.2.0-6 | 1002006 | 闪退实锤修复：用户提供的 Preferences-2026-10-18-233150.ips 首次带出 exceptionReason——-[__NSCFConstantString isSubclassOfClass:] unrecognized selector，即 PS 在 cellForRow 对 [spec cellClass] 直接发 isSubclassOfClass:，而 ERGestureController 用 setProperty 传了字符串 @"ERGestureValueCell"/@"ERSegmentedCell"；其它页同款字符串写法没崩只因那些行是 plist 装载失败时的兜底、从未执行（plist 解析器会转换字符串，setProperty 不会）。修复：cellClass 改传类对象（[ERGestureValueCell class] / NSClassFromString(@"ERSegmentedCell")，后者带 PSTableCell 兜底） |
| 202 | 1.2.0-7 | 1002007 | 六项反馈：①开关行图标白块修复——iOS17.2 原生 PSSwitchCell 不渲染 iconImage（1.1.8-7 同款教训），erSwitchNamed 换 cellClass=ERModuleIconSwitchCell（传类对象）；②搜索胶囊+手势设置合并为一张卡片（footer 文案合并）；③手势行图标左边距跟 contentView.layoutMargins（绝对定位 16 与系统不一致），下拉框箭头改独立 chevron.down SF Symbol（15pt semibold，右侧槽位居中，不再拼进标题字符串）；④ERSegmentedCell 增 iconImage 支持（refresh 显式写 imageView + layout 定位，无 iconImage 的旧行为不变）修震动强度行白块；⑤页面标题改「手势管理」；⑥跳页/页数无效诊断——ERSPG 全链路 ERLogInfo（SPG-PAGE 探测结果与发布值 / SPG-PILL 胶囊命中 / SPG-SWIPE 手势触发 / SPG-JUMP selector 命中与调用 / SPG-SCAN 未找到节流 / SPG-DUMP 首 tick dump SBIconController 全部 page/list/scroll selector 实锤 iOS17 翻页 API） |
| 203 | 1.2.0-8 | 1002008 | 手势触发改造：UISwipeGestureRecognizer 在搜索胶囊上被桌面翻页 pan/其它手势插件压制、从不触发（1.2.0-7 诊断日志 0 条 SPG-SWIPE 实锤）——改为单个允许 simultaneous 识别的 UIPanGestureRecognizer（ERSPGPanDelegate 全 YES），位移≥40pt 判方向触发一次（pan 内 erPanFired 防重）；新增 SPG-PAN 触发日志、SPG-PILL 30s 在场心跳；排查中发现 1.2.0-7 的 Tweak.xm 因推送脚本清单遗漏从未上设备（0 条 SPG 的根因），push_ergesture.py 已补 Tweak.xm |
| 204 | 1.2.0-9 | 1002009 | SPG 探针（ctor/tick 双通道）+ ERModuleIconSwitchCell 坐标换算修开关消失 + 箭头 15→12pt + 按钮加宽防截断 |
| 205 | 1.2.0-10 | 1002010 | 开关行换 ERGestureSwitchCell（不碰开关只注图标）+ 浅色模式适配（标题/按钮/下拉浮层动态色）+ 下拉框再加宽半字 |
| 206 | 1.2.0-11 | 1002011 | 开关行图标改为每布局重读 specifier 强制注入 + 下拉框页码筛选（他手势占用页隐藏，无动作恒可选）+ 下拉框再宽（容差36/上限216）+ 浅色模式框内文字/箭头改黑 |
| 207 | 1.2.0-12 | 1002012 | 参考插件逆向：胶囊类直接覆写 touches（Began/Moved/Ended，≥40pt 判向，单击透传）替代被压制的手势识别器 + 下拉框宽度量值文本（修「无动作/第10页」截断真因）+ 开关行图标改自建 UIImageView |
| 208 | 1.2.0-13 | 1002013 | 手势扫描零 tick 根因实锤：spgTimer 未被持有（ctor 栈 __block 释放）改 static；下拉框统一宽度（按第10页/无动作定宽）；开关行图标换编译期 ERGestureSwitchCell |
| 209 | 1.2.0-13b | 1002014 | 开关行改 ERGestureSwitchCell:PSTableCell 全自绘（图标+标题+自放 UISwitch，CFPreferences 直读写）；PSSwitchCell 头文件是枚举无法子类化。下拉框统一宽度已在 -13 |
| 210 | 1.2.0-14 | 1002015 | 手势实锤：ScanTick 已跑但 pill NOT found(roots=38)——加候选类名 dump（SPG-CAND）+ LooksLikePill 放行 Spotlight；下拉浮层恢复暗色；开关行图标 29pt/左距16/行高兜底 |
| 211 | 1.2.0-15 | 1002016 | SPG-CAND 改类名关键词过滤（含坐标/hidden/alpha）；浮层宽度 170→150+恢复深浅自适应；开关行隐藏原生 imageView 修双图标；手势行图标底色统一（上下蓝/左右绿） |
| 212 | 1.2.0-16 | 1002017 | 手势识别根因修复：SPG-CAND 实锤 iOS17.2 胶囊=SBHSearchPillView(62x30)，LooksLikePill 类名 SearchPill 直接放行+宽度闸门 90→40；扫描改为优先挂屏内实例（日志存在 @-31,-15 离屏旧实例，防挂错）；手势行 ERGestureValueCell 隐藏原生 imageView（用户实锤双层图标/左边缘多一截）；开关行图标左边距 16→layoutMargins 与手势行对齐（两卡片同改）；下拉浮层 150→132+cell layoutMargins 归零改固定 14pt（去左侧多余空白） |
| 213 | 1.2.0-17 | 1002018 | 手势触发第二根因实锤：-16 日志 SPG-PILL found+TOUCH hook attached 但 pan/touch 触发行零条——胶囊只是显示层、触摸被上层 SBSearchScrollView 接管。pan 改挂 window（全局唯一），Began 时判起点是否在胶囊 window 帧±10pt 内，Changed≥40pt 判向触发；ERSPGShouldFire 前移与 touches 去重；UI：开关行/下拉框行隐藏原生 textLabel（实锤文字开头被 29pt 图标盖住：胶囊手势→囊手势，选值后标题同症）；下拉按钮内边距 10→6/右侧 12→6 收窄约 14pt |
| 214 | 1.2.0-18 | 1002019 | 手势第三环实锤：-17 日志 begin-in-pill ok→SPG-PAN #n page=x 全通，卡死在 SPG-JUMP sel=(none matched)——SBIconController 上无翻页 setter（DUMP 227 方法实锤）。跳页兜底：SBIconController 视图树找桌面分页 scrollView（pagingEnabled+宽≈屏+content≥1.5 页+类名不含 Search+子树含 IconList），setContentOffset 直接驱动；页数探测 probe=-1 同因，pager contentSize/页宽 兜底发布。文字消失根因：行标题存 specifier.name，propertyForKey:@"label" 为 nil——自绘标题一直空串（此前显示的是原生 textLabel，被 -17 隐藏后空白）；ERSpecLabel(name 兜底) 修 3 处 |
| 215 | 1.2.0-19 | 1002020 | pager 找不到+震动无感双修：放宽 pager 匹配（不要求 pagingEnabled，主条件 content≥1.9 页，IconList 加分）+ 首轮全量 dump 树内 UIScrollView 候选（SPG-PAGER cands=）；震动 UIImpactFeedbackGenerator 在 SpringBoard 无感（-18 日志 PAN 后 haptic 已调用）换 AudioServicesPlaySystemSound（轻1315/中4095/重双震） |
| 216 | 1.2.0-20 | 1002021 | 三修：①双 SBHSearchPillView 实锤（真胶囊底 {184,744}/搜索层顶 {24,13}），LooksLikePill 排除祖先含 SearchScrollView/SearchController 的候选，缓存坐标不再抖动（修区域错位/不灵敏/左右全无）；②ERSPGPager ic.view 为空时改扫全部 window（-19 PAGER 诊断零行的静默根因），无候选日志置位修正；③震动降档：轻=1315×1/中=1315×2/重=4095×1 |
| 217 | 1.2.0-21 | 1002022 | 触发流程改造：滑够「触发范围」（新滑块 10~80pt 默认 20，步进 5，ERGestureSliderCell 左图标+右滑块）震动一次锁定方向、松手才跳页（pan/touch 双通道同改）；起手判定区外扩 30pt（pan Began 迟到 ~10pt 实锤：能触发的是胶囊上下环带、本体反被搜索层吞）；起手入区临时禁 pager pan 防横向被原生翻页抢、End 恢复+1s 兜底；震动换界面优化同款 UIImpactFeedbackGenerator（常驻+prepare 无声），1315/4095 全移除（用户实锤 1315 双响像消息铃声） |
| 218 | 1.2.0-22 | 1002023 | 滑块换界面优化同款 ERSliderTrackCell（−/滑轨/+、读数居中、双击键入，构造逐项对齐 erSliderNamed，删自建 ERGestureSliderCell）；系统胶囊手势压制：用户视频实锤系统自带"拖胶囊四向翻页"抢横向触摸（-21 压 pager pan 压错对象），开启开关时对胶囊祖先链类名含 Search 视图的 pan/swipe enabled=NO（window pan 除外）每 tick 心跳维持、关闭恢复；SPG-GR 一次性 dump 胶囊链手势清单供日志定位 |
| 219 | 1.2.0-23 | 1002024 | 闪退实锤（.ips：cellForRow→doesNotRecognizeSelector）：代码构建 specifier cellClass 传字符串必崩，NSClassFromString 运行期解析+兜底；起手区 ±30→±6（-22 日志触点散布中心 ±35 环带=外扩+pan 迟到合成，收紧到胶囊本体）；系统拖胶囊翻页真载体=搜索层 SBSearchScrollView 横向滚动（SPG-GR 零输出=链上无手势），总开关开→其 pan enabled=NO 每 tick 维持、关→恢复（SPG-SUPPRESS 含 30s 心跳）；SPG-HIT 起手 hitTest 链诊断 |
| 220 | 1.2.0-23b | 1002025 | CI 编译修复：SearchScrollView 压制处 root 为 UIView 无 panGestureRecognizer 属性，isKindOfClass UIScrollView 转型后取（SearchScrollView 必为 UIScrollView） |
| 221 | 1.2.0-24 | 1002026 | 系统拖胶囊翻页真载体实锤（SPG-HIT：胶囊区 hitTest=SBFolderScrollAccessoryView<SBIconListPageControl，iOS17 page control 自带拖圆点翻页）：开关开→整层 userInteractionEnabled=NO（拖圆点/点圆点跳页同属系统行为一并关，用户确认无碍）、关→恢复，每 tick 维持；缓存帧防抖（-23b 日志帧在动画过渡帧与真帧间跳变致 begin outside 误判，>20pt 跳变需连续两 tick 一致才切换）；滑块行补 label property（ERSliderTrackCell 读 label/name，代码构建不自动生成）+ 换有效 symbol 修白块 |
| 222 | 1.2.0-25 | 1002027 | 需求对齐（用户）：胶囊保持可点开搜索+可拖拽显示，只杀拖拽翻页。回滚 -24 整层 userInteractionEnabled 过杀（胶囊互动全灭、横向落到桌面翻页）。外科手术三招：①SPG-GR2 一次性 dump page control 链手势清单；②pan/swipe recognizer 开关开只禁它们（外科手术式）；③纯 touches 兜底：类级 hook SBIconListPageControl/SBFolderScrollAccessoryView/_UIPageControlContentView touches 开关开时吞噬（翻页死，window pan 不受影响），单击<10pt 隐藏链后 hitTest 重放给下层（点击开搜索保住，SPG-TAPREPLAY 日志） |
| 223 | 1.2.0-26 | 1002028 | 横向系统翻页残留根因（-25 日志实锤）：圆点指示器 _UIPageControlIndicatorContentView 是独立兄弟类，touches 绕过 hook 进系统翻页（起手只有落在父层边缘才轮到我们的 pan——用户"边缘才能成功手势"实锤）。hook 放宽为类名含 PageControl/Accessory 一律挂 touches 吞噬（中心起手也被接管）；新增 SPG-PCSWALLOW 吞噬生效诊断（30s 限流） |
| 224 | 1.2.0-27 | 1002029 | 系统翻页真凶实锤（-26 日志：PCSWALLOW 命中但翻页照旧）：view 层 touches 吞噬只挡"触摸→view"通道，挂在祖先滚动视图（SBIconScrollView/SBSearchScrollView）上的 pan 手势识别器独立收到同一套触摸识别成功→翻页。ERSPGPageCtlScrollPan：Began 吞噬同时沿祖先链禁用全部 UIScrollView 的 pan（SPG-PCGR 日志，引用计数 gERSPGPageCtlActive），Ended/touchesCancelled（新增第 4 hook）计数归零恢复，10s 兜底强制恢复防卡死；桌面其他区域起手不命中 hook 不受影响 |
| 225 | 1.2.0-28 | 1002030 | -27 实锤修正：SPG-PCSWALLOW 命中但 SPG-PCGR 零输出=被吞视图祖先链无 UIScrollView（SBIconScrollView 不在圆点链里，touch hook 堵不住）。第 1 招主杀：gestureRecognizerShouldBegin: 类级闸门挂 SBIconScrollView/SBSearchScrollView（addMethod 优先不污染基类），开关开时 pan 落点在胶囊区（外扩 10pt）直接拒绝开始（SPG-GRGATE blocked 日志）；第 2 招诊断：PCSWALLOW 时一次性 dump 完整祖先链每层类名+手势清单（SPG-CHNDUMP） |
| 226 | 1.2.0-29 | 1002031 | -28 日志实锤闸门有效（SPG-GRGATE blocked 命中）但单缓存胶囊帧在底部真胶囊 {184,744} 与顶部搜索层胶囊 {24,13} 间跳变（begin ok p=(214,753) frame={24.6,13.6} 实锤），闸门拿错帧全放行。改多帧集合：每 tick 记录观察到的胶囊帧（去重保留最近 8 个），闸门判定=落点命中任一帧（外扩 15pt）即拒绝 SBIconScrollView/SBSearchScrollView 的 pan |
| 227 | 1.2.0-30 | 1002032 | 釜底抽薪：全版本证据（PCGR 零输出+pan 全禁仍翻页）判定 iOS17 拖圆点翻页=搜索控制器直接调 SBIconScrollView setContentOffset（不走 pan）。①封滚动源头：hook SBIconScrollView/SBSearchScrollView 的 setContentOffset:/animated:（addMethod 优先不污染基类），胶囊区触摸活动期（gERSPGPageCtlActive>0）丢弃非我方调用（SPG-COBLOCK 日志），我方跳页经 ERSPGJumpToPage 包装器 sERSPGOwnJump 放行；②胶囊 SBHSearchPillView 本体 touches 观察 hook（不吞只计数，SPG-PILLTOUCH），与圆点吞噬路径共用活动计数；③活动计数沿用 Ended/Cancelled 双路+10s 兜底恢复 |
| 228 | 1.2.0-31 | 1002033 | -30 用户实测：系统翻页概率大降但仍偶发（触摸起手不在任何 hook 类上时活动计数=0 封锁不生效）；①系统震动封禁：用户实锤拖圆点翻页自带震动与手势震动混淆，胶囊触摸活动期封锁 UISelectionFeedbackGenerator selectionChanged + UIImpactFeedbackGenerator impactOccurred/WithIntensity:（SPG-HAPTLOCK），我方 ERSPGHaptic 经 sERSPGOwnHaptic 放行；②窗口级 pan 起手入区纳入活动计数（Began-inside ++，Ended/Cancelled --）；③广谱挂载：扫描到的任意 SB 系 UIScrollView 一律挂 pan 闸门+CO 封锁（闸门只拦胶囊区，无副作用） |
| 229 | 1.2.0-32 | 1002034 | -31 用户实测：翻页封锁生效（COBLOCK 命中）但拖圆点仍带系统震动=震动发射器未覆盖（私有 Feedback/Haptic 子类自带实现绕过基类 hook）。①运行时广谱：objc_copyClassList 枚举类名含 Feedback/Haptic 的全部类（含私有），凡响应 selectionChanged/impactOccurred/WithIntensity:/notificationOccurred: 一律挂活动期丢弃拦截（SPG-HAPTLOCK broad n 日志）；②C 函数兜底：%hookf AudioServicesPlaySystemSound/AlertSound 活动期拦截；统一条件 helper ERSPGShouldDropSysHaptic，我方 sERSPGOwnHaptic 放行不变 |
| 230 | 1.2.0-33 | 1002035 | -32 用户实测破案："拖到中间圆点不震、两边才震"=翻页一直在发生（震动是边界页反弹触觉）——翻页走 SBIconController selector 链（setCurrentIconListIndex:/scrollToIconListIndex:animated: 等，内部直接动画，绕过 scrollview pan 与 setContentOffset）。类级 hook SBIconController 四个翻页 selector（SPG-ICBLOCK），活动期丢弃非我方调用（sERSPGOwnJump 放行我方跳页）；至此翻页三路全封：pan 闸门+setContentOffset 封锁+图标控制器 selector 封锁 |
| 231 | 1.2.0-34 | 1002036 | -33 实测仍翻页：COBLOCK 命中 setContentOffset: 但圆点仍动、ICBLOCK 四 selector 零调用=翻页走未知通道；本版 hook 圆点 setCurrentPage:（UIPageControl/_UIPageControl）活动期打印 backtrace（SPG-PCTRACE）定位真凶；并补私有变体 _setContentOffset: 封锁；心跳带挂载类计数 |
| 232 | 1.2.0-35 | 1002037 | -34 实锤：PCTRACE 零输出=setCurrentPage: 零调用、ICBLOCK 挂载正常零命中（icoCls=1）→ 圆点位移不走 currentPage 通道；-35 升级探针：直接 hook 圆点指示器本体 _UIPageControlIndicatorContentView 的 setFrame:/setBounds:/setCenter: + setCurrentPage:/updateCurrentPageDisplay 旁路，圆点动一帧即打印 backtrace（只观察不拦截） |### 1.2.0-34 (1002036)
| 233 | 1.2.0-36 | 1002038 | -35 backtrace 实锤真凶：CallAssist.dylib（TweakInject 注入 SpringBoard 的通话助手整合插件）在布局遍历中直接 setFrame: 挪圆点，绕开 currentPage 属性与一切 selector 通道；-36 圆点焊死：胶囊活动期丢弃 _UIPageControlIndicatorContentView 的 setFrame:/setCenter:（SPG-PCBLOCK），我方跳页 sERSPGOwnJump 放行，setBounds 保持只观察 |- 定位翻页真凶：hook 页面圆点 setCurrentPage:（UIPageControl/_UIPageControl），胶囊活动期打印调用者 backtrace（SPG-PCTRACE），决定性证据定位未知翻页通道
| 234 | 1.2.0-37 | 1002039 | -36 实锤 CallAssist 换 setBounds: 继续驱动（焊不死，圆点跳出胶囊）；采纳用户 B 方案：系统分页圆点隐藏（仅胶囊所在 window，关闭恢复）+ 胶囊常驻不变形（每帧恢复 hidden/alpha）+ 圆点完全自绘（SBIconScrollView contentOffset 换算当前页，CADisplayLink 驱动，位置跟随胶囊下方）|- 补漏：setContentOffset 封锁增加私有变体 _setContentOffset:（-33 实锤 COBLOCK 命中但圆点仍动）
| 235 | 1.2.0-38 | 1002040 | -37 问题：胶囊被 CallAssist 藏没（PILLRESTORE 救不回）、自绘圆点页数算错太多颗；-38 按用户规格重做：胶囊守卫（类级封 SBHSearchPillView 的 setHidden:YES/setAlpha:<1，SPG-PILLGUARD）+ 圆点挂进胶囊内部 + 页数读桌面 _UIPageControl.numberOfPages + 滚动停止 3s 圆点淡出恢复搜索胶囊观感 + 滚动中深灰圆点当前页 0.85 高亮放大 1.2x |- 心跳日志带 ico/co 挂载类计数，确认 -33 四 selector 挂载状态
| 236 | 1.2.0-39 | 1002041 | -38 日志实锤：SPG-PILLGUARD 零输出=守卫被前置条件卡死（胶囊被藏后 pill.window 空直接 return）；-39 修复：守卫挂载提前到 syncDots 首步（只依赖 pill 类）+ ERSPGFindIconSV 改 isKindOfClass 匹配子类 + 页数发布补充桌面 _UIPageControl.numberOfPages 源（iconLists 探测失败时设置页下拉框仍实时真实页数）|### 1.2.0-35 (1002037)
| 237 | 1.2.0-40 | 1002042 | 用户实测禁用全部其他插件胶囊仍不显示=排除 CallAssist，是 -37 PCHIDE 连坐（藏了胶囊视图树里的 PageControl 成员）；-40：PCHIDE 防连坐（与胶囊同树互为祖先/后代的不藏）+ PCHIDE 日志附父链 5 级 + SPG-PILLSTATE 每 2s 胶囊全套状态与祖先链 hidden 探针 + 设置页最后一页显示资源库（映射值不变）|- -34 探针结果：SPG-PCTRACE 零输出 → setCurrentPage: 从未被调用；心跳 icoCls=1 确认 SBIconController 四 selector 挂载正常但零命中
- -35 升级：hook 圆点指示器本体 _UIPageControlIndicatorContentView 的 setFrame:/setBounds:/setCenter:，圆点位置变化直接打印调用者 backtrace；补 setCurrentPage:/updateCurrentPageDisplay 旁路；全部只观察不拦截
### 1.2.0-36 (1002038)
- -35 backtrace 决定性证据：圆点 frame 由 CallAssist.dylib 直接驱动（非系统、非本插件），解释 -33/-34 全部封锁无效
- -36 圆点焊死：活动期丢弃圆点指示器的 setFrame:/setCenter:，无论谁推都动不了；松手恢复，我方跳页放行
### 1.2.0-37 (1002039)
- 用户拍板 B 方案：不与 CallAssist 打地鼠，系统圆点隐藏 + 自绘圆点替代
- 系统分页圆点隐藏（ERSPG-PCHIDE，仅胶囊所在 window）；PCBLOCK 封锁瞬间顺带强制隐藏
- 自绘圆点：SPG-DOTS 视图（7pt 圆点/间距 6，当前页放大 1.15x），CADisplayLink 常驻刷新，contentOffset 换算页码，位置跟随胶囊
- 胶囊防变形兜底：SPG-PILLRESTORE 每帧恢复 hidden/alpha
### 1.2.0-38 (1002040)
- 胶囊守卫：类级封锁 SBHSearchPillView 的 setHidden:YES / setAlpha:<1（CallAssist 藏胶囊的主要手段被封死）
- 自绘圆点移入胶囊内部居中；页数优先读桌面 _UIPageControl 的 numberOfPages（修复页数算错）
- 交互规格（用户定义）：翻页滚动中/结束后 3s 内显示圆点（深灰，当前页 0.85 高亮 1.2x），超 3s 淡出恢复系统"搜索"胶囊原样
### 1.2.0-39 (1002041)
- 修复守卫卡死：ERSPGSyncDots 首步即挂胶囊守卫（不依赖 window/scrollview），CallAssist 藏胶囊前守卫已就位
- ERSPGFindIconSV 改 isKindOfClass 匹配（SBIconScrollView 子类实例也算），自绘圆点数据源建立
- 页数实时化：发布链路补充桌面 _UIPageControl.numberOfPages，设置页"选择第几页"下拉框反映真实页数
### 1.2.0-40 (1002042)
- PCHIDE 防连坐：与胶囊互为祖先/后代的 PageControl 视图不再隐藏（胶囊消失根因假设）
- SPG-PILLSTATE 探针：每 2s 胶囊 hidden/alpha/frame/transform/opacity + 祖先链逐级 hidden 检查
- SPG-PCHIDE 日志附父链 5 级类名（归属判断）
- 设置页"选择第几页"最后一页显示"资源库"（ERGesturePageText，映射值不变）

### 1.2.0-41 (1002043)
- 自绘胶囊底：胶囊内最底层插入圆角底视图（系统底色层被折腾没了只剩"搜索"label，截图实锤）
- 圆点固定 3 颗循环：高亮 = 页码 % 3，翻页淡入、3s 无翻页淡出
- FindIconSV 评分制：主屏窗口 +1000、宽度最接近屏宽优先（修抓错文件夹/小组件滚动视图导致圆点永不出现）
- 命中判定改实时帧：ERSPGPillRTWinFrame（convertRect 到窗口），pan 起手与 GR 闸门均启用（修点击/拖拽失灵）
- SPG-DOTSSTATE 探针：每 2s 滚动视图类名/尺寸/offset/页数/圆点 alpha/胶囊底在场
- refresh 删 contentSize 早退条件

### 1.2.0-42 (1002044)
- 圆点根因修复：桌面页控件类名实为 UIPageControl（-41 日志实锤），sERSPGHomePCRef 匹配条件补上该类名
- 页数第三源：numberOfPages/contentSize 都拿不到时读已发布的 HomeScreen.PageCount
- 恢复胶囊 userInteractionEnabled（-41 hitTest 落在 accessory view = 触摸进不了胶囊，点击搜索失效根因）
- DOTSSTATE 探针前移到页数守卫之前（旧位置在 pages<1 return 之后，恰好盲区盖住真因），附 pc 类名/raw 页数
- PILLSTATE 增 ue= 交互标志；SPG-PAN armed 附四方向配置值（拖拽无反应=没配置还是读不到，一眼可辨）

### 1.2.0-43 (1002045)
- 翻页期间隐藏胶囊内文字/图标（底壳+圆点除外），3 秒恢复时还原（-42 实锤圆点与"搜索"叠显遮挡）
- 页数可信度：numberOfPages 仅 ≥2 才采用（-42 日志实锤本机假报 1 导致 14↔1 抖动）
- 点击进搜索：自挂单击手势（cancelsTouchesInView=NO），转发给胶囊上系统单击手势的 action，附 SPG-PILLGEST 手势清单 dump
- 关闭功能时还原被隐藏的文字/图标

### 1.2.0-44 (1002046)
- SPG-SRDUMP：一次性 dump SBHSearchPillView/SBFolderScrollAccessoryView/SBRootFolderView/SBIconScrollView/SBIconController/SBRootFolderController 的 earch selector（实例+类方法）
- 目的：-43 实锤系统胶囊无点击手势，锁定点进搜索的真实载体，供下一版接自挂单击

### 1.2.0-45 (1002047)
- 点击进搜索落地：-44 SRDUMP 实锤 SBIconController `_handleSearchAffordanceTap` 为系统原生胶囊点击处理
- 自挂单击改为直调该方法（respondsToSelector 守卫 + @try 兜底），旧转发路径保留为 fallback

### 1.2.0-46 (1002048)
- 失效校验：父视图隐藏的胶囊候选不追踪（-45 实锤搜索借用未归还的残局实例=点击返回全面消失），SPG-PILLBAD 记录
- 无有效候选时每 5s 催 SBRootFolderView setNeedsLayout，催系统重建桌面胶囊
- 滚动视图必须挂在主屏窗口，失效即重扫（修翻页无圆点），SPG-SVBAD 记录
- 原生壳恢复：searchAffordanceBackgroundView 存在则恢复显示并退役自绘底；自绘底降级为兜底；SPG-PILLTREE 一次性 dump 子视图树
- 翻页藏字逻辑豁免原生底

### 1.2.0-47 (1002049)
- 胶囊身份锁：只认"底部小胶囊"（窗口高度≤44pt 且位于屏幕底部 1/4，SPG-PILLLOCK acquired）；已锁实例存活时扫描直接复用不重扫，锁失效（搜索借用/移除）时不另寻新欢，只催 SBRootFolderView 重建（-46 日志实锤第二次点击后追踪实例被切成搜索层大胶囊 frame {8,496,414,48}）
- 原生底主动挂载：MTMaterialView 不在 pill 内/frame 为空/被藏时直接 insertSubview atIndex:0 + 铺满 bounds + 复显（-46 实锤 getter 返回成功但视觉无效），SPG-PILLBG 诊断含 frame/superview/remount
- 翻页双判据：offset 变化 + 页控件 currentPage 轮询；currentPage 变而 offset 不动判 sv 失联重扫（SPG-SVSTALE），修 ox 变化但 dAlpha=0 的圆点不亮
- DOTSSTATE 探针加 cur/lock 字段；syncDots 只维护被锁定实例

- (rebuild) trigger fresh CI run: first run 39543525655 artifact compiled -46 source despite head e295cd

### 1.2.0-48 (1002050)
- 完全放手（用户拍板"去掉绘制的底板，让原生的显示出来"）：删除自绘黑底与 MTMaterialView remount 全部视觉干预，系统底由系统自己渲染；历史自绘底每 tick 清理退役
- SPG-PILLIVAR 一次性探针：dump SBHSearchPillView 全部 UIView 类型 ivar（定位系统底板真身）
- 页数上限 12→24：-47 日志实锤桌面 14 页被旧上限拦截 return——ox 变化而 dAlpha 恒 0（圆点不显示）的决定性根因
- 灰框随自绘底退役消失（自绘底跟搜索借用动画放大所致）

## 1.2.0-49
- 移除 -37 时代显示守卫（ERSPGAttachPillGuard 类级封锁 setHidden:/setAlpha:），根因：守卫把系统搜索借用流程卡死（胶囊放大移到屏幕中部再收回全被拦），胶囊冻在放大空白态=灰色长方形。防消失由身份锁+SBRootFolderView 催重建兜底
- 圆点改白色（rebuild 0.45 / 高亮 0.95 / 其余 0.40）

## 1.2.0-50
- A 方案：给原生胶囊自身 layer 补胶囊形兜底底板（不新建不替换视图），SPG-PILLCHAIN 探针 dump superview 链

## 1.2.0-51
- 用户拍板撤除 -50 兜底底板（非系统自带），清空胶囊 layer 背景回归纯原生（裸文字+白圆点）
- 如实结论：系统桌面态不创建底板（PILLIVAR/PILLCHAIN 实锤），且系统搜索胶囊本身固定底部不提供拖拽

## 1.2.0-52
- C 方案：PILLCHAIN2 直落盘探针（多路径写文件+NSLog 双保险），绕过日志门/沙箱，找胶囊视图链上有无被系统隐藏的真底板；视觉不变（纯原生）

## 1.2.0-53
- 用户截图实锤根因：-51/-52 的 layer 清理三行每次布局抹掉系统画在胶囊 layer 上的原生底板（底板消失+拖动失效）。删除清理，原生底板/拖动恢复；自绘白圆点保留（避开系统页点震动）

## 1.2.0-54
- 搜索胶囊模块整体回退到 1.2.0-32 形态（用户拍板）：Tweak.xm 与 -32 版逐字节一致（diff 实证 -33~-53 全部差异仅在 SearchPill 模块内）。胶囊恢复完全原生（底板/拖动/点击），移除身份锁/点击转发/自绘圆点/全部探针；保留手势跳页+震动封禁模块与 -40 设置页「资源库」命名

## 1.2.0-55
- 起手区收紧到胶囊本体：pan 命中外扩 6→0，手势闸门外扩 15→0（误触真凶）；触发距离保持默认 20pt

## 1.2.0-56
- 触发区改「中心圆」：主胶囊/帧列表均以中心点 r=18pt 判定（pan 起手+手势闸门两处），两端空白不再触发
- 下拉框新增「负一屏」选项（值 -1）：Tweak 放行 -1，候选链探测今天视图跳转入口，未命中一次性 dump 方法表落盘 er_todayprobe.txt
- 下拉按钮左内边距 10→3pt，「第10/12/13页」完整显示

## 1.2.0-57
- 触发区改「整个胶囊」：-56 中心圆 r18 用户实测偏窄触发难，改矩形包含判定（胶囊 frame 内任意一点起手，四方向滑均触发；主胶囊+帧列表两处同步，无外扩无内缩）
- 负一屏修复：er_todayprobe.txt 实锤真正入口 SBIconController activateTodayViewWithCompletion:（1 参 block，nil completion 安全），置于候选链首位，原 8 候选保留兜底

## 1.2.0-58
- 触发区=整个可见玻璃：-57 用户实测失灵触点均在逻辑帧外 2.3~11.3pt（玻璃可见底板比逻辑帧大一圈，现象即"只有边能触发"）。矩形外扩 左右+4pt 上下+12pt（CGRectInset -4/-12），主胶囊+帧列表两处同步；红框内任意点四方向滑均触发
- 负一屏确认修复（-57 日志多次命中 activateTodayViewWithCompletion:），本版不动

## 1.2.0-59
- 手势值改两级下拉（用户拍板）：一级=无动作/桌面页›/文件夹›（›为子菜单标识，须再选一次）；桌面页二级=负一屏+第1~n页（末页资源库，保持占用互斥）；文件夹二级=读 Tweak 落盘的 /var/mobile/Documents/er_folders.plist
- 值编码升级：数字（CFNumber 旧版兼容）或 "folder:<id>"（CFString）；Tweak 读原始串统一派发 ERSPGDispatchGestureValue（无动作/负一屏/开文件夹/跳页），pan+touches 双通道 5 处同步
- 文件夹枚举：SpringBoard 内 SBIconModel.folders→[{id,name}] ctor 后 20s 落盘；通道落空一次性方法表落盘 er_folderprobe.txt
- 一键打开文件夹：iconForFolder:/folderIconForFolder: 取图标 + openFolderWithIcon: 等 4 候选链探测（负一屏打法），落空方法表落盘

## 1.2.0-60
- 修文件夹枚举：-59 落盘探针实锤 iOS16/17 图标模型为 SBHIconModel、无 folders 字典 → 改 rootFolder 递归遍历（rootFolder→lists→icons→SBFolderIcon.folder 取 uniqueIdentifier+displayName），旧 folders 通道保留兜底；打开文件夹同样遍历定位 SBFolderIcon 再走候选链

## 1.2.0-61
- 与乌贼手势（SquidGesturePro 2.7.6-2）共存：拆包实锤其主屏幕下划按底部左/中/右分区判定，与胶囊触发区重叠。① 触发区收回胶囊本体（撤销 -58 外扩，外扩带正压其起手带）；② 手势开关关时 pan/touches 全通道完全透传（pan began/TouchArm/TouchRelease 补 Enabled 前置检查，不再压 pager/记闸门）；③ pan delegate 本就声明同时识别（-8 已有），松手才动作不变
- 修设置页不显示「文件夹」：根因=设置进程缓存旧代码，装机脚本 kill Settings 没杀到真正的 Preferences 进程，补 killall Preferences

## 1.2.0-62
- 乌贼冲突硬修复：window pan 创建时 cancelsTouchesInView/delaysTouchesBegan/delaysTouchesEnded 全关——pan 识别成功后默认向视图发 touchesCancelled，起手在胶囊内的乌贼下划收不到 touchesEnded 即死（-61 透传修复未覆盖此机制）
- 下拉框打开加诊断日志（code=-62 level1=3）：定位"设置只显示两项"是加载旧代码还是渲染问题

## 1.2.0-63
- 乌贼冲突真根因修复：-62 日志实锤用户 15 次下划全记 `SPG-PAN begin outside`——window pan 挂整个 SBHomeScreenWindow、桌面任意移动即 Began 抢跑，非同时识别的乌贼手势被系统强制失败。ERSPGPanDelegate 新增 gestureRecognizerShouldBegin:：起手点不在胶囊矩形 sERSPGPillWinFrame 内直接 return NO，pan 只在胶囊内生效
- 下拉框 z-order 修复：用户截图实锤面板被设置表格内容压底（"文件夹 ›" 被遮挡，prefs 日志 code=-62 level1=3 证明 3 项已构建）。ERGestureShowDropdown 改为独立悬浮 UIWindow（同 windowScene、windowLevel=anchor+2000、rootViewController 持 container、closer 统一收起、静态表持有防释放），不再 addSubview 进设置 window

## 1.2.0-64
- 下拉框仍只显示 2 项排查：设备侧实锤（bundle 唯一副本含 -63 新代码、prefs 日志 level1=3、二级制含"文件夹›"UTF-16LE 串），像素级测量 -63 截图：面板 132pt 宽/y 定位精确吻合、行距 40pt 正常，但总高只有 ~98pt=2 行——3 项在独立 UIWindow 下的 UITableView 布局行为异常
- 防御修复：menu 显式 frame（不再用 contentView.bounds 时序）+ contentInsetAdjustmentBehavior=Never + 显式 rowHeight/estimatedRowHeight
- 诊断日志：布局完成后落盘 options.count/anchor/overlay/panel/menu 几何 + rows + 可见 cell 文本；cellForRow 逐行落盘文本

## 1.2.0-65
- 下拉框末行不可见真根因实锤（-64 日志）：独立 UIWindow 下的 UITableViewStylePlain 恒定多 72.33pt（content = rows×40 + 72.33，3 行/13 行两级菜单均精确吻合）= section header 36.16pt + footer 36.16pt，cell 整体下移 36pt → 一级菜单第 3 行"文件夹›"起点 116pt、面板 120pt 截断只露 4pt。同时解释 -59 以来"设置只显示两项"的全部现象（此前误判为进程缓存/z-order）
- 修复：bridge 实现 heightForHeader/Footer=0.01 + viewForHeader/Footer=nil；menu sectionHeaderHeight/sectionFooterHeight/estimated*/sectionHeaderTopPadding 全部清零

## 1.2.0-66
- 下拉框三项显示确认修复（-65 日志实锤：cells 在 0/40/80 全可见）
- 文件夹二级去重：-65 日志 dumped=16 实为 8 个文件夹各两遍（walk 的 lists/icons 两路径重叠）→ walk 加 seen 集合去重 + prefs 显示层按 id 去重兜底
- 文件夹打开手势 miss 真相（-65 探针 v59）：folderObj(SBFolder) 找到了，但 SBIconController 没有 openFolderWithIcon:/_openFolderWithIcon:/openFolder:/presentFolder: 任何一个 → 4 候选全落空。新证据：iconManager:willOpenFolder: 系（入口在 iconManager）、_openFolderController、SBFolder.folderWithUniqueIdentifier:
- 修复：FindFolderIcon 复用已验证的 walk 建 iconMap 查 id（旧手写 DFS 废弃），兜底 folderWithUniqueIdentifier:；OpenFolder 改多目标宽候选链（ico/iconManager/model/rootFolder/图标/文件夹 × 12 个 open/present/launch 选择器，命中即调 + 异常保护），miss 时探针升级 v66（+iconManager/rootFolder 方法表 + SBFolderController 类方法表，filter folder/open/present）

## 1.2.0-67
- -66 日志实锤：find 已通（icon=SBFolderIcon folder=SBFolder），12 个宽候选全落空，_openFolderController 无参兜底无效果且提前 return 导致 v66 探针没写出
- 候选再加：openFolderForIcon:/_openFolderForIcon:/openFolderControllerForIcon:/_openFolderControllerForIcon:/_openFolderControllerAnimated:（目标侧）+ 图标自身 launchFromLocation:/open/launch/openFolder（tweak 圈标准启动 API，nil 实参=整数 0）
- miss 探针必写（修 -66 提前 return 问题）：v67 过滤放宽 folder/open/present/launch/tap/show，manager/iconObj 全方法表 + SBFolderController 类全方法表

## 1.2.0-68
- -67 日志：17 候选（含 manager 侧 + 图标自身 launchFromLocation:/open/launch）全落空，查找链完美（icon=SBFolderIcon folder=SBFolder）；_openFolderController no-arg 无可见效果且 return 又一次跳过探针（-66 同坑二犯）
- 修复：no-arg 兜底不再 return，miss 探针 v67 必达（manager/iconObj/rootFolder 过滤表 + SBFolderController 全表），下一版按真实方法表精确锁定打开入口
- 附注：尝试离线 strings SpringBoard 二进制失败（iOS 系统二进制为空壳，真代码在 dyld 共享缓存），运行时方法表是唯一可靠途径

## 1.2.0-69
- v67 探针实锤（313KB 方法表）：真入口 = SBHIconManager.openFolderIcon:location:animated:withCompletion:（manager=SBHIconManager）；-67 的 17 个候选恰无此 4 参选择器所以全落空；图标侧 launchFromLocation: 对文件夹无效
- 修复：ERSPGOpenFolder 候选链最前精确调用该选择器（location=icon.location 兜底 rootFolder.location，animated=YES），调用后 0.8s 验证 openedFolder 非空并写日志（区分真打开与静默失败）

## 1.2.0-71
- 用户实测 -70：跨页无效果。日志盲区：targetPage 定位失败时代码走立即打开分支且探针没写（条件含 targetPage>=0）
- 修复①（已审核新功能）：手势管理子页触发范围上面新增「手势区域」滑块（HomeScreen.SearchPill.AreaExpand，0~40pt 默认 0）——起手判定区=胶囊本体四周外扩 N pt 矩形（含四角均可触发）；ERSPGPointInAnyPill/GR 竞争闸门同步外扩保证行为一致；footer 注明外扩过大可能压乌贼手势起手区
- 修复②：探针条件放宽为 !switched 必写，附 targetPage/listCount/iconLists 每页详情（list 类名+图标数+是否含目标图标）

## 1.2.0-72
- v70 探针实锤（-71 必写生效）：SBHIconManager.scrollToIconListContainingIcon:animate: = 系统自带"滚到包含该图标的页"；-71 的 targetPage=-1 根因=rootFolder 不响应 iconLists（listCount=0）
- 修复：openFolderIcon 前优先调用该 API（animated=YES，命中即 switched）；落空才走 iconLists 手写定位+8 候选链兜底；探针逻辑保留

## 1.2.0-73
- 用户实测 -72：跨页文件夹能打开了，但成功率仅 2/10（翻页动画时长不定，固定 0.45s 后开文件夹常撞在半路）
- 修复①：重试机制——openFolderIcon 后 0.6s 自检 openedFolder，为空自动补开，最多 3 次尝试（递归块自引用仅终态释放）
- 修复②（用户需求）：手势区域滑块默认 0→20、上限 40→60（prefs 与 Tweak clamp 同步）

## 1.2.0-74
- 用户实测 -73：成功率仍 1-2/10（重试全撞翻页动画半路）；关文件夹时 3-4/5 注销崩溃；回桌面手势失灵 5-15s；0.45s 延迟
- 修复①：scrollToIconListContainingIcon 改 animate:NO 瞬间跳页（用户需求），翻页同步完成 → openFolderIcon 立即调用，删除 0.45s 固定等待（动画竞态根除，同时修成功率与延迟）
- 修复②：completion 护栏——openFolderIcon 传 erCompletion 标记 erOpened，打开过就永不重试（重试打在关闭动画里 = SBHIconManager 崩溃 = 注销，3-4/5 根因）
- 修复③：起手判定与 GR 闸门实时取胶囊帧（返回桌面后缓存过期 = 5-15s 失灵根因），缓存只作兜底
- 修复④：页码跳页 pager 兜底路径 setContentOffset animated:NO（瞬时跳页，用户需求）

## 1.2.0-75
- 用户实测 -74：秒关手势仍 4-5 次注销一次；成功率仍 1-2/10；跳页瞬时效果满意；负一屏手势无效果、翻页后才补跳；下拉框收起态只放得下 3 字
- 修复①：忙碌护栏——openFolderIcon 前置检查 openedFolder/_currentFolderController，任一非空（正在打开/已打开/正在关闭）直接跳过本次手势；重试路径同样检查（retry skip busy）。崩溃=重复 openFolderIcon 打在过渡动画里
- 修复②：文件夹诊断直写 /var/mobile/Documents/er_folderlog.txt（主日志走 buffer 需导出，直写立即可拉），open/verify/retry/give up 全记录
- 修复③：负一屏 activateTodayViewWithCompletion: 调用后 0.3s/0.9s 两次重发（排队过渡强制推进，幂等无害）
- 修复④：下拉框收起态测量基准加 4 字样例「乌贼软件」（约 +15pt，内部结构不动）

## 1.2.0-76
- 用户实测 -75：负一屏已修好✅、下拉框4字✅；**回归：文件夹完全打不开**（所属页也不行）
- 根因实锤（er_folderlog.txt）：忙碌护栏把桌面误判——_currentFolderController 恒为 SBRootFolderController（桌面本身就是根文件夹控制器），非空检查全被"busy skip"跳过，日志无一条 open 记录
- 修复①：新增 ERSPGCurIsRealFolder()——类名含 RootFolderController 的不算忙碌；前置护栏与 retry 路径都改用它
- 新功能②：「搜索胶囊手势」行标题右侧加蓝色 ⓘ 按钮，点击弹窗显示原 footer 说明文字（删乌贼手势那句——实测 60 也不影响）；原 g1 footer 整段删除
- 新功能③：左滑/右滑胶囊图标 teal→blue（与上下滑一致）；手势区域/触发范围图标改 purple（纯色，用户指定不要渐变）
- 新功能④：下拉框间距定版（用户审核）：文字距左 4pt、文字到箭头 3pt、箭头距右边框 4pt（箭头中心去 +1 视觉补偿），按钮总宽=文字宽+25（较 -75 窄 7pt），4 字仍完整显示

## 1.2.0-77
- 用户实测 -76：成功率仍 1-2/10；**点空白关闭 100% 注销**；图标颜色已解决；下拉框退回上一版；ⓘ 移到组头「搜索胶囊」右侧
- folderlog 实锤①：open 每次都调、completion 每次都触发（erOpened=1），但 verify of=SBFolder 的次数才=肉眼成功次数 → openFolderIcon 静默失败为主；共同点 loc 恒 (null) → -77 依次尝试 rootFolder/model 的 locationForIcon:/locationOfIcon: 并把 loc 状态写进 folderlog
- folderlog 实锤②：17:37:23 open → verify ok of=SBFolder（真打开）→ 用户点空白秒关 → 17:37:24 又一次 open 后无 verify = 当场崩 → 关闭过渡中 openedFolder/_currentFolderController 双双读空（guard 盲区）→ 修：打开后 2.5s 冷却期，冷却内手势直接跳过（cooldown skip 记日志）
- ⓘ 移位：删行上 erInfoText；ERGestureController 新增 ERGestureInstallGroupInfo（扫描 tableView 找「搜索胶囊」label 挂 18pt ⓘ 按钮 tag 7601，viewWillAppear 0.3/0.9s 双时机）+ erGroupInfoTapped 弹窗
- 下拉框：pad 6 / btnW=T+12+14+6 / chevron +1 全部恢复 -75

## 1.2.0-78
- 用户实测 -77：手势管理子页面打开即闪退（EXC_GUARD，Sileo 崩溃日志无符号栈）
- prefs 日志实锤崩溃窗口：viewDidLoad 完成 + 4 个下拉 cell init 后 1~2s 进程消失 = 组头 ⓘ 安装定时器（0.3/0.9s）运行窗
- 排查版改动：安装前后埋点（group info install begin/ok/label not found/ threw）+ @try 保护 + 延迟 0.6/1.2s + 开关行 layoutSubviews 加 _erInfoBtn 非空守卫（nil 消息 hidden=NO 导致分支误入的隐患）
- 下次拉 EchoReborn-prefs.log：见 begin 无 ok = addSubview/scan 段；无 begin = 崩在更早（cell/viewWillAppear）

## 1.2.0-79
- 用户实测 -78：不闪退了✅（@try 兜住）；但 ⓘ 不显示；成功率仍 2/18
- 埋点实锤闪退真凶：-[ERGestureController tableView]: unrecognized selector——PSListController 运行时无 tableView 方法（编译有声明、运行时没实现）。-77 的闪退 = 同一异常无 @try 直接崩；ⓘ 不显示 = 每次安装都在这一句抛异常
- 修复①：ERGestureFindTableView 从 self.view 递归找 UITableView 替代 self.tableView
- folderlog 实锤：locationForIcon:/locationOfIcon: 在 rootFolder/model 均不响应，loc 仍全 null；成功次数仍精确对应 of=SBFolder
- 修复②：location 候选补 model/manager 的 iconLists 逐页 locationOfIcon:；加一次性方法表探针——把 rootFolder/model/manager/iconObj 所有含 "ocatio" 的方法名 dump 进 folderlog，为下一版拿准真 API

## 1.2.0-80
- 用户实测 -79：ⓘ 已显示可点击✅但偏大；成功率依旧（18 中 2）；点空白关闭仍注销
- 探针金矿：SBHIconManager 有 bestLocationForIcon: / bestHomeScreenLocationForIcon: / _folderControllerForIcon:inLocation: / _animateFolderIcon:open:location:animated:withCompletion: / SBFolderIcon launchFromLocation:context:；此前试的 locationForIcon:/locationOfIcon: 均不存在 → loc 恒 null
- 根因链：loc=nil 打开的文件夹系统状态残缺 → 只有少数次"歪打正着"真打开（of=SBFolder）→ 残缺状态关闭过渡崩 = 点空白注销。修 location = 同时修成功率 + 注销
- 修复①：location 候选链 = manager bestLocationForIcon: → bestHomeScreenLocationForIcon: → icon.iconLocations 首个 → 旧链兜底
- 修复②：ⓘ 用组头文字字号生成 SF Symbol（configurationWithFont），side = 文字行高

## 1.2.0-81
- 用户实测 -80：成功率更低（20 中 1-2）；点空白关闭仍注销；ⓘ 延迟约 1s 显示、距文字间距太宽
- folderlog 实锤：loc=nonnull 但 class=__NSCFConstantString → bestLocationForIcon: 返回 SBIconLocationRoot 常量（"往根桌面加新图标"的方法）——不是图标本体位置
- 修复①：location 候选链改为 icon.iconLocations 首个优先（真格子位置；respondsToSelector 含继承，-80 时被 best* 抢先永远轮不到），Root 常量字符串视为无效跳过；附 iconLocations count/first 日志
- 修复②（成功率真根因）：翻页后图标视图要等一次布局才创建，就绪前 openFolderIcon 静默失败 → 打开前轮询 manager iconViewForIcon:location: 每 0.1s 一次最长 1.5s，出现即开；iconView 类名/pollsUsed 记日志
- 修复③：ⓘ 定时器 0.6/1.2→0.25/0.6s（-78 实锤异常已修，1 秒延迟是定时器太晚）；间距 6→3pt

## 1.2.0-82
- 用户实测 -81：成功率仍 1-2/20；触发到打开 2-3 秒不可接受；ⓘ 大小/间距已解决
- folderlog 三实锤：①每次 `iconLocations selector missing`——SBFolderIcon 不响应 iconLocations，候选链全落空 → loc=(null)；②iconView 轮询全部 `timeout pollsUsed=16`（loc=null 时 iconViewForIcon 恒 nil）→ 每次白等 1.5s = 慢 2-3s 直接原因；③loc=(null) 仍有 ~3/15 of=SBFolder 偶发成功（图标恰在当前页时系统兜底）——所有版本的随机成败都源于此
- 修复①：location 主候选改为枚举 rootFolder.iconLists 找含该图标的 list（page+idx）→ manager `iconLocationForList:inFolder:ofRootFolder:` 换算真 SBIconLocation（探针实锤存在）；iconLocations/best* 全降兜底；日志 listFound page=%lu idx=%lu locClass=%@
- 修复②：iconView 轮询 0.1s×15 → 0.05s×10（最长 0.5s）；location 修对后 iconView 应立即就绪，正常路径零等待，恢复 -80 手感

## 1.2.0-83
- 用户实测 -82：成功率更低、仍慢 1-2s、点空白关闭进安全模式（新证据：loc 残缺时 openFolderIcon 打开的状态连关闭都崩）
- folderlog：-82 的 listFound 一条没有 → er_folderprobe.txt 实锤 `iconLists=nil (rootFolder=SBRootFolder)`，SBRootFolder 不响应 iconLists，-82 枚举空转
- 探针金矿（er_folderprobe.txt）：SBRootFolder 有 `listAtIndex:`/`lastVisibleNonEmptyListIndex`；SBFolderIcon 有 `launchFromLocation:context:`（原生点击启动入口）
- 修复①：list 定位改 rootFolder listAtIndex: 逐页循环（上界 lastVisibleNonEmptyListIndex，兜底 49），找到含图标页 → manager iconLocationForList:inFolder:ofRootFolder: 换算真 location，日志 listFound page/idx/locClass
- 修复②：loc 非空时跳过 iconView 轮询（触发即开，恢复 -80 手感）；opener 改 launchFromLocation:context:（无 loc 才 openFolderIcon）；verify/retry 链共用

## 1.2.0-84
- 用户实测 -83 + folderlog A/B 铁证：listFound page=2 idx=2 每次命中（页面绑定没问题，locClass=__NSCFConstantString=SBIconLocationRoot 是桌面图标正规位置写法）；iconView=SBIconView 时 launch 全部 of=SBFolder 成功，iconView=timeout 时硬 launch 全部 retry→give up 失败——成功率 100% 对应"图标视图是否就绪"
- 修复：一律等 iconView 就绪再 launch（轮询 0.05s×40=2s，就绪瞬间即开零延迟）；重试 2→1（连发 launch 是点空白注销嫌疑）
- prefs：系统增强子页录屏设置/锁屏音乐卡片下新增「注销设置项」卡片——开关「注销不锁屏」（Respring.SkipLockscreen，默认关，lock.open 图标），本版仅 UI，功能下版接（用户自己找插件参考）
- push 脚本补 push9/SystemEnhance.plist

## 1.2.0-85
- 用户实测 -84：成功率仍 1/20-30；注销规律——立刻开立刻点空白必注销，停留 2-5s 不注销
- folderlog：成功案例 pollsUsed=0（图标已在当前页），失败案例 pollsUsed=41 全超时（2s 视图都不出现）→ 疑似 scrollToIconListContainingIcon 没真正落地或布局被打断
- 修复：轮询 4s（0.05×80）+ 每 1s 重发一次翻页 + 每 1s 记 currentIconListIndex 对比目标页（page=2）
- 注销不锁屏功能（用户提供参考插件 byg.iosios.net.zhuxiao_0.0.3 / NoPassAfterRespringSafe，已反汇编破解）：
  ① %hook SBBootDefaults dontLockAfterCrash（+/- 两个变体）开关开时返 YES
  ② %hook SpringBoard applicationDidFinishLaunching: 尾部 [SBLockScreenManager sharedInstance].coverSheetViewController setAuthenticated:YES
  开关 Respring.SkipLockscreen（-84 已加 UI），关=全部 %orig

## 1.2.0-86
- 用户实测 -85：成功率 100%！注销不锁屏功能完全可用；遗留：打开后立刻点空白关闭 → 注销（停留 2-5s 则不注销）；速度有延迟待后续优化
- 主日志实锤注销机制：打开 → verify(0.6s) 时用户已秒关 → of=nil → retry 分支在关闭过渡中重发 launch → SB 状态崩 → respring（停留 2-5s 时 verify 早已终态故不注销，与用户观察完全吻合）
- 修复：彻底移除重试（of=nil 一律按"已被用户关闭"处理，no-retry give up 日志）；erRetries 变量删除

## 1.2.0-87
- 冲突排查：禁乌贼仍注销→Choicy 白名单仅 EchoReborn 仍注销→确认是 EchoReborn 自身关闭路径触发；干净 respring 无 .ips → 疑未捕获 ObjC 异常被 roothide 引导程序静默 respring
- 修复：NSSetUncaughtExceptionHandler（applicationDidFinishLaunching 里 dispatch_once 安装）→ 异常名/原因/调用栈写 folderlog（EXCEPTION name=... 前缀）
- 提速实验：erTryOpen 轮询 poll#20 时除重发翻页外追加 layoutIconListsWithAnimationType:0 强制布局（目标跨页 1s→0.5s）

## 1.2.0-88（2026-10-23）
- 重大诊断：-87 watchdog .ips（bug_type 288）实锤注销 = SpringBoard 死于 SIGNAL 11（段错误），非 ObjC 异常（folderlog 0 字节、NSSetUncaughtExceptionHandler 抓不到）
- 用户实测新情报：手动快速开关文件夹也 4-5 次注销，手势触发 1-2 次即注销 → 疑"开/关过渡期"我们的 launch/open 调用踩已释放对象
- sigaction 装 SIGSEGV/SIGBUS/SIGABRT/SIGILL 处理器（async-signal-safe：open/write/backtrace_symbols_fd），信号号+出错地址+完整调用栈写 folderlog（前缀 `SIGNAL sig=`），写完恢复默认并 re-raise 保留正常崩溃流程
- erTryOpen 每跳轮询前查 openedFolder/_currentFolderController，检测到开/关过渡一律中止（`poll aborted (transition)`），防止向过渡中的系统打 launch
- 版本 1.2.0-88 / 1002170

## 1.2.0-89（2026-10-23 晚）
- -88 实测：手动开关 10 次注销、手势 100% 注销；但 SIGNAL sig= 零触发、无 .ips、JetsamEvent 最大进程是抖音（干扰项）
- 用户体感："哪里都没点，注销完自动进桌面，和手动点注销一模一样" → 干净退出
- 取证三件套：①atexit → ER-ATEXIT+backtrace（exit() 必经）②hook _relaunchSpringBoardNow:/relaunchSpringBoard/_relaunchSpringBoardIfRequested → ER-RELAUNCH+调用者backtrace ③主线程心跳 2s/5s 超时 → MAIN HANG
- 版本 1.2.0-89 / 1002175

## 1.2.0-90（2026-10-23 夜）
- 单变量实验：卸载 memorycontrold 守护进程 + Enabled=false → 注销 100% → ~5-10%（主帮凶实锤；其配置实为给 SB 提 jetsam 优先级 210，但与抖音 900MB 常驻相互作用的机制待定）
- 残余注销：探针仍全沉默、无 jetsam、无 .ips → 锁定 killall -1（SIGHUP）/SIGTERM 软注销手法（默认动作终止、无报告、atexit 跳过）
- 信号捕获器补 SIGHUP/SIGTERM → 下次现场写 SIGNAL sig=1/15
- roothide 核心组件（jailbreakd/hookd/boomerang）无杀进程字符串；idownloadd 为 roothide 自带 iDownload 调试台（Disabled=true）
- 版本 1.2.0-90 / 1002180

## 1.2.0-91（2026-10-23 夜）
- 用户拍板方案A：挂起低频注销（~5%，探针继续攒样本），主力提速 1s→0.5s
- 提速三刀：①layoutIconListsWithAnimationType 强制布局 poll#20→poll#2（0.1s）+每10跳补发 ②前3跳轮询 0.05s→0.03s ③全程计时埋点（open/forced-layout/iconView/launch/verify 均带 t=毫秒）
- 版本 1.2.0-91 / 1002185

## 1.2.0-92（2026-10-23 夜）
- 用户关键情报："触发手势后先当页停留一下再跳转"→ 定位两个延迟源：①松手才派发 ②每次手势全模型遍历找文件夹图标（100-300ms）
- 达标即触发：pan/touch 双通道中 folder 动作达标瞬间直接派发（不等松手），日志 arm-instant；页码跳转保持松手落地
- folderId→icon 弱引用缓存（NSMapTable strong key/weak value），命中零遍历
- 版本 1.2.0-92 / 1002186

## 1.2.0-93（2026-10-23 深夜）
- -92 达标即触发判死刑：用户实测触发手势后桌面整页锁死（滑动/翻页全无响应，开 app 回桌面才恢复）——提前派发使手势事件链未走完，SB 手势状态悬空
- 回退 pan/touch 双通道达标即触发，恢复"松手才派发"；保留 -91 强制布局提前+轮询加密+计时埋点、保留 -92 folderId→icon 弱引用缓存（纯读侧优化，无事件副作用）
- 版本 1.2.0-93 / 1002187

## 1.2.0-94（2026-10-24 凌晨）
- folderlog 实锤"当页停留"：跨页打开 4 次 pollsUsed=20 t≈1100ms（curList=102 也是 poll#20 才出现），同页打开 pollsUsed=0 t=2-4ms → 延迟 100% 在等图标视图就绪
- 根因：打开瞬间第一次 scrollToIconListContainingIcon:animate:NO 被吞（松手瞬间 SB 手势/分页状态机未交还控制权），真正生效的是 poll#20（1s）重发翻页
- 修复：翻页重发提前到 poll#2(~0.1s)/poll#6(~0.3s)（幂等），poll#20 兜底保留，curList 每个重发点记录；预期 1.1s → ~0.3s
- 版本 1.2.0-94 / 1002188
- 关键修复：信号/atexit 探针裸 open("/var/mobile/...") 在 roothide SB 内未被路径翻译（实际落 /rootfs/private/...），SIGSEGV(-11) 现场被静默丢弃 → 双路径重试（rootfs 优先）

## 1.2.0-95（2026-10-24 凌晨）
- -94 实测：跨页打开提速成功（pollsUsed=2 t=104-124ms，原 1100ms）✅；但点空白关闭注销仍在，且双路径探针仍零痕迹
- 注销主修：folderlog 实锤 launch 传的 loc 恒为常量串 SBIconLocationRoot（__NSCFConstantString）——系统按真实格子位置登记"展开图标"，残缺登记 → 关闭缩回动画崩溃（-80 埋的伏笔）
- 修复：iconView 就绪后问视图要真实 location（SBIconView.location/_location/iconLocation），只接受非 NSString 对象（Root 常量自然排除），拿到替换 launch 的 loc；realLoc 写日志
- 版本 1.2.0-95 / 1002189

## 1.2.0-96（2026-10-24 凌晨）
- -95 实测：手动开/关不注销了（realLoc 修复起效？实为未生效——realLoc=nil 每次都落空）；手势跨页打开第 2-4 次注销
- 真凶推理：launchFromLocation:context: 恒传 nil context——系统手点的 context 是真实 SBIconInteractionContext（来源图标视图/起始位置，关闭缩回靠它找家），nil context+Root 常量 loc 残缺状态累积后崩溃
- 主修：打开 API 主路径对调——manager 级 openFolderIcon:location:animated:withCompletion:（-69 实锤真入口，自管展开登记+上下文）为主，launchFromLocation 降兜底；当年弃用只因视图未就绪静默失败，pollsUsed=2 就绪轮询已解决
- realLoc 探测扩面：iconObj.location + manager bestHomeScreenLocationForIcon:（-95 实锤视图三选择器全落空）
- 版本 1.2.0-96 / 1002190

## 1.2.0-97（2026-10-24 凌晨）
- -96 实测：仍注销（5 次必 1 次）。folderlog 实锤：open via openFolderIcon 每次都走（新路径生效），但 realLoc 六探测点全灭（视图三选择器/iconObj.location/bestHomeScreenLocationForIcon 全 nil），loc 始终 Root 常量串 → openFolderIcon 传残缺 loc 照样残缺登记，换汤不换药
- 崩溃轮实锤：最后一轮 open via openFolderIcon t=2ms（pollsUsed=0 极速路径）后无 verify 行，日志戛然而止 → 崩在 open 后/关闭缩回中
- 主修：listscan 必中探测——manager.iconModel→rootFolder（manager.iconModel / model.rootFolder / manager.rootFolder 三路兜底）→ 遍历 iconLists，按 containsObject / identifier 双匹配找包含本文件夹图标的 list，取 list.location（系统手点时用的真实串）替换 loc；listscan 结果（lists 数/target id/hit）写 folderlog
- 防御：realLoc 若恰为 SBIconLocationRoot 常量串则丢弃（保持 fallback），杜绝再次传入
- 版本 1.2.0-97 / 1002195

## 1.2.1-1（2026-10-24 中午）—— 1.2.1 系列起点：控制中心专项优化至丝滑
- 竞品分析：ControlCenter18 3.0-beta 解包——整体自绘重写（~90 个 C18* 类、自研网格/分页/编辑/模糊、CADisplayLink+弹簧动画器），我们深 hook 原生 CC 与布局引擎对抗是卡顿根源
- 用户痛点优先级：编辑状态卡 → 本版先做"编辑模式降负"（纯性能减法，不改观感）
- 五项优化：
  ① configureEditingBorder：frame+radius 不变直接 return（旧实现每帧每模块 new UIBezierPath+new CAShapeLayer 设 mask，10-20 模块×60fps=每秒数百次分配）；CAShapeLayer 挂关联对象复用只更新 path；layer.mask 只在变化时赋值
  ② ERCollectModuleControllers：BFS 结果按 overlay 缓存 + 代际失效（gERModuleListGeneration），7 个模块集合变化点（setEditing/dismissEditing/resettle 三连/Move/Insert/Remove/AddSheet）调 ERInvalidateModuleListCache
  ③ updateEditControlFramesForOverlay 帧级快速跳过：模块 frame + chrome 状态位（抑制/边框开关/删除钮开关/当前页）都没变 → 整段跳过
  ④ ERModuleIdentifier 挂关联对象代际缓存（旧实现每次 2-4 层 KVC）；addControl 的 sizeToFit+落位只在 bounds/安全区变化时重算
  ⑤ 每帧 frame/hidden/alpha 写入包 CATransaction setDisableActions:YES，消除隐式动画调度
- 版本 1.2.1-1 / 1002101

## 1.2.1-2（2026-10-24 午后）—— 手势注销真凶实锤修复（重大）
- 用户翻出崩溃日志 SpringBoard-2026-10-24-124602.ips：EXC_BAD_ACCESS SIGSEGV KERN_PROTECTION_FAILURE（栈区）= 栈溢出；主线程 511 帧中 ~490 帧为 EchoReborn.dylib 同一偏移自递归 + -[NSString stringByAppendingFormat:]
- Mach-O 符号化（UUID d2ae01dc 切片匹配）+ 反汇编定位：递归点 = ERSPGSCOLookupOrig 的 class#selector 键拼接（stringByAppendingFormat）+ ellekit 转发蹦床（d0/d1 双浮点参数 = impactOccurredWithIntensity: 签名）
- 根因：1.2.0-32 广谱震动拦截遍历所有类名含 Feedback/Haptic 的类挂钩 4 方法——对子类 S 调 class_getInstanceMethod 拿到的是已挂钩父类的 IMP（即我们自己的 hook），仍存入 gERSPGSCOOrig["S#sel"] → 运行时 hook→LookupOrig 查到自身→调自己→490 层递归→栈爆
- 完美解释：①只有手势开才崩（手势震动走 sERSPGOwnHaptic 放行路径进 LookupOrig；手动开关被 ERSPGShouldDropSysHaptic 拦掉不进）②第 2-4 次才崩（取决于哪个私有子类 generator 先走带强度的 impactOccurredWithIntensity:）③探针零痕迹（不是 SB 逻辑死，是我们把栈打爆，死亡过快）
- 修复三层防御：①ERSPGSCOImpIsOwn() + LookupOrig 查到自身 IMP 跳过继续向父类找 ②AttachSCOHook 存储前 orig==自身则不存不挂 ③广谱扫描同款防御
- 版本 1.2.1-2 / 1002102

## 1.2.1-3（2026-10-24 下午）—— 五 bug 修复①：权限胶囊出现时顶部按钮下移
- 用户确认 5 个历史遗留 bug 方案后动工，本版处理问题 1
- 根因修正：+号（181001）/电源（181002）按钮就在 QA host（181000）内部，会跟随 host transform —— 理论上 1.0.9-19 的补偿应生效；用户实测仍下移 = suppressed 判据漏判（胶囊在场不总是把 host 压低 >8pt：压低量变小 / 压的是 header pocket 其他内容）
- 修复三件套（ERStartQuickAccessPositionCorrection）：
  ① suppressed 阈值 8→4pt
  ② 新增权限胶囊直接探测 ERPrivacyCapsuleVisible：窗口树 DFS 找类名含 PrivacyIndicator 的可见视图（限频 0.5s 缓存），可见即视为在场，不再单靠"被压低"间接判据
  ③ 补偿量升级：优先用实测压低量 drift=layoutWinY-baseline（开环单次读取，layoutWinY 已剥离自身 ty，无反馈回路不发散；夹取 [0,44]）；drift≤2pt 时退回旧常量 23.5 兜底
- QABTN-COMP 日志增加 capsule/drift 字段，装机后可凭日志复核
- 版本 1.2.1-3 / 1002103

## 1.2.1-4（2026-10-24 下午）—— 翻页点消失回归修复 + 横屏 slider 钳制 + 日志落盘根治
- 用户实测反馈：①1.2.1-3 胶囊补偿仍不生效（+号/电源仍下移）②右侧竖排翻页点消失（回归）
- 翻页点根因：1.2.1-1 的 ERCollectModuleControllers 缓存失效点只覆盖编辑路径 7 个变化点，
  CC 重开/provider 重建等非编辑路径改了模块集合却没失效 → normalizePagedLayoutForOverlay
  拿到陈旧缩水列表 → highestPage 缩水 → gERPageCount=1 → updatePageIndicatorsForOverlay
  的 host.hidden（gERPageCount<=1）把翻页点整体隐藏
- 修复三层：①缓存命中时活性校验（任一 controller.view.superview 为空即丢弃重收）
  ②normalizePagedLayoutForOverlay 入口强制失效（低频路径必须新鲜）③缩水防御重试一次
- 问题 2 保守钳制：横屏态无自定义尺寸的 slider 类模块（audio/displaymodule）高度钳 2 行，
  两处 hook 同步钳制（moduleLayoutSizeForContentModuleContext: + layoutView:layoutRectForSubview:）；
  用户自定义过尺寸的完全尊重。等日志实锤后再精修
- 日志落盘根治：实测 SpringBoard 写 /var/mobile/Library/Logs/EchoReborn 一直失败
  （目录需 root 预建）→ echoreborn.log 从未落盘过。写失败自动切 /var/mobile/Documents/echoreborn.log
  备用路径（Documents 已验证可写）；ERLogPath 智能选择存在的文件
- 1.2.1-3 复盘：代码确认已上设备（QABTN-COMP/capsule=%d 以 UTF-16 存在 dylib，之前
  ASCII 搜索误判为旧包）。补偿仍不生效待日志（capsule=/drift= 字段）实锤后精修
- 版本 1.2.1-4 / 1002104

## 1.2.1-5（2026-10-24 傍晚）—— 偏好用户域断链兜底（重大，解释「设置了不生效」悬案）
- 1.2.1-4 实测：翻页点回来 ✔；日志两条路径仍无文件 → 收敛出根因：
  **SpringBoard 以 root 运行，CFPreferencesGetAppBooleanValue 按 root 用户域找
  /var/root/Library/Preferences/…（不存在）→ valid=false → 直接走代码 fallback**。
  设置面板（mobile）写的 /var/mobile/Library/Preferences/… 从没被 tweak 读到过！
- 自洽验证：所有「默认 YES」开关碰巧正常（fallback 掩盖断链）；所有「默认 NO」开关
  （LoggingEnabled）从未生效。历史上一批「设置了不生效」疑案同源
- 修复：ERPreferenceBool/String/Double 三入口加文件兜底——CFPreferences 读不到时
  解析 /var/mobile/Library/Preferences/com.strive.echoreborn.preferences.plist
  （ERLoadPrefs 时解析一次缓存 gERPrefsFileFallback，绕过 cfprefsd）
- 效果：LoggingEnabled 即刻生效 → echoreborn.log（Documents 备用路径）开始落盘
  → QABTN-COMP 的 capsule=/drift= 实测数据到手 → 胶囊下移问题精修
- 版本 1.2.1-5 / 1002105

## 1.2.1-6（2026-10-24 傍晚）—— 日志落盘决定性诊断
- 1.2.1-5 装机后日志仍未出现（root 域手动写 LoggingEnabled=True + killall cfprefsd + respring 也不行）
- 推论已无法远程验证（设备无 ps/lsof，SSH 间歇超时）→ 改为让 tweak 自曝：
  ERLoadPrefs 尾部无条件写 /var/mobile/Documents/er_diag.txt（folderlog 同款已验证可写通道），
  内容：CF 读值/文件兜底读值/flag 终值/两路径 W_OK/三位置实写探针结果
- 一版拿到全部答案，er_diag.txt 出现即读
- 版本 1.2.1-6 / 1002106

## 1.2.1-7（1002107）· 诊断通道改版：cfprefsd 通道
- **1.2.1-6 实测结论（重大）**：装机后用户确认 CC 功能全部正常 → ctor 在跑、ERLoadPrefs 在跑，但 er_diag.txt 依然不出现 → **SpringBoard 沙盒拦截一切 writeToFile/fopen**（Documents、Accessibility、三个探针全静默失败）。同时解开了"BOOT 日志零输出"悬案：/var/mobile/Library/Accessibility 目录不存在 + fopen 被拦，ERBootLog 从未成功过。
- **通道佐证**：tweak 的 ModuleGridOrigins 经 CFPreferencesSetAppValue 写 root 域偏好且跨 respring 持久化（用户自定义布局一直有效）→ cfprefsd 写盘通道必然通。
- 修复：诊断全文写入 CFPreferences 键 `ERDiagText`（root 域 plist，SSH root 可读）；另补写 /var/root/er_diag.txt、/var/tmp/er_diag.txt、/var/root/Library/Preferences/er_diag.txt 三路径兜底。
- ERBootLog 补 createDirectoryAtPath（Accessibility 目录历史上不存在）。
- 新增用户反馈（待修）：编辑模式下 32 个圆钮有些对不齐。

## 1.2.1-8（1002108）· cfprefsd 日志镜像
- 1.2.1-7 诊断全文到手（经 ERDiagText 偏好键，实锤 cfprefsd 通道可用）：
  - CF LoggingEnabled valid=1 value=1 → **不存在用户域断链**，SpringBoard 即 mobile 用户，-5 的断链理论推翻（兜底无害，fileFallback keys=0 因 SpringBoard 沙盒读不了该 1.6MB 文件）
  - gERLoggingEnabled=1、两目录 W_OK=1、两探针 fileExistsAtPath=YES
  - **但全盘 find 无探针文件** → SpringBoard 文件写入"进程内成功但不落盘"（roothide 虚拟化），文件日志通道永久不可靠
- 修复：ERLogAppendLines 顶部镜像日志尾部（60 行/12KB 环形）到 CFPreferences 键 ERLogMirror，SSH 读 mobile 域 plist 即得运行日志（含 QABTN-COMP）
- 后续：读 ERLogMirror → 精修胶囊下移

## 1.2.1-9（1002109）· QABTN 专用镜像 + 基线胶囊门控
- 1.2.1-8 实测：日志镜像通道工作正常，抓到 QACORR 心跳（host=1 hostWinY=69.2 baseline=69.2 ty=-9.0）——补偿状态机在跑（drift=9 被精确抵消），但 COMP 状态切换行被 DI-TREE（一次 38 行）冲出 60 行窗口
- 修复①：QABTN 专用偏好镜像键 ERQAMirror（12 行环形，COMP 切换/心跳/BASELINE 事件全走它），SSH 读 mobile 域 plist 即得，永不被冲掉
- 修复②（胶囊下移候选根因）：基线采集加胶囊门控——tweak 启动瞬间若胶囊在场，首帧 layoutWinY 已是压低态，min-ever 启发式会把压低值钉成基线 → 永远欠补偿（用户看到的"胶囊出现就下移"）。现在胶囊在场时推迟立基线，BASELINE-SET/DEFER 事件也进镜像

## 1.2.1-10（1002110）· 几何跟随（对标 CC18，胶囊下移终极方案）
- **1.2.1-9 复现实锤**：用户复现全程 capsule=0 → 类名含 PrivacyIndicator 的探测在 iOS 17 从未命中，直接判据形同虚设；且回看日志 SBSystemApertureContainerView 宽度在 166（灵动岛）/125.3（胶囊态）间切换
- **CC18 逆向结论**：它的按钮全是原生 CC 模块体系成员（CCUIRoundButton/CCUIButtonModuleView），住在不被胶囊推挤的模块网格里，所以"永远不动"
- **方案废掉基线/drift/胶囊探测整套状态机，改为几何跟随**：锚 = CCUIContentModuleContainerView（日志实测胶囊在场时 Y 恒定），host 目标 Y = 锚窗口 Y + 固定偏移（首次见面用剥离 ty 的布局 Y 标定一次，之后冻结）；差值仍用 transform.ty 承载；锚不可见时冻结不猜
- 心跳改记 anchorY/offset；OFFSET-SET / FOLLOW 事件进 ERQAMirror
- 用户已确认方案（成功率评估 85-90%，失败模式温和：锚丢失=按钮静止）

## 1.2.1-11（1002111）· 绝对钉死（1.2.1-10 跟随方案的实证修正）
- **1.2.1-10 复现实锤**：胶囊出现时 CC 面板整体下移——锚容器 +25.8pt（410.4→436.2），host 被跟着带到 winY 69.2→86.0（+16.8）。跟随任何原生视图都会被带着走，"永不动"的唯一几何解释 = **窗口绝对坐标恒定**
- 方案：目标 = 每方向冻结常量窗口 Y（REF，首次见面标定；胶囊紧凑态在场时推迟标定），ty = REF − layout 反向抵消，夹取 [-60,60]
- 新胶囊几何探针 ERCapsuleCompactPresent：SBSystemApertureContainerView 宽度 ∈ (100,160) = 紧凑态（实证：166↔125.3 切换），类名探测 iOS 17 失效后的可靠替代
- 心跳改记 ref/compact；REF-SET/REF-DEFER/PIN 事件进 ERQAMirror

## 1.2.1-12（1002112）· REF 标定稳定性门
- **1.2.1-11 实测失控**：REF 在 CC 开场动画途中被标成瞬态值（layout=95），layout 落到真实值后 ty 一路加到 60 上限，按钮被推下 60pt——100ms 定时器采到了动画中间帧
- 修复：标定要求连续 3 帧布局几乎相同（300ms 静止）才允许；胶囊紧凑态在场照旧推迟

## 1.2.1-13（1002113）· 双 REF 破死锁
- **1.2.1-12 复现实锤（死锁）**：ERQAMirror 12 条全是 REF-DEFER layout=95.0——用户打开 CC 时绿点（权限胶囊紧凑态）常在场（相机/麦克风使用中），标定门永远拒绝标定 → REF 从未生成 → ty=0 无任何补偿 → 按钮停在压低态。且 layout=95 连续通过 3 帧稳定门，证明 95 就是绿点在场时的稳定布局值（无绿点约 69，差 ≈26pt）
- 方案：**双 REF**——绿点在场/不在场是两个稳定布局态，各自冻结一个 REF（竖/横 × 有/无绿点共 4 键，associated object）；当前状态用哪个 REF 就钉哪个。1.2.1-12 的"胶囊在场拒绝标定"取消，两种状态都允许标定（仍受 3 帧稳定门约束）
- 事件：NORMAL-REF-SET / CAPSULE-REF-SET / PIN 进 ERQAMirror；心跳 ref 字段同样按绿点状态选

## 1.2.1-14（1002114）· 单 REF 重标定 + 1s 稳定门（-13 实锤失败后的回退）
- **1.2.1-13 复现实锤（双 REF 全错）**：镜像实录 `compact=1` 常驻、`ref=111.0 ty=60.0`——
  ① CC 打开时灵动岛自动收紧成 125.33 紧凑态让位，compact 探针恒真，与绿点无关，双 REF 选错分支；
  ② REF=111.0 是 CC 动画中途瞬态，骗过 300ms 稳定门；真实稳态 layout=26，desiredTy=85 撞 60 上限，
  等于补偿逻辑自己把按钮推下 60pt，比不补偿更糟；③ 用户确认无绿点时按钮也下移，压低源识别整体失败
- 方案：① 放弃 compact 分支与双 REF，回退每方向单 REF；② CC 关闭即清 REF，下次打开重标定
  （清除放在离屏判断之前，否则永远带上次的 REF）；③ 稳定门 3 帧→10 帧（≈1s），排除动画暂停瞬态；
  ④ 新增灵动岛容器原始宽度探针 ERApertureContainerWidth + STATE 宽度跳变事件，用真实几何对齐
  「胶囊出现」与 layout 位移；心跳补记 layout/apertureW/host 类名；ERQAMirror 环 12→24 行

## 1.2.1-15（1002115）· 重构起步：回退 1.2.1-2 基底 + 三项修复移植
- **重构决策（用户批准）**：-3~-14 权限胶囊线六版全败，根因 = 操作按钮 host 挂在
  CCUIHeaderPocketView（CC 顶部 chrome 容器），权限胶囊出现时 chrome 让位下移按钮被带走；
  检测-补偿路线三重失败（类名探测 iOS 17 失效 / 灵动岛宽度探针恒真 / REF 被动画瞬态污染），
  且补偿反噬（-13 ty 撞 60 上限反推下 60pt）。用户拍板：回退稳定版打底，操作按钮后续重构
  re-parent 进原生模块网格容器（对标 CC18 成员身份，随系统布局）
- 本版 = git aaacbb675a（1.2.1-2）为基底，只移植三项已验证修复，胶囊补偿链全部不带入：
  ① 横屏音量/亮度 1×3 钳制（-4，slider 类模块横屏高度钳 2 行，尊重自定义尺寸）
  ② 翻页点消失回归修复（-4，模块列表缓存活性校验 + normalize 入口强制失效双重防御）
  ③ ERBootLog 目录创建（-7）
- 下一步（1.2.1-16 规划）：installQuickAccessHostOnOverlay: 挂载点从 CCUIHeaderPocketView
  改到原生模块网格容器，删除旧开环补偿全链

## 1.2.1-16（1002116）· 基线再纠正：还原 1.2.0-97 + 保留手势修复
- **用户实锤**：控制中心一系列 bug 的源头是 1.2.1-1 的「编辑模式降负」五项优化（BFS 缓存/代际失效/帧级跳过/mask 复用/CATransaction），要全部还原；1.2.1-2 的手势崩溃修复要保留
- 本版 = git aaf0d9766a（1.2.0-97）为基底（-1 优化零残留，已 grep 验证），移植三件事：
  ① 1.2.1-2 手势自毒免疫三修法（ERSPGSCOImpIsOwn + LookupOrig 跳过自身 IMP + AttachSCOHook/广谱扫描不存不挂）——防 490 层递归栈爆
  ② 横屏音量/亮度 1×3 钳制（自 -4，slider 类模块横屏高度钳 2 行）
  ③ ERBootLog 建目录（自 -7）
- 不带入：-1 全部优化、-3~-15 胶囊补偿线、翻页点缓存活性校验（依赖 -1 缓存基础设施，随优化一起还原后自然 moot）
- 待办：操作按钮重构（host 离开 CCUIHeaderPocketView 顶部 chrome，进原生模块网格）在稳定基线验证后另版进行

## 1.2.1-17（1002117）· 控制中心 4 项 CC bug 修复（方案先行，用户审核「开始吧」）
- **bug 4（翻页点点击放大 + 0.5s 延迟才跳页，代码级实锤）**：根因 = `pageIndicatorTouchDown:` 按下即 `beginInteractivePageTransitionForOverlay:` → heldScale 0.26s 入场缩放 + indicator 切 scrub 大间距（"放大"）→ 松手 finishInteractive 再 0.30s settle，合计 ~0.5s。修复：touch-down 删除 beginInteractive/updateInteractive 两调用，只留 haptic + 夹紧重assert；纯点击走 `pageIndicatorTapped:` 的 `setCurrentPage:animated:YES`（0.22s 即翻，对齐 CC18 原生 UIPageControl「按下即翻」）；真拖拽仍由 pageIndicatorPanned: Began 进 scrub，交互不变
- **bug 2（末页还能上翻 2 排且可悬停，应过半圆弹回）双路径修复**：① `gestureRecognizerShouldBegin:` 末页上拂一律拒绝 pager 改判据 —— 仅 velocity.y < -400（快速上拂）放行原生收起 CC，慢拖收回 pager 所有权；② `pagePanned:` 边界阻尼从线性 0.24 改为渐近橡皮筋 `span*0.5*(1-1/(1+over/span))`（渐近上限 = 半个圆 = span×0.5，与用户"超过半圆弹回"的要求一致），按实时页位逐帧钳制（旧码只按 startPage 判边界）；③ 手势 Began 无条件全树 `ERClampNativeScrollViewForOverlay`（旧码要求 nativeScrollView && nativeBaseline 双满足）；④ 两个 Ended 分支 delta==0 且 |translation|>0.5 时 settleCurve 换 spring（0.34,1.42,0.64,1.0）回弹
- **bug 3（每页滑动落位弹跳：向上一下再落下）三修 + 一看门狗**：① `animatePageSettleForOverlay:` 起点与屏幕对齐 —— 呈现层与模型 |Δm42|>1pt 时先 removeAllAnimations + setDisableActions 把模型对齐到呈现值再补间（治「以模型作起点 = 第一帧跳位」）；② swipe Ended 原生 offset 回写从 completion 移入 modelChanges 第一帧（与页面跳转同帧）；③ `setCurrentPage:animated:` 补 token 校验的 0.22s completion 清理 `gERPagerTransitionActive`（旧版置位后无任何清理路径）；④ `updateTopFadeForOverlay:` 加 staleness 看门狗：标志为真但 >1s 无手势推进（|translation|>0.5 或圆点 dragging）即清残留（合法窗口 tap 0.22s/settle ≤0.42s+0.42s snap 均 <1s 不误伤，跟手悬停与圆点长按算推进中）
- **bug 1（竖屏点不收起 CC 的模块 → 红框状态区消失 2-3 秒，静态考古未实锤，诊断+稳健化同修）**：首选嫌疑 = top fade（frame (0,0,宽,max(112,safeArea+76)) 正好盖住 HeaderPocket 状态带）被残留翻页标志以 alpha 1.0 点亮。修复：① bug 3 的第 3/4 条先拆公共温床（已完成）；② `willOpenExpandedModule:`/`didCloseExpandedModule:` 强制熄 fade（presentationAlpha:0.0）+ 清 gERPagerTransitionActive/ScrubbingActive；③ 新增诊断三件套 —— updateTopFadeForOverlay: 逐变日志 `[FADE] target=/active/scrub/transition/tr/expanded` + HeaderPocket 看门狗（CC 呈现时 0.5s 独立采样 fade/pocket/子视图 alpha·hidden，仅签名变化落 `[POCKET]` 日志，代数票根防多链、收起自断）+ 复用 PAGEGEO/PAGESETTLE 探针。装机复现后回传 [FADE]/[POCKET] 日志，若写入点不在这两处，按日志出 -18 定点清除
- 参照系：cc18_dylib.extracted 字符串考古实锤 CC18 = 原生 UIPageControl（即点即翻）/ 真 overlayScrollView 末页占位页 + 回弹 / spring 落位，②③④ 目标行为即「原生 scrollview 分页感」
- 方案文档：PLAN_1.2.1-17.md（根因带行号、改法、风险、批次）。风险项：bug 2 边界手势（装机后专项验证末页慢拖回弹 + 首页下拉阻尼 + 末页底部快速上拂收起 CC 三条既有行为）

## 1.2.1-18（1002118）· cfprefsd 日志镜像通道恢复（bug 1 诊断数据救援）
- **背景实锤链**：1.2.1-7 发现 SpringBoard 文件写入「进程内成功但不落盘」（roothide 虚拟化）→ 1.2.1-8 建立 CFPreferences 镜像键 `ERLogMirror`（60 行/12KB 环）并经 SSH 从 mobile 域 plist 读出验证可用 → 1.2.1-16 回退 1.2.0-97 基底时把镜像通道一并还原掉 → 1.2.1-17 装机后用户复现 bug 1，诊断数据全丢
- **1.2.1-17 复现失败实机复盘（2026-10-25 凌晨）**：
  - 复现后 SSH 实锤：`/var/mobile/Library/Logs/EchoReborn/` 目录在盘（03:05 创建）但 `echoreborn.log` 不存在；plist 里昨日 23:06 的 `ERDiagText` 探针记录显示直接写 `er_probe.txt` 返回 `ok=1`（进程内成功）——该文件同样不在磁盘上。「进程内成功但不落盘」二次实锤；目录创建能落盘、文件内容不落盘
  - 短会话丢失实锤：`ERLogRecord` 每 8 条才刷盘（kERLogFlushInterval=8），复现会话通常 < 8 条，缓冲区只活在 SpringBoard 内存里
  - unified log 通道不可用：设备无 `log` 二进制（/usr/bin/log 不存在，sudo PATH 亦无）；NSLog 回落只在写文件真失败时触发，而本次写入「成功」故无 NSLog
  - CFPreferences 通道可用性实锤：`Diag.ctor` = 2026-10-24 19:19:11 +0000（= 03:19:11 CST，respring 后插件构造时间）经 SSH 从 plist 读出，新鲜有效；plist 跨重启保留昨日镜像键（ERLogMirror 尾 60 行 23:43、ERQAMirror、ERDiagText）
  - 设备时间线：03:01 userspace respring 装机 1.2.1-17 → 03:16 前后用户竖屏点「锁定」模块复现 bug 1 → 03:19:11 再度 userspace respring（kern.boottime 10-23 18:04 内核未动，backboardd/SpringBoard PID 联动变为 32092/32094），复现数据随内存缓冲区丢失。respring 触发方待用户确认（手动 or 自动）
- **本版修复**：恢复双环 cfprefsd 镜像（`ERMirrorRingUpdate` 通用实现，按行入环保持行数语义）：
  - `ERLogMirror`：全部日志尾 60 行（12KB 上限），`ERLogRecord` 逐行镜像（不再等 8 条刷盘），短会话不再丢
  - `ERPocketMirror`：仅 `[FADE]`/`[POCKET]` 尾 16 行（4KB 上限），诊断时序永远在手（1.2.1-9 教训：通用 60 行窗口会被批量日志（一次 38 行）冲出，专用环保证 bug 1 的诊断时序）
  - 已知权衡：plist 域已达 ~2MB（ShortcutCatalog 带 1.6MB 图标 PNG），逐行同步 = 每行一次 cfprefsd 全域重写；实测复现会话行数 20-100 量级可接受，若出现写放大问题下一版合并写
  - 读取方式：SSH 下载 `/var/mobile/Library/Preferences/com.strive.echoreborn.preferences.plist` 后 plistlib 解析（该设备 plutil -p/-extract 对大 plist 报 keypath 错，下载解析最稳）
- 诊断站点接入（1.2.1-17 已建，本版接入镜像）：[FADE] stale 清理 / [FADE] target 逐变 / [POCKET] 看门狗签名变化，版本串 ver=1.2.1-18
- 装机后复现流程：竖屏 → 拉开 CC 不收起 → 点「锁定」等模块 → SSH 拉 plist 的 ERPocketMirror + ERLogMirror → 定位状态带被谁打零

## 1.2.1-19（1002119）· bug 1 写入方追踪（setAlpha: 运行时观测 + 状态上下文）
- **1.2.1-18 装机复现实锤（2026-10-25 03:57-03:58，用户竖屏 CC 不收起点屏幕方向锁定模块）**：
  - 每次点击触发一轮「状态带消失 → 自行恢复」，消失持续 1.56 / 2.09 / 2.60 / 3.16 秒（与用户「消失 2-3 秒」吻合）
  - **掉落物实锤**：`SensorAttrib`/`StatusBar` 两个 pocket 直接子视图 alpha 1→0（hidden 保持 0），**pocket 本体 alpha 保持 1、top fade 全程熄灭（fade=0.00/1）**——fade 假设彻底排除
  - 另观测到 pocket 子视图顺序翻转（StatusBar 被移到最顶 → 我们的 host 被 13246 行 bringSubviewToFront 抢回），与掉落无因果关系
  - 静态逐一排除：setHeaderChromeHiddenForScrubbing（藏 pocket 本体，本体没掉）/ willOpen·didCloseExpandedModule（不写 alpha）/ ERSuppressHeaderPocketMaterial（只藏 MTMaterialView+发丝线）/ 横屏 chrome 全家（只写 transform 且复现为竖屏）/ ERExpandedChromeRevealActive（窗口 0.65s 与变动延迟不符）
- **本版诊断**（不改行为，纯观测）：
  - `ERSwizzleBandAlphaTraceOnce`：看门狗采样命中 `CCUISensorAttribution*`/`CCUIStatusBar` 时对其 swizzle `setAlpha:`（幂等）。安全细节：setAlpha: 大概率继承自 UIView，直接 method_setImplementation 会改到 UIView 本体影响全应用 —— 先 class_addMethod 给子类落自己的实现（已覆盖则取子类 IMP 作原实现），再 class_replaceMethod 换观测块，块内直调原 IMP，行为不变只观测
  - alpha 反转点（1→0 / 0→1）落 `[BAND]` 日志：类名 + 前后 alpha + hidden + **调用栈前 8 帧**（NSThread 栈最新在前，前 8 帧即直接调用链）—— 一次复现指名写入方
  - [POCKET] 签名追加运行时状态上下文 `st=scrub/tr/exp/edit/pres`，掉落瞬间的系统状态直接可读
  - ERPocketMirror 环扩到 24 行 / 6KB（[BAND] 栈行 ~400B/条，16 行装不下一轮完整复现）
  - 版本串 ver=1.2.1-19
- 装机后复现流程不变：竖屏 → CC 不收起 → 点模块 → SSH 拉 ERPocketMirror，读 [BAND] 栈顶帧定位写入方

## 1.2.1-20（1002120）· bug 1 修复：伪隐藏当场顶回（[BAND] 栈帧实锤写入方是 iOS 自己）
- **1.2.1-19 装机实锤（2026-10-25 04:46-04:47）**：[BAND] 运行时栈帧指名写入方 —— **ControlCenterUI（iOS 自己）**，路径为 UIView 动画：淡出动画块里 `setAlpha:0`，完成块里 `setAlpha:1` 恢复（栈帧 7 = `__UIVIEW_IS_EXECUTING_ANIMATION_COMPLETION_BLOCK__`）；hide 时长 1.5-3.2s = 该动画时长。抓到两条触发路径：动画路径（CCUI+84284→142680→151520→151964→UIKit 动画机制→154640→90280）与 dispatch_async 路径（libdispatch→162424→135148→53844→142028）。发生条件：竖屏 CC 不收起、点模块（含切换类的「锁定」）、**无模块展开态**（st=exp0 pres2 scrub0）——伪隐藏
- **本版修复**：`setAlpha:` swizzle 里对伪隐藏当场顶回 —— 合法隐藏场景不抢（模块展开中 / 展开收尾中 / 翻页擦刷 scrub·transition / 编辑态 / CC 收起中 state==3 / CC 已收起），其余（CC 呈现中且无展开无擦刷）一律 `original(setAlpha:, 1.0)` 并 return：iOS 随之设置的淡出动画变成 1→1 空操作，完成块的淡回也无害，状态带不再可见地消失。修复落 `[BANDFIX]` 日志（5s 限一条，带栈）；合法Transition 仍落 `[BAND]`（带 legit 标志）
- 保留观测：swizzle / [BAND] / [POCKET] 状态上下文全部保留，若修复后仍有异常（如 [BANDFIX] 高频 = 隐藏成环）可继续定位
- 装机验证流程：竖屏 → CC 不收起 → 点「锁定」等模块 → 确认状态带不消失 → SSH 拉 ERPocketMirror 看 [BANDFIX] 命中

## 1.2.1-21（1002121）· bug 4 新问题修复（翻页卡死恢复）+ bug 2 悬停同根修复 + 镜像环卫生
- **用户四测反馈（2026-10-25 05:25，1.2.1-20）**：① bug 1 已解决；② bug 2 末页有回弹但滑动手势过长依旧悬停；③ bug 3 落位弹跳依旧；④ bug 4 点击已解决，但**长按拖动翻页点后模块内容整体不可见**（只剩状态栏/翻页点/操作按钮），模块可点击，需 respring 恢复
- **bug 4 新问题根因实锤（1.2.1-20 镜像环现场数据）**：用户 05:27 测试会话里，翻页点 scrub 周期（17.081→19.836→22.248）结束后只有标志位被 staleness 看门狗清掉（22.248 [FADE] flags=0），**`finishInteractivePageTransitionForOverlay:` 的恢复痕迹缺失**——结束事件在长按场景丢失，模块停在 `layer.opacity=0`（14221 行写的属性，**不挡触摸** = 「能点击但看不见」）。同时 [BAND] 显示伪隐藏分类正确（全程 legit=1，零 [BANDFIX]），bug 1 修复确认有效
- **本版修复（三处，bug 2 悬停同根一并修）**：
  1. `pageIndicatorPanned:` **结束态优先于门控**：scrub 进行中但门控此刻不满足（长按误触编辑/拖动、overlay 被换）时，旧代码直接 return 导致收尾永走不完；现在用 Began 时存的 overlay 票根（kERPagerOverlayKey）补走 `finishInteractivePageTransitionForOverlay:`，无论门控
  2. **翻页卡死安全网** `ERRecoverStuckPagerIfNeeded`（挂 pocket 看门狗，2s 节流）：翻页完全空闲时若发现页面位移残留（gERPagerInteractiveTranslation ≠ 0，= bug 2 末页悬停）或当前页模块仍被裁隐藏（= bug 4 不可见），走 finishInteractive 落回视觉页，位移与可见性一并恢复——不再需要 respring。落 `[PAGERRECOVER]` 日志
  3. **镜像环卫生**：DI-GEO/DI-TREE 布局几何转储不再进 ERLogMirror 环（一次 CC 布局几十条把 60 行环冲爆，PAGESETTLE/PAGEGEO/[PAGER] 全被挤出——这正是 bug 3 拿不到落位数据的原因）
- bug 3（落位弹跳）：本版先保证数据通道（PAGESETTLE 行能留在环里），下次复现拿 from/to/dur 序列后定点修
- 装机验证：① 长按拖动翻页点 → 模块应立即恢复可见（[PAGERRECOVER] 命中）；② 末页超长上滑 → 松手应回弹不悬停；③ 普通翻页 3-5 次 → 拉 ERLogMirror 看 PAGESETTLE 行

## 1.2.1-22（1002122）· 卡死恢复重写（不信标志位，信手指+活动时间戳）+ 卡死状态带恢复
- **1.2.1-21 装机复测实锤（用户 06:05 会话）**：bug 1/2 依旧。镜像环显示翻页点 2.8s 拖拽结束后无 finish 收尾痕迹、无 PAGESETTLE；状态带 06:05:23.579 被打零（legit=1，翻页标志位卡着）后**再无恢复行**——状态带永久卡隐藏。1.2.1-21 的安全网没触发：**它要求「标志位已清」才动作，而标志位本身卡死了**（结束事件丢失 → gERPagerTransitionActive 永停 YES；staleness 看门狗被卡住的 kERPageIndicatorDraggingKey 挡着不触发）
- **根因统一**：翻页手势结束路径不可靠（长按/超长拖动场景结束事件丢失）→ 标志位卡死 → 状态带卡隐藏（bug 1 复现）+ 页面卡位移（bug 2 悬停）+ 模块卡 opacity 0（bug 4 不可见），三症同根
- **本版修复**：
  1. **卡死恢复重写判定基准**（ERRecoverStuckPagerIfNeeded）：不再信标志位。`gERPagerActiveGesture` 弱引用 + `numberOfTouches > 0` 判手指是否真在屏幕上（结束事件丢了触摸数也归零，长按不动不误伤）；`gERPagerLastActivityTime` 由全部翻页事件（begin/update/finish/setCurrentPage/两个 pan）刷新，1.5s 无活动即闲置。闲置 +（标志位卡着 / 位移残留 / 当前页模块被裁隐藏）→ finishInteractive 落回视觉页 + 强制清标志位 + 清卡住的 dragging 票根。落 `[PAGERRECOVER]`
  2. **卡死状态带恢复**：看门狗采样发现状态带 alpha 卡 0 且手指已离屏、翻页闲置、无展开/编辑 → 0.2s 淡回 1 并清残留动画（iOS 的「完成块恢复」永不来时的兜底）。落 `[BANDRESTORE]`
  3. **PAGESETTLE 接诊断环**：落位 from/to/dur 同时进 ERPocketMirror（24 行低流量环），保证 bug 3 时序数据不再被通用环挤出
- 装机验证：① 长按拖动翻页点 → 2 秒内自动恢复、不用 respring；② 末页超长上滑松手回弹；③ 竖屏点模块状态带不消失；④ 翻页几次后拉 ERPocketMirror 看 PAGESETTLE/PAGERRECOVER/BANDRESTORE次数

## 1.2.1-23（1002123）· 不变量自愈（不动中间过程，只校终态）+ 高容量追踪 + bug 3 去过冲
- **1.2.1-22 装机复测实锤（用户 06:36 会话 plist，06:43 拉回）**：用户报「所有问题依旧」。三条一手数据同时到手：
  1. 恢复机制**一次都没跑** —— `[PAGERRECOVER]` / `[BANDRESTORE]` / `[BANDFIX]` **零条**（环里只有 PAGESETTLE 与 `[BAND]`）
  2. **窗口太窄（算得出来）**：闲置门 1.5s + tick 0.5s = 最坏 2s 才动手，而实测三次 PAGESETTLE 只隔 0.7s（06:36:53.953 / 54.636 / 55.337），自愈根本轮不到；随后 06:36:56.235 / .575 状态带被打零且再无恢复行
  3. **诊断环被自己的日志吃光**：ERPocketMirror 19 行里 7 条 `[BAND]` 就是 5.6KB（每条 ~800B 调用栈），刚顶到 6KB 上限；ERLogMirror 60 行被 `DI-PILL` 单次窗口扫描占满。两条环都拿不到想看的证据 —— 这才是连着两轮「复现了但猜不出原因」的真正原因
- **思路调整：不再追「哪条结束事件丢了」，改成校一组必须恒真的不变量**。丢事件是系统手势抢占造成的，追不完；只要**最终状态**不对就整盒重建，与中间断了哪条链路无关：
  - A 标志：无手势、无自有动画时 scrub/transition 必须为 NO
  - B 位移：`sublayerTransform.m42` 必须 = `base - page*span`，且 `interactiveTranslation == 0`（**bug 2 悬停**）
  - C 可见性：当前页模块 `layer.opacity` 必须为 1（**bug 4 能点看不见**）
  - D 亮度：`collection.alpha` 必须回到基准值（heldAlphaFactor 卡住时整页灰着）
  - E 状态带：无展开/编辑/拖动时 pocket 子带 alpha 必须为 1（**bug 1 消失**）
- **本版改动**：
  1. **不变量自愈** `-erReconcilePagerForOverlay:forced:`（单一出口，走 `finishInteractivePageTransitionForOverlay:` 这条本来就写好的收敛路径；`forced` 时连标志位与 dragging 票根一起作废，因为它们本身可能就是卡死源头，不能拿来当判据）。看门狗 tick 0.5s→0.25s，闲置门 1.5s→0.45s —— 自愈延迟从最坏 2.0s 降到 **0.7s**。落 `RECON f=/fl=/disp=/vis=/dim=/pg=/tr=/m42=` 短行
  2. **呈现即自检**：`ERStartHeaderPocketWatchdog` 在呈现落定后 0.45s 强制自检一次。上一轮会话丢干净的手势链留下的 opacity=0 / 悬停位移 / 状态带 alpha 0 **跨会话存活**，这条保证下次打开控制中心必定自愈 —— 用户不再需要用注销来恢复
  3. **日志通道重建**：新增 `ERPagerTrace`（160 行 / 16KB，只装翻页生命周期短行）与 `ERBandTrace`（8 行 / 5KB，`[BAND]` 专用）；`[BAND]` 调用栈从 8 帧压到 3 帧并剥掉 UUID/偏移（单条 800B→~260B）；`ERLogMirror` 补过滤 `DI-PILL`
  4. **翻页生命周期全追**：`TD / TAP / IPAN / IPAN-CH / SPAN / SPAN-CH / BEGIN / FIN / SETP / PAGESETTLE / RECON` 全部入 ERPagerTrace 同一时间轴（Changed 是 60Hz，照单全收会重演 DI-PILL 事故，故 Changed 节流 0.30s）
  5. **bug 3（弹跳动画）定点去过冲**：`updateInteractivePageTransitionForOverlay:` 里每次跨页给每个模块播的 pop 动画原为 keyframe `0.90 → 1.025 → 1.0`，那个 **1.025 是故意写进去的过冲**，正是用户说的「弹一下」；改为单调 `0.92 → 1.0` 纯淡入（grid 侧同改）。另 `finishInteractive` 的 settle 曲线 EaseInEaseOut → **EaseOut**（in 段的「先慢半拍再冲」配上 0.30s 就是最初 bug 3 描述的「停滞一下再落下」）
- 装机验证：① 长按拖动翻页点后松手 → 0.7s 内模块自己回来（**不用注销**）；② 末页超长上滑松手即回弹不悬停；③ 翻页跨页时不再有「弹一下」；④ 任意问题复现后立刻 SSH 拉 plist，看 `ERPagerTrace` 的 RECON 行与 `ERBandTrace` 的 `[BAND]` 行

## 1.2.1-24（1002124）· bug 3 真凶实锤删除 + bug 2 橡皮筋收紧 + 收起期不打架
- **1.2.1-23 用户四测结果（2026-10-25 14:34）**：① 状态带消失 **已解决**；② 长滑依旧悬停；③ 依旧弹跳；④ 长按翻页点后控制中心整体消失
- **bug 3 真凶（代码级实锤，非推测）**：`pagePanned:` 两个收尾分支里，`delta == 0`（没跨页——末页回弹、小幅滑动全算）时 settle 曲线被换成 **cubic-bezier(0.34, 1.42, 0.64, 1.0)**。第二控制点 y=1.42 = 动画值**冲过终点再回来**，这就是用户连续四轮看到的「弹跳动画」。1.2.1-23 删掉的 pop keyframe 1.025 过冲不是真凶。修复：两处一律改 **EaseOut**（起步即走、末段自然减速、绝不过冲），曲线选择逻辑整体删除
- **bug 2「悬停」定性 + 收紧**：`ERPagerTrace` 实测一次长拖把页面悬出 202pt+（渐近上限 0.5*span=484pt，长拖可悬出 300pt+ 小半屏），手指按住期间一直停在那里 = 用户说的「悬停」。修复：越界行程（over）超过 **0.35*span** 后不再继续拉伸，视觉位移上限收敛到 **≈125pt**（0.5*span*(1-1/1.35)）；短拖行程与原来完全一致。保留弹性回拉手感，页面永远不再悬出小半屏
- **④ 的实锤新问题：恢复逻辑在收起动画期间和系统打架**：14:34:15.341 iOS 开始收起 CC（状态带淡出），15.595 我们的 `[BANDRESTORE]` 把状态带强行点亮，0.09s 后 iOS 又打回去 —— BANDRESTORE 门缺「呈现态必须是 2」判据。修复：`gERControlCenterPresentationState == 2` 才允许恢复，收起中（3）/已收起（0）一律放行系统
- **④ 防线（收起即清场）**：`didChangePresentationState` 在 state 3/0 时立刻清空翻页交互残留（scrub/transition 标志、跟手位移、dragging 票根、手势弱引用），落 `DISM-CLEAN` 追踪行。防止长按拖拽中途 CC 被收起时，脏状态跨收起存活到下一轮呈现（呈现后强制自检仍是第二道）
- 追踪数据侧写：本轮 `[BANDRESTORE]` 两次命中（14:33:50.167 / 14:34:15.595），bug 1 的自愈链路确认在干活；`RECON` 零命中 = 本轮没有发生真正的卡死（悬停是设计内的跟随位移，不是状态卡死）
- 装机验证：① 翻页跨页/末页回弹不再有「弹一下」；② 末页/首页长滑，页面最多悬出 ~125pt，松手 0.24-0.42s 平滑归位；③ 长按翻页点拖拽后 CC 收起再打开，内容完整可见

## 1.2.1-25（1002125）· 分页引擎对齐 CC18（C18PageScrollView 架构迁移）
- **架构裁决（用户）**：不再打补丁，对齐 CC18 底层实现。参考材料 = 用户提供的 `cc18_blob.bin`（/Library/ControlCenter18 payload，二进制解析出主 dylib ControlCenter18.dylib 2.26MB 并提取）。ObjC 元数据实锤 CC18 三件套：**C18PageScrollView（UIScrollView 子类）+ C18PageView + C18PageControl**，落位走 `scrollViewWillEndDragging:withVelocity:targetContentOffset:` + `animateWithSpringDuration:bounce:`，收起仲裁走 `_dismissalPanGestureRecognizerShouldBegin:` / `_scrollViewCanAcceptDownwardsPan` 状态门控。dayanch96/CC18 仓库只有圆角 hook，与分页无关（已排除）。
- **本版迁移内容**：
  1. **新增 `ERPagerScrollView`**（UIScrollView 子类，tag kERPagerEngineTag，插在 collection 之上）：引擎铺满 overlay。触摸路由 hitTest —— 命中控件/原生滚动/带手势视图一律放行（模块交互优先，对齐 iOS18「翻页手势只属于背景与圆点」），纯背景归引擎；安全方向的失败（放行出错最坏只是这里翻不了页，不伤模块交互）。
  2. **物理全部原生**：rubber band（bounces + alwaysBounceVertical）、减速、`targetContentOffset` 落位（round(预测位) + 速度偏置，对齐 CC18 _targetPage）。**bug 2 悬停 / bug 3 弹跳在架构上消失** —— 不存在自造橡皮筋曲线与自造 settle 动画了。
  3. **渲染镜像**：`scrollViewDidScroll` 把 offset 镜像进现有渲染链：`gERCurrentPage = round(offset/span)`、`translation = page*span - offset` ⇒ 视觉位置恒等于 `-offset.y`（页号翻转时 translation 跳变但视觉连续）；镜像写入包 CATransaction disableActions（避免 0.25s 隐式补间导致跟手发糊）。
  4. **收起仲裁（bug 4 根治）**：引擎拖拽 / 圆点 scrub 期间**窗口级压制**全部非我方 pan（此前只压 overlay 子树，CCUI 收起 pan 在子树外漏压 —— 长按圆点被系统收走就是这个洞）；松手/收尾立即恢复。另保留「末页快速上拂让位」：引擎 pan 在末页且 vy<-400 时 decline，同一触摸走祖先上的收起 pan（1.2.1-17 既有行为 + CC18 仲裁语义）。
  5. **圆点 scrub 重写**（CC18 `_preciseTouchedPage` 语义）：触点 → ERPageProgressForScrubY → 引擎 offset 直接驱动；**heldScale 0.70 收缩 / jello / 粘滞滞后全部退役**（用户报的「放大」「弹跳」来源）；跨页 haptic + indicators 保留。
  6. **点圆点跳页**：`ERPagerEngineJumpToPage` —— 视觉连续地把 offset 动画到目标页（`setContentOffset:animated:` 原生曲线，自造 0.22s CABasicAnimation 退役）。
  7. **pop 动画整块删除**（updateInteractivePageTransition 的 changedPage 分支）——「弹跳」最后残留源。
  8. **状态一致性**：`updatePageIndicatorsForOverlay` 开头 = 引擎对账汇聚点（所有翻页收尾都经过）；看门狗每 tick 对账；DISM-CLEAN 增加引擎 offset 同步；scrub/拖拽/动画期间对账不回写（守卫防视觉打架）。
  9. 旧 `pagePanned` 休眠：引擎在位时 Began 即转投（SPAN-ENGBAIL），保留作模块表面 require-to-fail 链的兜底；其完成路径经 updatePageIndicators 汇聚点自动对账。
  10. 追踪行新增：`ENG-INSTALL / ENG-BEG / ENG-END / ENG-JUMP / ENG-YIELD-DISMISS / SPAN-ENGBAIL / SCRUB-BEG / SCRUB-END`。
- **明确不做（如实说明）**：模块内容不迁入滚动视图（CCUI 原生层级不能动，重写宿主层是另一个量级）；引擎是「物理引擎」而非「容器」——CC18 的内容随 offset 走，这里由镜像链等价实现。
- 装机验证：① 背景滑动翻页 → 原生手感（rubber band 回弹、无弹跳、无悬停）；② 末页快速上拂 → CC 收起；③ 长按圆点拖拽 → 不再被收起，松手原生动画落位；④ 点圆点 → 原生动画跳页；⑤ 模块点按/滑条/长按编辑不受影响。

## 1.2.1-26（1002126）· 撞号崩溃热修 + 崩溃自报告
- **用户崩溃日志实锤（SpringBoard-2026-10-25-162801.ips）**：下拉 CC 即 SIGABRT，`NSInvalidArgumentException` —— `-[UIButton <sel>]: unrecognized selector`，调用链 = CADisplayLink → 我方 6 帧 → forwarding。consecutiveCrashCount=4，CC 完全不可用。
- **根因（代码级实锤，1 分钟定位后复盘）**：1.2.1-25 新增的 `kERPagerEngineTag = 181033` **与既有常量 `kERConnectivityExpandButtonTag = 181033`（连接模块展开按钮，UIButton）撞号**。`viewWithTag:` 递归全树查找，引擎对账（updatePageIndicators 汇聚点 / duplicate host 布局链）先命中展开按钮 → 强转 ERPagerScrollView → 调 `erSyncContent` → 崩。receiver=UIButton、下拉 CC 必崩（连接模块必然布局）、display link 链全吻合。
- **修复**：① 引擎 tag 挪到未占用段 **181090**；② `ERPagerScrollViewForOverlay` 加 `isKindOfClass:[ERPagerScrollView class]` 类型防御 —— 撞号的最坏后果降级为「引擎缺失」，绝不崩 SpringBoard。
- **崩溃自报告（永久升级）**：`NSSetUncaughtExceptionHandler` → 未捕获异常的名字/原因/EchoReborn 栈帧写入 cfprefsd 镜像新键 `ERCrashMirror`（20 行/8KB，handler 在 abort 前跑、通道已被 1.2.1-18 验证）。以后崩溃不再依赖 .ips 猜选择子，SSH 拉 plist 即得。
- 验证：下拉 CC 不再崩溃；SSH 拉 plist 应见 `ENG-INSTALL`（引擎正常安装）与 `ERCrashMirror` 为空。

## 1.2.1-27（1002127）· 双引擎互踩根除（shouldBegin 闸口）+ scrub 动态恢复
- **1.2.1-26 用户四项反馈（2026-10-25 17:30 会话追踪环）**：① 悬停依旧；② 弹跳依旧；③ CC 消失有变化——但**长按翻页点的动态效果被误删**（用户明确：只该修 CC 消失，不该动 scrub 手感）；④ 新问题：第二页滑不过第三页。
- **追踪环实锤（根因）**：`SPAN-ENGBAIL` 后 `SPAN-CH`/`PAGESETTLE` 仍然成串出现 —— 1.2.1-25 的「引擎接管」只在 pagePanned 的 Began 分支 return，但**手势已经识别，Changed/Ended 事件继续涌进旧物理**，新旧两套引擎交替拖动同一页面：旧橡皮筋/旧 settle 的悬停弹跳全部回归（①②），混合写入的位移残留导致第二页到第三页的落位错乱（④），强制自愈还要收拾残局（17:30:58 RECON f=1 disp=1 拉回 57pt）。
- **修复 1（双引擎根除）**：引擎接管从「Began 后逃逸」改为 **`gestureRecognizerShouldBegin:` 直接拒绝**（协调器手势代理，pager 分支加 `ERPagerEngineAvailable` 门）——手势整体不启动，触摸完全归引擎 pan；pagePanned 仅作引擎不可用时的兜底路径。1.2.1-25 的 Began-bail 块删除。
- **修复 2（scrub 动态恢复，用户裁决）**：长按圆点 scrub 恢复 1.2.1-24 的原链路（beginInteractive → updateInteractive → finishInteractive，heldScale 收缩/粘滞/jello 全部回归）；**bug 4 的修复只保留「窗口级压制」**（拖拽期间收起 pan 被压住、松手恢复）这一件事。引擎 offset 由 finish 的 completion → updatePageIndicators → 引擎对账归位，不参与 scrub 驱动。TAP during scrub 同步回到 update+finish 链。
- 保留：引擎背景翻页（原生物理）、ENG-JUMP 点按跳页、ENG-YIELD-DISMISS 末页上拂让位、崩溃自报告（ERCrashMirror）。
- 验证：① 背景滑动 = 原生引擎物理（无悬停无弹跳、四页全部可达）；② 长按圆点 = 原动态手感 + 不再被收起；③ 点圆点 = 原生动画跳页。

## 1.2.1-28（1002128）· bug 3 根修（停住后弹 8pt）：源头防漂移 + 回写条件化（基底 = 1.2.1-24）
- **流程变更（用户裁决）**：回退 1.2.1-24 基线，逐 bug 修。1.2.1-25/26/27 的引擎迁移整线作废（双引擎互踩引入跳动与新问题）；工作区源码从 GitHub -24 commit（020a35bd6838）精确恢复。
- **用户录屏逐帧取证（509 帧）**：落位动画结束后**静止约 0.2s，单帧离散跳变 ≈8pt**（视频位移 118→114，缩放折算 7.8pt）——不是动画过冲（过冲是多帧曲线），是某次延迟写入把内容挪了 8pt。8pt 与 `kERRestingModuleOffset = -8.0` 精确吻合。
- **根因链（代码级）**：拖拽期间 `ERRestoreNativeScrollBaseline` 因 transitionActive 被跳过 → 原生 `CCUIModuleCollectionView` 的 contentOffset 可被手指带偏（clamp 只在 Began/Ended/snap 窗口跑）→ 落位后 snap 窗口（0/0.08/0.24/0.42s）里 4882 行的**无条件归零写**一次性修正漂移 → 视觉上「停住后弹一下」。
- **修复（两层）**：
  1. **源头防漂移**：新增 `ERPinNativePagerScroll` —— 滑动 Began 时把原生集合 `scrollEnabled = NO`（拖拽期间 offset 不可能漂移）；四处收尾（pagePanned 编辑/非编辑 completion、finishInteractive completion、DISM-CLEAN）恢复 `scrollEnabled = YES`。落 `NATIVE-PIN on/off` 追踪行（带当时 offset，直接验证漂移量）。
  2. **回写条件化**：ERClamp 里对 CCUIModuleCollectionView / FCUIActivityListView 的归零写改为**差值 >0.5 才写**，并落 `SNAPZ cls= d=` 追踪行（若仍有漂移，直接给出类名与漂移量）。
- 滑动/点按正常路径零改动（用户红线）；scrub 动态完整保留（-24 原样）。
- 验证：翻页落位后应无任何「弹一下」；SSH 拉 plist 看 `NATIVE-PIN on/off` 的 offset 值（on 与 off 应一致 ≈0，证明无漂移）与 `SNAPZ` 是否出现（出现即仍有漂移源，数据直接指名）。

## 1.2.1-29（1002129）· bug 3 根修第二轮：漂移层定位修正（外层主滚动）
- **1.2.1-28 复测（用户）**：跳动仍在。追踪环关键证据：**`SNAPZ` 零条** —— 内层 `CCUIModuleCollectionView` 在整场复测中漂移从未超过 0.5pt（1.2.1-28 的内层 pin + 条件写生效），**但跳动存在** ⇒ 8pt 修正不来自内层集合，1.2.1-28 钉错了层。
- **修正定位**：这段代码有两层原生滚动 —— 内层 CCUIModuleCollectionView（-28 已钉）与**外层主滚动容器**（`ERNativeScrollViewForOverlay` 返回的那个）。漂移发生在外层：拖拽期间 applyPageTransform 因 transitionActive 跳过基线恢复（15176 行），外层 offset 被手指带偏；落位后 snap 窗口 `@[@0.0,@0.08,@0.24,@0.42]` 里**无条件**的 `[nativeScrollView setContentOffset:nativeOffset]`（16720-16723 行）一次性修正 ≈8pt —— 时序与录屏（落位静止 ~0.2s 后单帧跳）吻合。
- **修复（1.2.1-29）**：新增 `ERPinMainNativeScrollLight` —— 在 pagePanned Changed（拖拽每帧）把外层 offset 贴回基线（差值 >0.25 才写、CATransaction 禁隐式动画、落 `MAIN-PIN d=x/y` 追踪行）。漂移被摊进跟手过程（每帧 <1pt 不可见），snap 写自动变成 no-op，「停住后弹一下」消失。
- 内层 pin（-28）保留：两层都钉死，拖拽期间两个原生滚动都不可能漂移。
- 验证：落位后无弹跳；`MAIN-PIN` 行的 d 值 = 每次实际修正量（若持续出现大值，说明漂移源在别处，数据继续指路）。

## 1.2.1-32（1002132）· bug 2 根修（末页悬停）：撤销底部 92pt 让位区
- 用户关键观察：**上半部分滑动正常弹回，下半部分滑动就悬停** —— 与代码精确对应。
- 根因：gestureRecognizerShouldBegin:/shouldReceiveTouch: 的翻页分支有底部 92pt 让位区（当年为「底部上滑收起 CC」保留）——底部滑动被翻页手势拒绝后落给原生滚动容器，它未被完全钳死（bounces=NO 但 scrollEnabled/inset 行程仍在），拖动后没有任何机制拉回 = 悬停；上半部分走我们的橡皮筋所以正常。追踪环佐证：悬停期间模型/呈现层零动作（位移在原生层）。
- 修复（方案 A，对齐 CC18 全屏接管）：删除两处翻页分支的底部让位（shouldBegin + shouldReceiveTouch）；收起 CC 仍两条路：末页快速上拂让位（velocity<-400）+ 主屏指示条系统手势。编辑模式的两处底部护栏（dismiss pan / 模块拖拽）有意保留。
- 代价（如实）：底部区域慢速上滑不再直接收起 CC，而是页面回弹——与 iOS 18 CC 行为一致。
- 验证：下半部分滑动 = 与上半一致弹回；末页快速上拂 = 收起 CC；主屏指示条上滑 = 收起 CC。

## 1.2.1-33（1002133）· bug 2 根修第二轮：悬停真凶 = 斜率拒绝让位 + 原生滚动可滚
- 1.2.1-32 复测悬停仍在。probe 决定性数据：落位动画正常结束后，外层滚动 offset 从 -139 被拖到 +83（+222pt inset 行程）并停住 = 悬停本体；且内层集合查找 cc=-9999 = ERNativePagerCollectionViewForOverlay 永远 nil（要求 UICollectionView，运行时类不是）→ 内层钳制全空转。
- 真凶链条：shouldBegin 的斜率判定（垂直>水平×1.12 才接）把斜向滑动让给原生滚动 → 拖动+减速停住 → 悬停。-32 撤销的只是「底部位置让位」，斜率让位仍在。
- 修复（釜底抽薪，对齐 CC18「滚动由我们全权接管」）：① shouldBegin 删除斜率拒绝（滑动无条件归我们，斜滑=原地回弹）；② 主滚动 scrollEnabled=NO 常驻；③ 内层查找放宽为 UIScrollView + CCUIModuleCollectionView 常驻禁滚。末页快速上拂让位（收起 CC）保留。
- 教训：probe 的 modY/cc 占位值 -9999 是「查找失败」信号，第一版就该追查而不是留默认。

## 1.2.1-34（1002134）· bug 4 纯取证（长按圆点 → 内容全消失但可点击）
- 用户录屏 + 追踪环关键排除：复现时刻追踪环里**没有任何我方事件**（无 IPAN/SCRUB/FIN/RECON）——scrub 链路无辜；自愈不变量 C（模块 opacity）未触发=模块 layer.opacity 未变；视频显示磁贴网格+圆点全消失、仅媒体模块红心可见（媒体不在分页集合）——消失的是「分页内容层」而 CC 本体在（能点击）。
- 头号嫌疑：长按圆点触发 CCUI 自己的长按手势=进入编辑模式（iOS 17 系统行为），CCUI 藏正常内容视图而编辑视图未出现。CC18 圆点是自绘 C18PageControl 长按不触发 CCUI 手势=无此问题。
- 本版：看门狗新增 ERDumpInvisibilityScene——异常态（可见模块=0 且非编辑态）每 tick 落 CCVIS 行（editMode/col 状态/grid/dots/scrub 全量），复现一次直接指名消失的层。探针暂停（防洪水）。

## 1.2.1-35（1002135）· bug 4 取证 v2（修复取证盲区）
- 1.2.1-34 复测 CCVIS 零条 —— 取证器自身有盲区：ERDumpInvisibilityScene 开头 gEditModeActive 跳过，若消失态=编辑模式误入则采样器自己跳过了它。
- v2：① 编辑态不再跳过；② 加测面板本体 ovlHid/ovlA；③ 看门狗链终止留痕 WATCHDOG-STOP（pres/state/ovlA）——面板还在但系统认为已收起=状态失步的直接证据。

## 1.2.1-36（1002136）· bug 4 取证 v3（祖先链点名）
- 关键观察：-35 装好后用户两次开关 CC（00:30:56/00:31:27 两条 WATCHDOG-STOP，正常关闭）全程无翻页/圆点手势事件 = 本次复现是「纯长按不拖动」，长按本身即触发消失，进一步坐实 CCUI 长按手势方向。CCVIS 零条 = 消失时模块 opacity/hidden/alpha 全正常 → 消失在祖先层。
- v3：触发面放宽（模块全不可见 OR collection 消失 OR 面板透明 任一命中）+ **祖先链排查**（从首个模块向上爬，点名第一个 hidden/alpha<0.05/opacity<0.05 的祖先类名 hider= 字段）。

## 1.2.1-37（1002137）· bug 4 根修：scrub 期间压制收起手势
- 用户在 -35 上复现（长按+上下拖动）。probe 决定性链（00:35:36-42）：IPAN Began→CH×9→Ended→FIN tgt=3（scrub 全程正常）→ 3.7s 后 WATCHDOG-STOP pres=0 state=0 ovlA=1.00（系统宣布收起而面板 alpha=1）= scrub 尾态被 CCUI 收起手势解读 → 收起动画卡住 → 内容移出（看不见）而面板在（能点击）。
- 根因：圆点 scrub 路径从未压制收起 pan（pagePanned Began 有压制、圆点没有——-24 血统的遗漏）。
- 修复：抽公共函数 ERSuppressOverlayPans/ERRestoreSuppressedPans；pagePanned Began 改用公共函数（行为不变）；圆点 scrub Began 压制、Ended/结束态优先块恢复。

## 1.2.1-38（1002138）· bug 4 自愈层：容器消失态当场恢复
- -37 复测仍消失。60 条 CCVIS 实锤消失态：collection 与其父层 alpha/opacity 双 0（colA=0.00 colOp=0.00 hider=UIView a=0.00），而模块自身全部正常（mods=11/33 可见）——消失的是「分页内容容器」，被某次写入打成透明后无恢复路径。
- 修复：看门狗 ERDumpInvisibilityScene 升级为自愈——检测到容器消失态（colVanished/ovlVanished/模块全不可见）时当场把 collection 与「首个模块→overlay 祖先链」的 alpha/opacity/hidden 拉回 1.0（禁隐式动画），随后 applyPageTransform + 可见性重申，落 CCVIS-HEAL 行（n=恢复层数、hider=被恢复的层名——为后续修根写入者留证）。
- 效果：即使触发，内容 0.25s（一个看门狗 tick）内自动回来，不再卡死到注销。
- 坑：版本号连锁替换会改掉历史注释里的版本标，锚点匹配要用当前文本。

## 1.2.1-39（1002139）· bug A 修复（末页下滑收起）+ bug B 取证（残影几何）
- bug A（末页下滑收起）：追踪环实锤下滑被我们的翻页正常接住（PAGESETTLE 到页 2）但 1.4s 后 CC 仍被收起 = 双识别：我们的 pan 与 CCUI 收起 pan（挂在 presentation 容器=overlay 子树之外，子树压制够不到）同时识别同一次触摸。修复：ERSuppressOverlayPans 压制范围升级为整个 CC 窗口；末页快速上拂让位不受影响（那条路 shouldBegin 返 NO，无压制需求）。
- bug B（收起残影=CC 背板+圆点在而磁贴无）：残影窗口 CCVIS 零条=模块 opacity 全正常，疑为位置偏移（收起/再呈现布局把模块挪出屏）。CCVIS 触发面放宽：首模块呈现位置 vs 模型位置偏差>80pt 也算消失态，新增 posD/nat 几何字段。

## 1.2.1-40（1002140）· 末页滑动收起根修：让位规则全删（双副本教训）
- 用户裁决「滑动不该收起，收起只靠小白条」。-39 追踪环实锤：连续 4 次末页上滑（vy=-425~-2008）全部被我们正常橡皮筋接住，1 秒后 CC 仍被收起 = shouldBegin 的末页上拂让位（vy<-400 让位收起）在用户正常滑动速度区间内必触发。
- **关键事故**：文件里存在两份重复的 gestureRecognizerShouldBegin: 实现（-40 第一轮只删了第一份的让位，运行时用的是第二份=让位仍生效）。第二轮删除第二份让位，velocity.y<-400 全文件 0 残留。
- 现在：内容区内任何滑动都归翻页手势（末页上滑=橡皮筋回弹），CC 收起唯一入口=小白条系统手势。
- 教训：**改手势委托方法前必须 grep 全文件确认唯一性**（同方法多副本时运行时行为与源码直觉不符）。

## 1.2.1-41（1002141）· 残影取证 v4：遮挡检测（hitTest 点名覆盖者）
- 残影窗口 CCVIS 零条（模块 opacity/位置全正常）+ 残影态「手电筒可见其他磁贴无」= 排除透明度/位置后，头号嫌疑转为 z 序遮挡（背板盖住磁贴）。
- v4：采样器加遮挡检测——对首个可见模块中心 hitTest，命中不在该模块子树=被遮挡（occluder 字段点名覆盖者类名）；命中时（限 state==2 且非 scrub/edit/transition）自愈=collection bringToFront + 可见性重申（CCVIS-OCCLUDE 行）。
- 理论：z 序遮挡时模块一切属性正常但被盖住=与全部观察吻合；自愈后 0.25s 内容回来。

## 1.2.1-42（1002142）· 遮挡检测 v2
- 12:44:32.754 首次命中 occ=UIView（tr=1 滑动中）= 模型/呈现坐标错位误报 + 0.25s 采样错过收起瞬态。
- v2：hitTest 改用呈现层位置；tr=1 不判遮挡；命中者落完整父链（点名 UIView 挂在谁下面）。

## 1.2.1-43（1002143）· 残影根修：zPosition 跨层级压制
- -42 取证抓到覆盖者：CCUIS-OCCLUDE by=UIButton<ERQuickAccessHostView<CCUIHeaderPocketView（CC 顶部状态/快捷区容器）。收起/再呈现后 pocket 布局错乱压住磁贴；磁贴容器与 pocket 非兄弟视图，bringSubviewToFront 无效（OCCLUDE 反复触发实证）。另有 hider UIView 每 0.25s 被反复写 0（写入者在持续作恶）与模块累积 33→45（overlay 泄漏）待后续。
- 修复：heal 改用 layer.zPosition（跨父级生效）——磁贴容器 z=pocket.zPosition+10、圆点 host +11，一击把内容提到 pocket 之上；OCCLUDE 行加 pocketFrame 取证。

## 1.2.1-44（1002144）· 残影根修二：僵尸 overlay 清理
- -43 复测 OCCLUDE 仍反复触发但 pocketFrame 正常（{{0,0},{430,139}} 未盖磁贴区）+ mods 33→45 累积 = 推翻 pocket 布局错乱假设，真因 = **僵尸 overlay 累积**：旧 overlay 收起后 CCUI 把其容器 alpha 写 0（收起态正常行为），看门狗对着僵尸无限自愈与 CCUI 打架；用户看到的「看不见但能点击」= 僵尸 overlay 本体（还挂着圆点/手势）。
- 修复：① 存活门——overlay 不在窗口 = 僵尸，跳过一切治疗（CCVIS-SKIP）；② 呈现完成时清尸——把不在窗口的旧 overlay 从 gOverlayControllers 移除（OVERLAY-PURGE n/left）；③ CCVIS 加 ovl=总数/在窗 字段。
- 教训：版本号连锁替换会改历史注释锚点；锚点必须用当前文本 grep 后再写。

## 1.2.1-45（1002145）· bug 4 终版根修：幽灵模块过滤（页数膨胀）
- -44 数据证伪僵尸 overlay（ovl=1/1、PURGE=0）但抓到决定性线索：TAP p=4（第 5 个圆点）+ RECON pg=4->4 m42=-3872=4*968 = **第 5 页真实存在** + mods=45。真因 = CCUI 每次呈现往 overlay 挂新模块 childViewController，旧控制器视图被移出（window=nil）但控制器仍挂载 → 模块 33→45 跨会话累积 → 页数按幽灵模块推导膨胀到 5+ → 圆点多出空页 → 长按圆点导航到空页 = 看不见但能点击。
- 修复：ERCollectModuleControllers 过滤——只保留 isViewLoaded && view.window != nil 的模块；幽灵计数落 COLLECT-GHOST n/kept（变化时才落）。页数/圆点/可见性回归真实。

## 1.2.1-46（1002146）· bug 4 终版根修：模块 identifier 去重
- -45 窗口过滤失效（COLLECT-GHOST 零条）+ mods=47 + PAGESETTLE to=-4840=第 6 页 + cur=5 + pocketFrame 139→155。真相：幽灵模块视图没离开视图树（CCUI 把旧模块视图藏在原地），窗口过滤抓不到。真因=持久化 overlay + CCUI 每次呈现追加新模块控制器 → 模块 33→45→47 累积 → 页数推导 6+ → 圆点 6 个 → 导航到空页 = 看不见但能点击。
- 修复：state==2 呈现完成时按 identifier 去重——同名模块只留最后出现的（最新在屏），旧的 removeFromParentViewController+view.removeFromSuperview 物理移除（MODULE-DEDUPE removed/kept 追踪）。
- 教训：版本标链式替换导致锚点三次失配——大文件锚点必须先 grep 当前文本。

## 1.2.1-47（1002147）· 去重键回退 + 模块清单转储
- -46 MODULE-DEDUPE 零条 = ERModuleIdentifier 对幽灵模块返回空，去重键失效。
- v2：去重键回退为「identifier 优先，空则类名」；state==2 转储 MODLIST（前 16 模块的 class/identifier 长度/hidden/alpha）——看清幽灵的形态。

## 1.2.1-48（1002148）· 残影根修：收起瞬间隐藏我方副本层
- 用户关键观察：控制中心面板退出后，磁贴在桌面停留 0.5-1 秒。嫌疑=我方常驻副本层（快捷指令磁贴渲染副本 duplicate host 等）——其隐藏动作挂在「同步窗口」里，收起时窗口已结束无人隐藏 = 副本比面板多活 0.5-1s。
- 修复：DISM-CLEAN（state 3/0）第一时间隐藏 duplicate host（181052）/快捷区 host（181000）/圆点 host；collection 属面板层级随面板自然退场不动。
- 坑：kERQuickAccessHostTag 不存在（快捷区现役 tag=181000）；indicatorHost 是 UIView 不是 UIViewController（锚点笔误）。

## 1.2.1-49（1002149）· 残影根修终版：内容层统一淡出生命周期
- 用户关键观察定方向：第一页亮度模块无感（系统自渲染跟随面板退场）、页码越大停留越久（内容层 opacity 恒 1 无人淡出，按模块排队的延迟清理逐页跑完）。用户裁决：0.3s 内消失即可。
- 修复：① state 3（收起启动）collection.layer.opacity 0.2s 统一淡出（CABasicAnimation ERDismissFade，fillMode forwards）；② state 0 兜底切 0；③ state 2（呈现完成）显式恢复 opacity=1（在任何自愈前，避免打架）。

## 1.2.1-50（1002150）· 缓落根修：落位 completion 禁隐式布局动画
- 用户视频逐帧定量：滑到第 3 页落位后 0.3-0.4s 顶部三排以减速曲线下坠约 100pt = CCUI 布局重算的隐式动画（模块 frame 从旧布局位置缓缓落到新位置）。页 4/5 经圆点再滑正常 = 布局已稳定无 frame 差异。
- 修复：三处落位 completion（滑动编辑态/滑动非编辑态/scrub+TAP+自愈）整体包 performWithoutAnimation——布局 frame 变化立即生效，缓落物理性消失。
- 教训：文件里存在两份滑动 completion（编辑态/非编辑态），尾部结构不同（一个 prepareGrid 结尾一个 updateTopFade 结尾），包裹必须逐个核对块尾。

## 1.2.1-53（1002153）· 缓落数据采集版（基底=-50 精确恢复）
- 决策：-50 为新基线（-51 误删事故 + 47/51 累积为 BFS 重复计数误读，GEN-MAP 实证 12 模块稳定无累积）。源码从 -50 commit（d72f6384）整树恢复。
- 本版只加缓落探针：滑到第 2+ 页落位后 1.2s 内采样顶部 3 模块呈现位置 + 外层滚动/collection offset/contentInset.top（DROOP 行×6），下坠的动画层直接指名。零逻辑改动。

## 1.2.1-54（1002154）· 缓落根修：落位动画全清
- DROOP 窗口坐标实锤：滑到第 3 页落位瞬间磁贴窗口位置差一页（m0=1061 vs 终点 160），0.5s 动画归位=缓落。colWinY 恒 139=collection 不动，磁贴相对 collection 的 frame 差一页。
- 根因：第 3 页顶部三排模块的布局归属曾变动（挤到下一页又拉回），CCUI 布局重算以 UICollectionView cell move 动画（0.5s）归位。-50 的 performWithoutAnimation+指定键移除管不住 UICollectionView 自己的 move 动画。
- 修复：滑动路径（非编辑态）与 scrub/TAP 路径的落位 completion 对当前页模块 removeAllAnimations 全清。编辑态分支不加（防误伤编辑动画）。

## 1.2.1-55（1002155）· 缓落触发源切除：snap 补写判等跳过
- -54 removeAllAnimations 无效 = 移动不是 CA 动画而是逐段 frame 写入。DROOP 下坠窗口（0-0.5s）与 snap 补写窗口（0/0.08/0.24/0.42s）完全重合 = 每次补写触发 CCUI scrollViewDidScroll → 内部修正内容（带动画）→ 磁贴逐段归位。
- 修复：snap 补写前判等（contentOffset 已在目标 0.5pt 内则跳过写入）——拖拽期间 MAIN-PIN 已逐帧钉位，补写本就多余。不写=不触发=缓落源切除。

## 1.2.1-56（1002156）· 动画源点名探针（纯采集）
- DROOP 实锤缓落=顶部磁贴窗口 Y 1036→157 动画 0.5s（垂直 880pt 归位），colWinY/nat 恒定=collection 不动，动画在磁贴内部层级。-54 清模块层无效=动画载体是别的层。
- v6：t=0.15-0.45 采样顶部磁贴 superview 链逐层「呈现 vs 模型」Y 差 + animationKeys + 类名——动画载体与键名直接现形。

## 1.2.1-57（1002157）· 缓落真凶根修：collection 层动画清除
- ANIMCHAIN 实锤动画载体 = CCUIModuleCollectionView 自己的 layer（d=0 但 animationKeys 非空，子树整体被平移 305-880pt）。-54 清模块层没够到它。-55 snap 判等无关（动画非 snap 触发）。
- 修复：滑动路径 + scrub/TAP 路径的落位 completion 对 collection.layer 及其 superview 链 removeAllAnimations——contentOffset/bounds 瞬间跳终值，磁贴瞬间到位。

## 1.2.1-58（1002158）· 缓落终版：滚动抑制窗口
- 机制闭环：现有 %hook layoutSubviews 的零位锚（offset≠0 即拉回 0）与 CCUI 的动画滚动（contentOffset.y -880→0）互相拉扯 = 缓落合成轨迹。
- 修复：%hook 内新增 setContentOffset:animated: 覆写——落位后 1.5s 抑制窗口内强制 animated:NO（CCUI 滚动瞬间到位，无拉扯）；两个落位 completion 设 gERDroopSuppressUntil。

## 1.2.1-59（1002159）· 缓落根修：非动画 setContentOffset 入口封堵
- -58 只拦了 animated: 变体；CCUI 在自己的动画块里调 setContentOffset:（无标志）→ bounds.origin 逐帧动画写入（ANIMCHAIN 容器 d=261 keys=- 实锤写入驱动）。
- 修复：%hook 新增 setContentOffset:（无动画变体）覆写——窗口内 >100pt 大偏移写入忽略（零位锚持有正确位置），小偏移动作禁用事务瞬时应用。

## 1.2.1-60（1002160）· 缓落终版：actionForLayer 关卡否决
- 前四轮失败复盘：-54 清错层/-55 拦错触发/-58 拦错变体/-59 探针挂错分支（编辑态 completion，正常滑动不经过，缓落轨迹从未采到）。
- 终版：① %hook CCUIModuleCollectionView 加 actionForLayer:forKey:——抑制窗口内对 bounds/position 返回 NSNull（CA 隐式动画唯一必经关卡，事前否决而非事后清除，覆盖一切写入路径）；② 抑制窗口设在落位启动点（now+1.8s，不依赖 completion）；③ 探针同步搬到启动点（+0.45/0.9/1.4s）。

## 1.2.1-68（1002168）· 锁屏组件/通知卡片整体换成上游 Soko 1.1.0（ObjC + Logos 重写）
- 基线：1.2.1-60（d45a6211）。1.2.1-61~66 的 addAnimation/缓落实验不进本版；-60 自带的 actionForLayer 抑制窗口原样保留。
- Soko：Swift（rc.3 移植）整目录删除，改由上游 1.1.0 的 ObjC/Logos 源编入同一支 EchoReborn.dylib。组件「顶部/底部」改成长按锁屏 → 自定义 → 上下滑切换，按壁纸各自记忆（写进 PRPosterComplicationLayout 归档，编码键 SokoComplicationsUseBottomLayout）。
- 旧设置桥：6 个 soko_* 键（域 com.strive.echoreborn.preferences、通知 com.strive.echoreborn/ReloadPrefs）名字/默认值/语义不变，1.1.0 的 SokoPreferences.m 按同键读取，设置页继续实时生效。
- 修复：① 根 filter 补 com.apple.PosterKit / com.apple.MercuryPoster（壁纸配置在这两个进程编解码，缺了就是「编辑完退出回顶部」），Tweak.xm 的 %ctor 对它们第一行 return；② Soko 的 %ctor 改显式进程白名单（原来 Siri 三个进程会误走 poster 分支）；③ SokoPosterModel 的 <roothide.h> 改 __has_include 守卫（rootless 可编译），jbroot 兜底收进 SokoPrivate.h；④ 删除 Soko.x 里对 quickActionsView 的 transform 缩进 —— 与 Tweak.xm 的 center 路径叠加成 2× 位移，横向缩进唯一由 Tweak.xm 负责；⑤ marker 改名 com.strive.echoreborn.default-layout（不与真 Soko 抢文件）；本包不带 postinst，首次下滑一次即可，之后按壁纸记忆。
- 诊断：新增 ERSokoLog 跨 TU 日志桥（Tweak.xm 实现 / Soko 各 .m 调用），打 SOKO-CAP / SOKO-DOCK / SOKO-SWIPE / SOKO-ENC / SOKO-DEC；日志开关未就绪前的行做早鸟缓冲，避免丢掉启动期探针。

## 1.2.1-69（1002169）· 编辑态拖动诊断版（只加日志，不改行为）
- 现象：长按进入编辑态后无法上下拖动切换组件位置。
- 新增 Soko/SokoFileLog（独立文件 /var/mobile/Library/Logs/EchoReborn/soko.log，256KB 截断，按进程名打前缀）—— 不用 ERLogMirror 是因为它是 60 行环，SpringBoard 的 CC 心跳会把 PosterBoard 的判定行冲掉。
- 探针：CTOR（进程归属/bundleId）、CAP（model/dock/poster/liquidAss）、INITPOSTER（支持判定 + 选中了哪组 widget 配置与加号手势钩子）、CONTAINER/EDITOR（登记与角色）、SWIPE-INSTALL/SKIP（手势装在哪一层）、SWIPE-TOUCH、SWIPE-BEGIN（逐条记录 canSwipe/presented/inset/dodging/dismissing/portrait/起手时长/方向/起手点是否落在 editingRowFrame±24 带内）、SWIPE-END（位移/速度/阈值）、ROW（editingRowFrame 与 inset/usesBottomEditingRow 的真值）。

## 1.2.1-70（1002170）· 诊断通道改 cfprefsd 键（文件写不进）
- 1.2.1-69 实锤：iOS 17.2.1 + rootless 下 SpringBoard 写 /var/mobile/Library/Logs/EchoReborn 被沙箱挡（目录能建、echoreborn.log 0 字节），Soko 文件日志同样写不进去。
- 改为写 CFPreferences 独立键 com.strive.echoreborn.preferences / ERSokoMirror（120 行 / 20KB 环），不与 ERLogMirror 的 60 行环抢行；SSH 拉 plist 的 ERSokoMirror 即可读全部判定行。

## 1.2.1-71（1002171）· 定位 PosterBoard 侧：双域日志 + isSupported 预演
- 现象补充（用户）：原版 Soko 在底部态进编辑态，组件也在底部；我们这版进编辑态却回到顶部 —— 指向 PosterBoard 侧 Soko 完全没干活。
- 双域日志：SokoFileLog 除写 com.strive.echoreborn.preferences 外，再写进程自己的 bundleId 域（PosterBoard 写不进宿主域，但一定写得进自己的域），SSH 读 com.apple.PosterBoard.plist 的 ERSokoMirror 即可。
- SpringBoard 里预演 PosterBoard 的 isSupported 五项：nativeBottom（PRComplicationContainerViewController setWidgetsUseBottomLayout:）/ rowFrame / reticle / frameRect / frameVariant（后四项在 CSProminentLayoutController）。哪一项为 0 就是 PosterBoard 侧整段跳过的原因。

## 1.2.1-72（1002172）· 数值标定版（只采集，不改行为）
- 目标：把"顶部/底部"两档换算成滑块同一套单位（pt），确认实际行程。
- CALIB 行：screen 尺寸 / safeAreaBottom / stockY（系统原位行 = 顶部态行，SpringBoard 未装 _frameForElement: hook，取到的是系统原值）/ bottomY（底部态行，含当前 offset）/ delta = stockY - bottomY。
- 判读：delta 就是"从底部走到顶部"需要写进 soko_widgetOffset 的量（当前滑块只有 -120~120，明显不够）。

## 1.2.1-73（1002173）· 滑块行程 -400~+120、默认/重置归 0、重置即时生效、海报进程报到探针
- 滑块：soko_widgetOffset 范围 -120~+120 → **-400~+120**，默认 -18 → **0**；soko_notificationOffset 默认 60 → **0**（范围不变）。
- 重置无效根因修复：SokoPreferences 原为"键存在才覆盖"，设置页重置只删 key → 缓存保留旧值，画面不变、必须拖一下滑块才生效。改为**键不存在即回落默认 0**，并新增 SokoPreferencesSetChangeHandler —— 变更/重置后 SpringBoard 立即 refresh + setNeedsLayout 重算组件行。
- 海报进程报到：PosterBoard/PosterKit/MercuryPoster 侧写不进宿主偏好域（实测其自身域也没有文件），改为 %ctor 里 notify_post 一条报到通知，SpringBoard 侧监听并落盘 `POSTER-HELLO <name>`，用于确认编辑器进程是否真的加载了本 dylib。
- CALIB 几何标定行（只读）：stockY（系统原位=顶部）/ bottomY（底部）/ delta，用于把两档换算成滑块同一单位。

## 1.2.1-74（1002174）· 海报进程判定码通道（Darwin notify）
- 1.2.1-73 实锤：PosterBoard 已注入并执行（收到 POSTER-HELLO.posterboard），但它既写不进宿主域，也写不进自己的域（com.apple.PosterBoard.plist 根本不生成）。所以判定只能走 Darwin 通知。
- SokoTrace(code, payload)：海报进程把判定压进 notify state，SpringBoard 解码后落盘为 `TRACE code=… payload=…`。编码：低 8 位 code，高 32 位 payload+100000。
- 码表：1 posterSupported / 2 liquidAss / 3 容器登记 / 4 编辑器登记 / 5 手势装(编辑器) / 6 手势装(容器) / 7 触摸(payload=起点y) / 8 接受(payload=行y) / 9 拒绝canSwipe(payload=位掩码:1弹层2insetNaN4dodging8dismissing16横屏) / 10 拒绝hold(ms) / 11 拒绝非纵向(vy) / 12 拒绝方向(vy) / 13 行框空 / 14 拒绝起手点出界(payload=起点y) / 15 应用(payload=切换前是否底部) / 16 editingRowFrame(payload=行y)。

## 1.2.1-75（1002175）· 根修：装了 LiquidAss 就整段跳过编辑器钩子
- 实锤（TRACE code=2 payload=1）：只要 lgHostEnabled("Clock") 为真，SokoInitPoster 就走「LiquidAss 分支」——该分支只装几何钩子，不装编辑态 reticle / 滑动 / 壁纸状态写入。所以长按进自定义既不在底部、也拖不动。
- 修复：① 删除 SokoInitPoster 的 LiquidAss 早退分支，永远装标准编辑器钩子；② CSComplicationManager 读状态、SokoPosterLayout 选几何，都改成「这张壁纸的 userInfo 里真有 dylv.liquidass.clock.style 才算 LiquidAss」，否则走本插件自己的状态；③ 删除 frameByAdjustingFrame 里 `if (editing && liquidAss) return frame` 的编辑态早退。
- 判定码通道修正：原来所有 code 共用一条通知名 + notify state，连续两笔被系统合并（实测 code=1 丢失只剩 code=2）。改为每条 code 一条独立通知名 com.strive.echoreborn.soko.tr.<code>。
- 滑块下限 -400 → **-520**（实测顶部 = 底部 -518）。

## 1.2.1-76（1002176）· 连续位置：编辑器与滑块共用同一个数值 + 边框跟随
- 新通道 SokoDockPublishRowOffsets(rowOffset, topOffset, isSet)：SpringBoard 每次布局把「底部基准 + 生效偏移」「顶部端点(-518)」「是否显式设置过」发布给海报进程。
- 行定位统一为 y = 底部基准行 + 生效偏移（编辑态/非编辑态同一套，去掉原来的 -28 编辑补偿），因此滑块 -200 进自定义就在 -200。
- 编辑态虚线框改为直接钉到同一公式，不再用「系统行框差值」平移（17.2.1 上两套行框相同、差值恒 0，导致边框不跟随）。
- 上滑 = 请求 topOffset(-518)，下滑 = 请求 0；PosterBoard 无法写偏好，改由 SokoEditorRequestRowOffset 发通知，SpringBoard 落盘 soko_widgetOffset 并广播 ReloadPrefs，设置页数值随编辑同步。
- 只要用户显式设置过偏移，即使该壁纸布尔为"顶部"，dock 也接管渲染。

## 1.2.1-77（1002177）· 编辑态虚线框跟随 + 滑动跟手
- 边框不跟随根因：frameByAdjustingFrame 里对 `variant == kSokoReticleVariant(3)` 直接 return，而 17.2.1 的编辑虚线框正是走 variant 3 算帧 → 组件滑走、框留在原位。现改为 variant 3 与组件行走同一套定位公式。
- 滑动后 0.2~0.3s 才动的根因：重排走 0.45s 弹簧动画（且要等跨进程 offset 发布回来）。改为编辑态/几何更新一律 relayoutAnimated:NO 立即重排，动画分支时长压到 0.18s。
- 变体纠正：15 Pro Max 是 RootHide（/var/jb -> /、有 libroothide.dylib、dpkg 架构 iphoneos-arm64e），之前误装 rootless 包（iphoneos-arm64）才需要 --force-architecture；已改用 CI 的 roothide 产物，dpkg -i 无需强制参数。

## 1.2.1-78（1002178）· 按原版语义重做编辑期：本地会话 + 完成才生效 + 震动 + 边框 transform 兜底
- 编辑期不再跨进程：进入编辑时把当前生效偏移取进会话（SokoPosterLayout editingRowOffset），滑动只改会话值；取消退出会自动回落到发布值。
- 保存语义对齐原版：只有 setComplicationLayout:（"完成"路径）才把会话值落盘（发通知由 SpringBoard 写 soko_widgetOffset）；"取消"不写、不生效。
- 震动：滑动生效时 Light 轻震（与原版一致）。
- 跟手：编辑期全程本地、无跨进程等待，重排改回 0.3s 弹簧（原版手感）。
- 虚线框：先让系统 updateReticleViewFrames 重算（它会覆盖 frame 修正），再按「目标 y − 系统原位 y」叠加 transform.ty 兜底。

## 1.2.1-79（1002179）· 每壁纸归档偏移 + 顶部基线校正 + 开关生效
- 顶部端点校正：原用 layoutController 类方法算「系统原位行」(210)，与系统真正摆出的组件行差 ~11pt，导致 -518 实际偏低；改用 complications 视图的真实 frame，顶部端点应落到 ~-507。滑块下限 -520 → **-510**。
- 每张壁纸独立记忆：新增归档编码键 ERSokoRowOffset(double)，随系统保存落盘；「完成」写进新 layout、「取消」不写 —— 天然实现原版语义（之前写偏好所以取消也生效）。
- 编辑会话初始值取自该壁纸归档偏移，因此"设置里 -200 → 进自定义就在 -200"。
- 开关修复：「调整组件位置」关闭 → 完全不接管（之前被 isSet 判定盖过）；「调整通知位置」关闭 → listMinY / footer inset / footer 中心三处全部不介入。
- 设置页镜像：SpringBoard 读到归档偏移时写回 soko_widgetOffset，切壁纸滑块跟随。
- 虚线框：仍不跟随，本轮加 TRACE 17/18/19（位移×10 / 边框高 / 系统原位）定位是没算对还是被系统复位。

## 1.2.1-80（1002180）· 修复"上滑下滑无效"：几何发布与停靠解耦
- 根因：顶部/底部基准只在 layoutDock 里计算并发布，而 layoutDock 只在"组件已被 dock 接管"时执行。默认顶部态下 dock 不启用 → 顶部 offset 从未发布（NaN）→ 编辑器滑动判定的 `isnan(topOffset)` 直接 return，表现为怎么滑都没反应。
- 修复：抽出 publishRowOffsetsIfPossible，在 publishDockGeometry（每次锁屏布局都会走）里发布；layoutDock 改为复用发布值，两套算法不再漂移。
- 顶部基线仍取"系统真实摆放的组件行"（≈ -507），滑块下限 -510。

## 1.2.1-81（1002181）· 编辑态虚线框强制跟随（兜底）
- 1.2.1-80 的 TRACE 已证明滑动恢复：code 7（触摸）/16（editingRowFrame=728）/8（接受）连续出现。
- 边框仍不跟随：系统 updateReticleViewFrames 与我们的 frame/transform 都被随后复位。改为在每次重排后遍历编辑场景视图树，按类名匹配 reticle 视图并直接按其父视图坐标强制定位；同时 TRACE 17=命中数 / 18=目标y×10 / 19=当前偏移。

## 1.2.1-82（1002182）· 修复滑块/滑动同时失效
- 滑块无效根因：shouldHostDock 只认 self.enabled，而它仅在壁纸切换回调里更新；设置页改值后从未重算 → 一直不接管。改为：开关打开且（设置页设过值 或 该壁纸归档有值）即接管；设置页变更回调里同时 setEnabled 重算。
- 滑动"无反应"根因：handleSwipe 用跨进程发布值当"当前值"，滞后一帧时会与目标相同而直接 return（日志里只有 7/16/8、没有 15）。改为当前值优先取编辑会话值。
- 完成后立即生效：除写归档外再发一次 setrowoffset，SpringBoard 收到即设为当前生效偏移并接管刷新。
- PUB 日志：throttle 1s 打 top/eff/set/prefs/archive 五元组，便于核对顶部基线与生效值。

## 1.2.1-83（1002183）· 渲染唯一来源改回滑块 + 顶部端点 -507 修正
- 实锤（PUB 行）：`eff=-108.1 prefs=-108.1` 之后变成 `eff=0.0 archive=0` —— 完成时写进归档的 0 覆盖了设置页的 -108，导致"滑块拖了没反应"。改为：渲染只认 soko_widgetOffset；归档值仅写入（为将来每壁纸记忆保留），不参与渲染与接管判定。
- 顶部端点经验修正 +11pt：量到 -518，系统实际渲染行对应 -507，与用户实测一致。
- 接管判定简化为「开关开 && 滑块设过值」。

## 1.2.1-84（1002184）· 顶部基线缓存 + 虚线框匹配放宽
- 实锤：停靠后组件视图被搬进 dock，再拿它当"系统原位"量出来是 11pt（PUB top=11.0），整条偏移尺度全错。改为只在"未停靠/不在 dock 容器内"时采样一次并缓存。
- 虚线框：TRACE 17 一直是 0 → 类名匹配不到。放宽到 Reticle / Outline / Dashed 三类关键字，继续用 17 回报命中数。
