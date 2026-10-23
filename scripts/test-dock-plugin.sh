#!/bin/zsh
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
mkdir -p "build"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" xcrun swiftc \
    "DockFolder/Library.swift" "DockFolder/FolderInstance.swift" \
    "DockFolder/InstanceCatalog.swift" "DockFolder/DockIcon.swift" \
    "scripts/VerifyDockPlugin.swift" -o "build/verify-plugin"
"build/verify-plugin" "${1:-build/Release/DockFolder.app}"
