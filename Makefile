ARCHS = arm64 arm64e

# 16.5 is the newest SDK Theos ships and it is what this project has always
# built against.  It is pinned deliberately, NOT `latest`:
#
# Theos' iPhoneOS16.5.sdk contains a SwiftUI.swiftinterface produced by Apple
# Swift 5.8.  Its @inlinable bodies call os_log() with string interpolation, and
# every Swift 6.x compiler rejects that outright ("string interpolation cannot
# be used in this context"), so `import SwiftUI` can never succeed against that
# SDK under a Swift 6 compiler:
#
#   SwiftUI.swiftinterface:17964:59: error: string interpolation cannot be used
#   in this context; if you are calling an os_log function, try a different
#   overload
#     -> error: failed to build module 'SwiftUI'; this SDK is not supported by
#        the compiler (the SDK is built with 'Apple Swift version 5.8', while
#        this compiler is 'Apple Swift version 6.3.3')
#
# The fix is the compiler, not the SDK: CI pins the job to macos-14, whose
# default Xcode ships a Swift 5.x compiler that reads that interface fine.
# Neither Soko nor LiquidSiri uses any API newer than iOS 16.4, so this SDK
# covers both subprojects completely.
#
# (Vendoring a modern Xcode SDK as `latest` was tried and reverted: Apple's
# newer SDKs no longer ship the full set of Swift overlay .tbd stubs, so ld64
# lost libswiftUIKit.tbd and could not resolve the
# __swift_FORCE_LOAD_$_swiftUIKit reference Swift emits for `import UIKit`.)
TARGET = iphone:clang:16.5:16.0

# The package scheme is selected by CI: `make package THEOS_PACKAGE_SCHEME=rootless`
# or `...=roothide`.  A command-line assignment overrides anything set here,
# so rootless merely remains the default for local builds.
THEOS_PACKAGE_SCHEME ?= rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = EchoReborn EchoRebornBackboardd EchoRebornDualCam EchoRebornUIKit

# 0.5.26: Soko and LiquidSiri are no longer separate subprojects / dylibs.
# Shipping them as their own Soko.dylib + LiquidSiri.dylib put a SECOND copy of
# LGLiveBackdropView (and its supporting C helpers) into SpringBoard next to
# GlassKit's copy in EchoReborn.dylib.  Two @implementations of one ObjC class in
# one process is undefined behaviour: the runtime keeps whichever image loads
# first and the other's ivar layout no longer matches, so the very first glass
# property access walks off the object - SpringBoard dies and the device
# respring-loops.  Everything now compiles into EchoReborn.dylib, so any leftover
# duplicate would be a link error instead of a runtime landmine.
EchoReborn_FILES = Tweak.xm \
                GlassKit/LGGlassKit.x \
                GlassKit/LGLiveBackdropView.m \
                GlassKit/LGGlassLog.m \
                Soko/Soko.S \
                Soko/Soko.swift \
                $(wildcard Soko/Hooks/*.swift) \
                $(wildcard Soko/SokoLayout/*.swift) \
                $(wildcard Soko/Support/*.swift) \
                $(wildcard Soko/Shared/*/*.swift) \
                LiquidSiri/Tweak.x \
                LiquidSiri/SwiftUIWave/Models/SiriWave.swift \
                LiquidSiri/SwiftUIWave/Views/SupportLine.swift \
                LiquidSiri/SwiftUIWave/Views/WaveView.swift \
                LiquidSiri/SwiftUIWave/Views/SiriWaveView.swift \
                LiquidSiri/SwiftUIWave/Views/SiriMetalView.swift \
                LiquidSiri/SwiftUIWave/WaveManager.swift \
                LiquidSiri/Shared/LGSharedSupport.m \
                LiquidSiri/Shared/LGHookSupport.m \
                LiquidSiri/Shared/LGBannerCaptureSupport.m \
                LiquidSiri/Shared/LGMetalShaderSource.m \
                LiquidSiri/Shared/LGGlassRenderer.m \
                LiquidSiri/Shared/LGBackButtonSupport.m \
                LiquidSiri/Runtime/LGLiquidGlassRuntime.m \
                LiquidSiri/Runtime/LGSnapshotCaptureSupport.m
