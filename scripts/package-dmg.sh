#!/bin/zsh
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' DockFolder/Info.plist)"
zsh "scripts/build.sh" "build/PackageDerivedData"
mkdir -p "dist" "build"
stage="$(mktemp -d "$project_root/build/DMGStage.XXXXXX")"
ditto "build/Release/DockFolder.app" "$stage/DockFolder.app"
ln -s "/Applications" "$stage/Applications"
cat > "$stage/安装说明.txt" <<'TEXT'
DockNest · macOS 26 应用文件夹

1. 先退出正在运行的旧版文件夹入口。
2. 将 DockFolder.app 拖到 Applications（应用程序）。
3. 从「应用程序」打开 DockFolder。
4. 右键 Dock 图标 → 选项 → 在程序坞中保留。
5. 从 2.3 及更早版本升级：将旧图标从 Dock 移除，再将对应 .app 拖回 Dock 一次，让系统加载新的图标插件。这不会删除文件夹或列表。
6. 多开文件夹和改过名的入口不会被安装包自动替换。新版首次启动若提示「发现旧版入口」，点「前往更新」→「全部更新」即可，名称和应用列表都会保留。
7. 主入口改过名（例如「远程工具.app」）时，更新后管理页会提示同一文件夹有两个入口：选「改用 远程工具」即可只保留原来那份，安装用的 DockFolder.app 会移到废纸篓。

右上角 … 菜单：
• 设置：独立控制本文件夹开机自启动，查看 Dock 圆点的系统设置说明；导出或导入此文件夹的应用列表备份（可合并或替换）。
• 修改应用名称：名称会同时显示在窗口与 Dock 中。
• 新建独立文件夹：每个文件夹独立运行、独立 Dock 图标。
• 管理多开文件夹：打开、找回被移到废纸篓的入口、更新旧版入口、删除多开数据。

误删 .app 不会删除应用列表，管理页的「恢复并打开」可重建入口。
已有旧版多开：在管理页对应条目的 … 中选择「更新到当前版本并打开」。
删除数据需要再次确认；不会卸载快捷方式指向的原应用。
窗口默认完整显示 3 行、每行 5 个图标。
按住图标拖动即可调整顺序，松手自动保存；拖到上下边缘会自动滚动。
退出时自动将前四个应用的缩略图保存为静态图标；未启动时也能显示。
Dock 图标插件读取同一份缓存，未运行时也保留大号蓝色文件夹外观。
Finder 中的静态图标仍由系统处理，可能带有 macOS 26 的灰色底板。
只关闭窗口会保留后台进程，若要去掉运行圆点，请选择「退出此文件夹」。

本机 ad-hoc 签名版本，未经过 Apple Developer ID 公证。
应用列表保存在用户的 Application Support/DockFolder 目录，安装包不包含个人列表。
TEXT
codesign --verify --deep --strict "$stage/DockFolder.app"
/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$stage/DockFolder.app/Contents/Info.plist" | /usr/bin/grep -qx "com.dalong.DockFolder"
/usr/libexec/PlistBuddy -c "Print :CFBundleName" "$stage/DockFolder.app/Contents/Info.plist" | /usr/bin/grep -qx "DockFolder"
hdiutil create -volname "DockNest $version" -srcfolder "$stage" -format UDZO -ov "dist/DockNest-${version}-macOS-arm64.dmg"
hdiutil verify "dist/DockNest-${version}-macOS-arm64.dmg"
shasum -a 256 "dist/DockNest-${version}-macOS-arm64.dmg" > "dist/DockNest-${version}-macOS-arm64.dmg.sha256"
print "安装包：$project_root/dist/DockNest-${version}-macOS-arm64.dmg"
