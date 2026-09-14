#!/bin/bash
# build_native.sh - macOS 原生 .app 一键打包脚本
# 在 /Users/lihaidi/Downloads/Dev/报销整理Native/ 根目录运行
#   bash BuildScripts/build_native.sh

set -e

# 1. 定位 native/ 根目录
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
echo "→ native/ 根目录: $ROOT_DIR"
cd "$ROOT_DIR"

ARCHS="${ARCHS:-$(uname -m)}"
echo "→ 目标架构: $ARCHS"

echo ""
echo "=== 步骤 1: xcodebuild 出 SwiftUI 壳 ==="
if [ ! -d "ReimbursementNative.xcodeproj" ]; then
    echo "  ⚠️  Xcode 项目不存在，请跑 xcodegen generate 后重试"
    exit 1
fi
xcodebuild \
    -project ReimbursementNative.xcodeproj \
    -scheme ReimbursementNative \
    -configuration Release \
    -derivedDataPath "$ROOT_DIR/BuildAssets/temp_build" \
    ARCHS="$ARCHS" \
    ONLY_ACTIVE_ARCH=NO \
    build

APP_PATH="$ROOT_DIR/BuildAssets/temp_build/Build/Products/Release/报销整理.app"
if [ ! -d "$APP_PATH" ]; then
    echo "  ❌ xcodebuild 失败：$APP_PATH 不存在"
    exit 1
fi
echo "  ✓ $APP_PATH ($(du -sh "$APP_PATH" | cut -f1))"

echo ""
echo "=== 步骤 2: ad-hoc 签名 ==="
if codesign --force --deep --options runtime \
    --entitlements "$ROOT_DIR/Sources/ReimbursementNative.entitlements" \
    "$APP_PATH" >/dev/null 2>&1; then
    echo "  ✓ 签名成功（ad-hoc）"
else
    # 退回到最简签名（无 entitlements、无 hardened runtime）
    codesign --force --deep --sign - "$APP_PATH" >/dev/null 2>&1 && \
        echo "  ✓ 签名成功（ad-hoc 简化）" || \
        echo "  ⚠️  签名失败（仍可本地运行）"
fi
codesign -dv "$APP_PATH" 2>&1 | grep -E "Identifier|Format|Signature" | head -3

echo ""
echo "=== 步骤 3: 打 dmg ==="
DMG_PATH="$ROOT_DIR/报销整理.dmg"
hdiutil create -volname "报销整理" \
    -srcfolder "$APP_PATH" \
    -ov -format UDZO "$DMG_PATH" 2>&1 | tail -2
echo "  ✓ $DMG_PATH ($(du -h "$DMG_PATH" | cut -f1))"

echo ""
echo "✅ 打包完成"
echo "   .app: $APP_PATH"
echo "   .dmg: $DMG_PATH"
echo ""
echo "下一步：open \"$APP_PATH\" 或 open \"$DMG_PATH\""