# Union of what EchoReborn, Soko and LiquidSiri each linked separately.
EchoReborn_FRAMEWORKS = UIKit CoreFoundation CFNetwork QuartzCore CoreImage CoreMotion \
                     Foundation SwiftUI AVFoundation Accelerate AudioToolbox MetalKit \
                     Metal MetalPerformanceShaders CoreVideo
EchoReborn_PRIVATE_FRAMEWORKS = ControlCenterServices SpringBoardUIServices
EchoReborn_CFLAGS = -fobjc-arc -Wno-nullability-completeness -Wno-deprecated-declarations \
                 -Wno-unused-variable -Wno-unused-function
# Soko and LiquidSiri are Swift 5 sources; one -swift-version for the whole
# instance. The generated ObjC header is now EchoReborn-Swift.h (see Tweak.x).
EchoReborn_SWIFTFLAGS = -swift-version 5

# 0.4.0: the LiquidAss render server is vendored. This second instance hooks
# backboardd and registers the echoreborn.liquidglass.* CAFilter types that
# GlassKit's LGLiveBackdropView asks the render server for. Without it the
# SpringBoard side silently renders no glass.
EchoRebornBackboardd_FILES = BackboarddGlass/Tweak.mm \
                      BackboarddGlass/LGSymbolResolver.mm
EchoRebornBackboardd_FRAMEWORKS = Metal QuartzCore CoreFoundation
EchoRebornBackboardd_LDFLAGS = -lc++
EchoRebornBackboardd_CFLAGS = -fobjc-arc -std=c++17 -fno-objc-arc-exceptions

# 1.0.7-5 · 相机双摄。
#
# 为什么是**第三支独立 dylib** 而不是把 com.apple.camera 加进主 filter：
# 主 dylib 里是 1.18MB 的 Tweak.xm + Soko + LiquidSiri + GlassKit，那份代码里有大量
# 只对 SpringBoard / 控制中心成立的 hook（AVCaptureSession 之外还有 CCUIModule*
# 一整套）。把它们一并注入相机进程，等于让相机去承担一整套与之无关的 hook 与
# 崩溃面。这里只把双摄相关的代码注入 com.apple.camera，filter 见项目根的
# EchoRebornDualCam.plist。
EchoRebornDualCam_FILES = DualCam/Tweak.xm
EchoRebornDualCam_FRAMEWORKS = UIKit AVFoundation CoreMedia Photos CoreImage CoreVideo
# -std=c++17 是必须的，不是保险：DualCam/Tweak.xm 是 .xm（Theos 按 ObjC++ 编译），
# 而 Photos.framework 的 PHImageManager.h 里直接写着
#     #error "Photos requires C++11 or later"
# 用默认 C++ 标准（gnu++98）会在 <module-includes> 阶段就炸出
#     fatal error: could not build module 'Photos'
# 主 target 因为不 import Photos 所以一直没暴露这个问题。
EchoRebornDualCam_CFLAGS = -fobjc-arc -std=c++17 -Wno-deprecated-declarations

# ---------------------------------------------------------------------------
# 1.0.9-81 · EchoRebornUIKit：把液态玻璃渲染层注入 com.apple.UIKit（= 所有进程）
#
# 结构照抄上游 Liquidify：他们的渲染器放在 Filter = com.apple.UIKit 的 dylib 里，
# 这样"开关 / 滑条 / 键盘"等出现在任意 App 的控件都能用上同一套渲染。
#
# LiquidGlassKit（上游开源库，MIT，DnV1eX）在这里编译；主 dylib 不再重复编译它，
# 避免同一进程里出现两份同名 Swift 类。
# ---------------------------------------------------------------------------
EchoRebornUIKit_FILES = UIKitGlass/Tweak.xm \
                GlassKit/LGGlassKit.x \
                GlassKit/LGLiveBackdropView.m \
                GlassKit/LGGlassLog.m
