#!/bin/bash
# release_macos.sh - 报销整理 macOS 版 Sparkle 发版一条龙
# 在仓库根目录运行：bash BuildScripts/release_macos.sh 2.1.1
#
# 本脚本完成：改版本号 → 调 build_native.sh 构建并打 DMG → 归档 →
# generate_appcast 生成带签名的 appcast.xml 与增量包 → 增量包改 ASCII 名 →
# 若本机装有 ossutil 并配好密钥，自动上传到阿里云 OSS（appcast 最后传）；
# 否则打印剩余手动步骤。
#
# 前置条件（见 BuildScripts/SPARKLE-RELEASE.md）：
# - Sparkle 私钥已在本机钥匙串（generate_keys 生成）；
# - Sparkle 工具包已解压：设环境变量 SPARKLE_TOOLS 指向其目录，
#   或放在 ~/Downloads/Sparkle-2.10.1（脚本自动找）；
# - 归档目录长期保留全部历史版本（增量包靠它生成），默认 ~/SparkleArchives，
#   可用 SPARKLE_ARCHIVES 覆盖。
set -euo pipefail

VERSION="${1:?用法: bash BuildScripts/release_macos.sh <版本号，如 2.1.1>}"
IFS='.' read -r MAJ MIN PAT <<< "$VERSION"
if [ -z "${PAT:-}" ] || [ "$MIN" -gt 9 ] || [ "$PAT" -gt 9 ]; then
    echo "错误: 版本号须为 X.Y.Z 且 Y、Z 均为个位数（构建号规则: X*100+Y*10+Z）" >&2
    exit 1
fi
BUILD_NUM=$((MAJ * 100 + MIN * 10 + PAT))
TAG="v$VERSION"

MARKER="$(mktemp)"
trap 'rm -f "$MARKER"' EXIT
sleep 1

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
echo "→ 仓库根目录: $ROOT_DIR"
echo "→ 版本: ${VERSION}（构建号 ${BUILD_NUM}，标签 ${TAG}）"

echo ""
echo "=== 步骤 1: 写版本号到 Sources/Info.plist ==="
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Sources/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUM" Sources/Info.plist
echo "  完成: CFBundleShortVersionString=$VERSION, CFBundleVersion=$BUILD_NUM"
echo "  （记得把 Info.plist 的这次改动随分支提交）"

echo ""
echo "=== 步骤 2: 构建并打 DMG ==="
bash BuildScripts/build_native.sh
DMG_SRC="$ROOT_DIR/报销整理.dmg"
[ -f "$DMG_SRC" ] || { echo "错误: 未找到 ${DMG_SRC}，构建可能失败" >&2; exit 1; }

echo ""
echo "=== 步骤 3: 归档（ASCII 文件名，GitHub 会剥掉资产名里的中文） ==="
ARCHIVE_DIR="${SPARKLE_ARCHIVES:-$HOME/SparkleArchives}"
mkdir -p "$ARCHIVE_DIR"
ARCHIVE_NAME="Reimbursement-$VERSION.dmg"
cp "$DMG_SRC" "$ARCHIVE_DIR/$ARCHIVE_NAME"
echo "  完成: $ARCHIVE_DIR/$ARCHIVE_NAME"

echo ""
echo "=== 步骤 4: generate_appcast（签名 + 生成增量包） ==="
GA=""
for d in "${SPARKLE_TOOLS:-}" "$HOME/Downloads/Sparkle-2.10.1" "$HOME/Sparkle-2.10.1"; do
    if [ -n "$d" ] && [ -x "$d/bin/generate_appcast" ]; then GA="$d/bin/generate_appcast"; break; fi
done
[ -n "$GA" ] || { echo "错误: 找不到 Sparkle 工具包的 bin/generate_appcast，请设 SPARKLE_TOOLS 环境变量指向解压目录" >&2; exit 1; }
echo "  使用工具: $GA"
# 更新包与 feed 统一托管在阿里云 OSS（Bucket: reimbursment-macosupdate，华东2·上海）。
# generate_appcast 按「一个目录 = 一个下载前缀」设计，前缀必须固定，不能按版本变。
OSS_BASE="https://reimbursment-macosupdate.oss-cn-shanghai.aliyuncs.com"
"$GA" --download-url-prefix "$OSS_BASE/" "$ARCHIVE_DIR"
echo "  完成: appcast 与增量包已生成于 $ARCHIVE_DIR"

echo ""
echo "=== 步骤 5: 增量包改 ASCII 名并修正 appcast 地址 ==="
# generate_appcast 用应用名给 delta 命名（带中文），统一改成纯 ASCII 名，
# 并把 appcast 里对应的（百分号编码的）下载地址同步改掉，避免各托管方的编码差异。
python3 - "$ARCHIVE_DIR" <<'PYEOF'
import os, sys, urllib.parse
d = sys.argv[1]
cast_path = os.path.join(d, "appcast.xml")
cast = open(cast_path, encoding="utf-8").read()
for name in os.listdir(d):
    if name.endswith(".delta") and any(ord(c) > 127 for c in name):
        new = "".join(c for c in name if ord(c) < 128)
        os.rename(os.path.join(d, name), os.path.join(d, new))
        cast = cast.replace(urllib.parse.quote(name), new)
        print("  delta 改名: " + new)
open(cast_path, "w", encoding="utf-8").write(cast)
print("  完成: appcast 地址已同步")
PYEOF

NEW_FILES="$(find "$ARCHIVE_DIR" -type f -newer "$MARKER" ! -name appcast.xml -exec basename {} \; | sort -u)"
rm -f "$MARKER"

echo ""
echo "=== 步骤 6: 上传到 OSS（更新包先传，appcast 最后传） ==="
OSSUTIL=""
for c in ossutil ossutil64; do
    if command -v "$c" >/dev/null 2>&1; then OSSUTIL="$c"; break; fi
done
UPLOADED=0
if [ -n "$OSSUTIL" ] && "$OSSUTIL" ls "oss://reimbursment-macosupdate/" >/dev/null 2>&1; then
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        "$OSSUTIL" cp "$ARCHIVE_DIR/$f" "oss://reimbursment-macosupdate/$f" -f
        echo "  已上传: $f"
    done <<< "$NEW_FILES"
    "$OSSUTIL" cp "$ARCHIVE_DIR/appcast.xml" "oss://reimbursment-macosupdate/appcast.xml" -f
    echo "  已上传: appcast.xml"
    UPLOADED=1
else
    echo "  未检测到可用的 ossutil（或其密钥未配置），跳过自动上传，见下方手动步骤。"
fi

cat <<EOF

==============================================================
$(if [ "$UPLOADED" = "1" ]; then echo "上传已由脚本完成，只剩验证："; else echo "自动部分完成。剩下手动的事："; fi)

$(if [ "$UPLOADED" != "1" ]; then cat <<'MANUAL'
[1] 把下列本版新增文件上传到 OSS Bucket reimbursment-macosupdate 的根目录
    （控制台或 ossutil 均可，不要删旧文件）
MANUAL
echo "$NEW_FILES"
echo ""
echo "[2] 再把归档目录里的 appcast.xml 也传到该 Bucket 根目录（务必在 [1] 之后）"
echo ""
fi)
[验证] 启动一个已安装的旧版本，菜单「报销整理 → 检查更新…」
       应能发现 ${VERSION} 并完成下载、重启更新。DMG（${DMG_SRC}）
       仍可作为首次安装包分发。
==============================================================
EOF
