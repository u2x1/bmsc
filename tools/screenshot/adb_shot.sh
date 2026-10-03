#!/bin/zsh
# 截屏到 tools/screenshot 目录
# Usage: adb_shot.sh <name>
set -e
cd "$(dirname "$0")"
ADB=/opt/homebrew/share/android-commandlinetools/platform-tools/adb
"$ADB" -s 4t89qge6twivirzx exec-out screencap -p > "$1.png"
echo "saved $1.png ($(stat -f%z "$1.png") bytes)"
