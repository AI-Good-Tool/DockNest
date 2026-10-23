#!/bin/zsh
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
build_root="${1:-build/DerivedData}"
xcode_developer="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
if [[ ! -x "$xcode_developer/usr/bin/xcodebuild" ]]; then
    print -u2 "未找到 Xcode。请安装 Xcode，或通过 DEVELOPER_DIR 指定 Xcode Developer 目录。"
    exit 1
fi
DEVELOPER_DIR="$xcode_developer" "$xcode_developer/usr/bin/xcodebuild" \
    -project "DockFolder.xcodeproj" -scheme DockFolder -configuration Release \
    -derivedDataPath "$build_root" ARCHS=arm64 ONLY_ACTIVE_ARCH=NO build
mkdir -p "build/Release"
ditto "$build_root/Build/Products/Release/DockFolder.app" "build/Release/DockFolder.app"
print "构建完成：$project_root/build/Release/DockFolder.app"
