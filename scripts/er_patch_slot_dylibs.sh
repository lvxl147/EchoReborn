#!/bin/bash
# 1.2.2-159 · 构建期 roothide 依赖改写：把槽位 dylib 的绝对依赖路径
# 统一改写为 @loader_path/.jbroot/...（配合 bundle 内 .jbroot -> / 链接）。
set -e
cd ~/er174
DEPS=(
  "/usr/lib/libobjc.A.dylib"
  "/usr/lib/libSystem.B.dylib"
  "/System/Library/Frameworks/Foundation.framework/Foundation"
  "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation"
  "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics"
  "/System/Library/Frameworks/UIKit.framework/UIKit"
  "/System/Library/PrivateFrameworks/ControlCenterUIKit.framework/ControlCenterUIKit"
)
for n in $(seq 1 50); do
  BIN=".theos/obj/ERShortcut${n}Module.bundle/ERShortcut${n}Module"
  [ -f "$BIN" ] || continue
  for dep in "${DEPS[@]}"; do
    if otool -L "$BIN" | grep -q "^\s*${dep} "; then
      install_name_tool -change "$dep" "@loader_path/.jbroot${dep}" "$BIN" 2>/dev/null || true
    fi
  done
done
echo "dylib deps rewritten"
