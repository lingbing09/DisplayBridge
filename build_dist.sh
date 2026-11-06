#!/bin/bash
# ============================================================
#  DisplayBridge 分发包构建脚本
#
#  从源码完整构建：编译主程序 + 内置工具 → 组装 .app → ad-hoc 签名 → 打 zip
#  不依赖本机任何既有安装，clone 下来即可构建。
#
#  用法：
#    bash build_dist.sh                      # 默认 arm64，版本取自 Info.plist
#    VERSION=1.3 BUILD=4 bash build_dist.sh  # 指定版本
#    ARCH=x86_64 bash build_dist.sh          # Intel 构建
# ============================================================

set -euo pipefail

PROJ_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJ_DIR"

APP_NAME="DisplayBridge"

# 版本默认沿用 Info.plist，可用环境变量覆盖
VERSION="${VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist 2>/dev/null || echo 1.2)}"
BUILD="${BUILD:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Info.plist 2>/dev/null || echo 1)}"
ARCH="${ARCH:-$(uname -m)}"
TARGET="${TARGET:-${ARCH}-apple-macosx13.0}"

MIN_MACOS="13.0"

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

DIST="$PROJ_DIR/dist"
mkdir -p "$DIST"

echo "── 1/6 编译主程序（${TARGET}）──"
swiftc -O -target "$TARGET" \
    -framework SwiftUI -framework AppKit -framework CoreGraphics -framework IOKit \
    -o "$STAGING/$APP_NAME" DisplayBridge.swift

echo "── 2/6 编译内置工具 ──"
swiftc -O -target "$TARGET" -framework CoreGraphics -framework AppKit \
    -o "$STAGING/get_virtual_display" get_virtual_display.swift
swiftc -O -target "$TARGET" -framework AppKit \
    -o "$STAGING/sidecar_toggle" sidecar_toggle.swift

echo "── 3/6 组装 .app ──"
APP="$STAGING/$APP_NAME.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/scripts"

if [ ! -f "$PROJ_DIR/Info.plist" ]; then
    echo "❌ 缺少 Info.plist" >&2; exit 1
fi
cp "$PROJ_DIR/Info.plist" "$APP/Contents/Info.plist"

if [ -f "$PROJ_DIR/AppIcon.icns" ]; then
    cp "$PROJ_DIR/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

cp "$STAGING/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
chmod +x "$APP/Contents/MacOS/$APP_NAME"

# 写入本次构建的版本号
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $BUILD" "$APP/Contents/Info.plist"

echo "── 4/6 内置脚本与工具 ──"
cp "$STAGING/get_virtual_display" "$APP/Contents/Resources/scripts/"
cp "$STAGING/sidecar_toggle" "$APP/Contents/Resources/scripts/"

for f in ipad_sidecar_start_silent.sh \
         ipad_sidecar_stop_silent.sh \
         sidecar_ui_connect.scpt \
         sidecar_ui_connect.applescript; do
    if [ -f "$PROJ_DIR/$f" ]; then
        cp "$PROJ_DIR/$f" "$APP/Contents/Resources/scripts/"
    else
        echo "⚠️  缺少 $f（相关功能可能不可用）" >&2
    fi
done
chmod +x "$APP/Contents/Resources/scripts/"* 2>/dev/null || true

echo "── 5/6 签名 ──"
xattr -cr "$APP"
codesign --force --deep --sign - "$APP"

echo "── 6/6 生成安装说明并打包 ──"
cat > "$STAGING/安装说明.txt" << EOF
DisplayBridge — Mac 一键连接 iPad 副屏
==========================================

【这是什么】
极简小窗工具，三种连接方式：
· 原生随航（Sidecar）：Mac 自带，无需安装任何第三方软件
· 串流副屏（BetterDisplay + Sunshine）：跨网络、低延迟，iPad 端用 Moonlight 连接
· OpenDisplay：越狱 iPad 上稳定低延迟的扩展屏方案

【安装】
1. 把 DisplayBridge.app 拖入「应用程序」文件夹
2. 首次打开：右键 →「打开」（绕过 Gatekeeper）
   若仍被拦，终端执行：xattr -cr /Applications/DisplayBridge.app
3. 打开后到「设置 → 依赖」检查依赖是否齐全

【依赖（按需安装）】
· 只用原生随航：不需要任何依赖
· 用串流副屏：
  - BetterDisplay  https://betterdisplay.pro （免费版即可，需创建名为 display 的虚拟屏）
  - Sunshine       https://app.lizardbyte.dev/Sunshine/ （装完先手动打开一次完成初始化）
  - iPad 端 Moonlight（App Store）
· 用 OpenDisplay：
  - OpenDisplay    https://github.com/peetzweg/OpenSidecar
  - iPad 端需越狱并安装配套客户端

【首次配置：串流副屏】
1. BetterDisplay 新建虚拟显示器，名称保持默认 display
   （改了名字也没关系，到 设置 → 依赖 → 虚拟屏名称 改成一致即可）
2. 手动打开一次 Sunshine，设置 Web UI 用户名和密码
3. 回到 DisplayBridge：设置 → Web UI，填入同样的账号密码并保存
4. 主界面点「连接副屏」，等待虚拟屏和 Sunshine 启动
5. iPad 打开 Moonlight → 连接这台 Mac → 记下显示的 PIN
   → 设置 → 串流 → 设备配对，输入 PIN 并发送（只需配对一次）

【权限】
· 连接方式选「系统设置界面」时，需要到
  系统设置 → 隐私与安全性 → 辅助功能 → 勾选 DisplayBridge
· 首次连接如弹出自动化授权，点「允许」

【环境要求】
macOS ${MIN_MACOS} 及以上；当前构建架构：${ARCH}
EOF

mkdir -p "$STAGING/pack"
mv "$APP" "$STAGING/pack/"
cp "$STAGING/安装说明.txt" "$STAGING/pack/"
cp "$STAGING/安装说明.txt" "$DIST/安装说明.txt" 2>/dev/null || true

ZIP="$DIST/${APP_NAME}-${VERSION}-${ARCH}-macOS.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$STAGING/pack" "$ZIP"

echo "✅ 完成：$ZIP"
ls -lh "$ZIP"