EchoRebornUIKit_FRAMEWORKS = UIKit Foundation QuartzCore CoreVideo CoreImage Metal MetalKit MetalPerformanceShaders
EchoRebornUIKit_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-function
EchoRebornUIKit_SWIFTFLAGS = -swift-version 5

# ---------------------------------------------------------------------------
# LiquidGlassKit 的 Metal shader 编译（Theos 不认 .metal，这里手工用 xcrun 编译）
#
# 两个 .metal → 一个 default.metallib → 落到
#   <jbroot>/Library/Application Support/EchoReborn/LiquidGlassKit.bundle/default.metallib
# 代码侧从该 bundle 加载（见 LiquidGlassKit/LiquidGlassView.swift 的 makeDefaultLibrary 调用）。
# ---------------------------------------------------------------------------
ER_LGK_BUNDLE_NAME = LiquidGlassKit.bundle
ER_METAL_SRCS = LiquidGlassKit/LiquidGlassVertex.metal LiquidGlassKit/LiquidGlassFragment.metal
ER_METALLIB_STAGE = $(THEOS_STAGING_DIR)/Library/Application Support/EchoReborn/$(ER_LGK_BUNDLE_NAME)

# 1.0.9-86 · 把上游**预编译**的液态玻璃渲染器打进本包（shader 已内嵌在 dylib 里，无外部资源）。
# 用它的二进制而不是重编源码：同一份源码在我们环境（Swift 5 / iOS 16.5）编译后运行期会 Swift trap。
# 它的依赖 @loader_path/LGOffline.dylib 必须与它同目录，所以两个一起放。
ER_PREBUILT_DYLIB_DIR = $(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries
before-package::
	@mkdir -p "$(ER_PREBUILT_DYLIB_DIR)"
	@cp Prebuilt/LiquidGlassKeyboard.dylib "$(ER_PREBUILT_DYLIB_DIR)/" && \
	 cp Prebuilt/LGOffline.dylib "$(ER_PREBUILT_DYLIB_DIR)/" && \
	 cp Prebuilt/LiquidGlassKeyboard.plist "$(ER_PREBUILT_DYLIB_DIR)/" && \
	 echo "    Prebuilt: 已打入液态玻璃渲染器"

before-package::
	@mkdir -p "$(ER_METALLIB_STAGE)"; \
	BUILD=$$(mktemp -d); \
	ok=1; \
	for src in $(ER_METAL_SRCS); do \
	  out="$$BUILD/$$(basename $$src .metal).air"; \
	  xcrun -sdk iphoneos metal -c "$$src" -o "$$out" || ok=0; \
	done; \
	if [ $$ok -eq 1 ]; then \
	  xcrun -sdk iphoneos metallib $$BUILD/*.air -o "$(ER_METALLIB_STAGE)/default.metallib" && \
	  cp Info.plist "$(ER_METALLIB_STAGE)/" 2>/dev/null; \
	  echo "    LiquidGlassKit: default.metallib 已编译并打入 bundle"; \
	else \
	  echo "    WARNING: LiquidGlassKit shader 编译失败（不影响其余功能）"; \
	fi; \
	rm -rf "$$BUILD"

INSTALL_TARGET_PROCESSES = SpringBoard backboardd

include $(THEOS_MAKE_PATH)/tweak.mk

# slot-modules：32 块快捷指令槽位 bundle（com.strive.echoreborn.shortcut.1 … .32）。
#
# 这是控制中心里快捷指令能显示的唯一正确做法：它们是**真实的 Control Center 模块**，
# 由系统控制中心自己摆放、分页、绘制；而不是让本插件去复刻控制中心的布局算术、画一块
# 系统并不认识的磁贴。1.0.x 之前丢掉了这层结构，只保留自绘磁贴，那正是「控制中心里
# 快捷指令不显示」的结构性原因。源码取自 CCAster 真实 0.5.6.24（commit b939d0d9ce）。
SUBPROJECTS += modules prefs slot-modules

# Soko (lock-screen widget/notification placement, from waruhachi/Soko 1.0.0-rc.1)
# and LiquidSiri (iOS 27 style glass Siri orb, from Thijs2004/LiquidSiri v1.1.2)
# are compiled straight into EchoReborn.dylib - see the note above EchoReborn_FILES.
# The .deb therefore ships exactly two dylibs again: EchoReborn.dylib and
# EchoRebornBackboardd.dylib.  Their settings pages are drawn by EchoRebornPrefs (see
# prefs/).  EchoReborn keeps its own domain "com.strive.echoreborn.preferences"
# (Soko keys keep a `soko_` prefix); the iOS27 Siri pane writes to
# "com.yourcompany.liquidsiri.prefs" with unprefixed keys, per the v7 spec.

# The seven standalone 连接 (Connectivity) Control Center bundles are built
# here again as part of the single EchoReborn package (reverted from the short-
# lived COSMIC Kit split at 0.3.15). See modules/Makefile (aggregate.mk over
# airplane/cellular/airdrop/hotspot/bluetooth/wifi/vpn). EchoReborn's Tweak.xm
# owns their visual presentation and the liquidass glass/rounding bridge.

include $(THEOS_MAKE_PATH)/aggregate.mk


# ---------------------------------------------------------------------------
# 1.0.5: the Sileo package icon path must follow the jailbreak scheme
# ---------------------------------------------------------------------------
# Sileo takes the `Icon:` value and hands it to its image loader **as a URL**; it
# does NOT prepend the jailbreak root (the control-file parser only lowercases
# the key, and the value goes straight into `URL(string:)`). So a single
# hard-coded absolute path can never be correct for both schemes, because the
# file physically lands somewhere different in each:
#
#   rootless  → /var/jb/Library/PreferenceBundles/EchoRebornPrefs.bundle/icon.png
#   roothide  → <randomised jbroot>/Library/PreferenceBundles/EchoRebornPrefs.bundle/icon.png
#
# roothide randomises the jbroot per device, so no literal `/var/jb` path can ever
# resolve there — and roothide exists precisely so that nothing can hard-code the
# path. Its Sileo is built jbroot-aware (that is the whole design), which is why
# the **jbroot-relative** form is the right value on roothide: it is also the
# form every other path inside a roothide .deb already uses.
#
# The two schemes therefore need two different strings while `control` can only
# hold one, so the value is rewritten inside the staging tree right before the
# .deb is assembled. `make package` runs: internal-package-check → stage →
# before-package → internal-package, and the deb rule makes
# `before-package` depend on the generated `$(THEOS_STAGING_DIR)/DEBIAN/control`,
# so the file is guaranteed to exist by the time this recipe runs.
ER_PACKAGE_ICON_RELATIVE = /Library/PreferenceBundles/EchoRebornPrefs.bundle/icon.png

ifeq ($(THEOS_PACKAGE_SCHEME),rootless)
ER_PACKAGE_ICON = file:///var/jb$(ER_PACKAGE_ICON_RELATIVE)
else
ER_PACKAGE_ICON = file://$(ER_PACKAGE_ICON_RELATIVE)
endif

before-package::
	@control="$(THEOS_STAGING_DIR)/DEBIAN/control"; \
	if [ -f "$$control" ]; then \
		/usr/bin/sed -i.bak -E 's|^Icon:.*$$|Icon: $(ER_PACKAGE_ICON)|' "$$control"; \
		rm -f "$$control.bak"; \
		echo "    package icon [$(THEOS_PACKAGE_SCHEME)]: $$(/usr/bin/grep '^Icon:' "$$control")"; \
	else \
		echo "    WARNING: $$control missing — package icon left untouched"; \
	fi
