#!/bin/zsh
set -euo pipefail
plugin="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/PlugIns/DockFolderTile.docktileplugin"
mkdir -p "$plugin/Contents/MacOS"
cp "$SRCROOT/DockTilePlugin/Info.plist" "$plugin/Contents/Info.plist"
arch_flags=()
for architecture in ${=ARCHS}; do
    arch_flags+=(-arch "$architecture")
done
xcrun clang -bundle -fobjc-arc -fblocks -framework AppKit \
    -isysroot "$SDKROOT" -mmacosx-version-min="$MACOSX_DEPLOYMENT_TARGET" \
    "${arch_flags[@]}" "$SRCROOT/DockTilePlugin/DockTilePlugin.m" \
    -o "$plugin/Contents/MacOS/DockFolderTile"
codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" --options runtime "$plugin"
