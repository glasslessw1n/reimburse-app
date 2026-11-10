#!/bin/bash
# release_macos.sh - 报销整理 macOS 版 Sparkle 发版一条龙
# 在仓库根目录运行：bash BuildScripts/release_macos.sh 2.1.1
#
# 本脚本完成：改版本号 → 调 build_native.sh 构建并打 DMG → 归档 →
# generate_appcast 生成带签名的 appcast.xml 与增量包 → 打印剩余手动步骤
# （上传到 GitHub 的 macos-updates 永久 Release、把 appcast.xml 推到 main）。
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

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
echo "→ 仓库根目录: $ROOT_DIR"
echo "→ 版本: $VERSION（构建号 $BUILD_NUM，标签 $TAG）"

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
[ -f "$DMG_SRC" ] || { echo "错误: 未找到 $DMG_SRC，构建可能失败" >&2; exit 1; }

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
MARKER="$(mktemp)"
sleep 1
# 所有版本的更新包都挂在同一个永久 Release（标签 macos-updates）下，
# generate_appcast 按「一个目录 = 一个下载前缀」设计，前缀必须固定，不能按版本变。
"$GA" --download-url-prefix "https://github.com/glasslessw1n/reimburse-app/releases/download/macos-updates/" "$ARCHIVE_DIR"
echo "  完成: appcast 与增量包已生成于 $ARCHIVE_DIR"

NEW_FILES="$(find "$ARCHIVE_DIR" -type f -newer "$MARKER" ! -name appcast.xml -exec basename {} \; | sort -u)"
rm -f "$MARKER"

cat <<EOF

==============================================================
自动部分完成。剩下三件手动的事：

[1] 把下列本版新增文件上传到 GitHub 的 macos-updates Release
    （该 Release 只建一次：标签 macos-updates，标题随意；
      之后每个版本都往它里面追加文件，不要删旧文件）
$NEW_FILES

[2] 把 appcast.xml 推到 main（先传完 [1] 再推，顺序不要反）
      git checkout main && git pull
      cp "$ARCHIVE_DIR/appcast.xml" ./appcast.xml
      git add appcast.xml && git commit -m "发布 Sparkle appcast $VERSION" && git push
      git checkout -

[3] 验证：启动一个已安装的旧版本，菜单「报销整理 → 检查更新…」
    应能发现 $VERSION 并完成下载、重启更新。DMG（$DMG_SRC）
    仍可作为首次安装包分发；需要的话也可以在 GitHub 另建 $TAG
    的版本 Release 把它挂上去，那与自动更新无关，纯供人下载。
==============================================================
EOF
