#!/bin/zsh
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
xcode_developer="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
DEVELOPER_DIR="$xcode_developer" "$xcode_developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift" test
