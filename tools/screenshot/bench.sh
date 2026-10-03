#!/bin/zsh
# 播放列表场景帧耗时 bench：后台采集 Flutter.Frame 事件，同时执行 adb 操作
# Usage: bench.sh <ws-uri> <label> <adb args...>
# 例: bench.sh ws://127.0.0.1:52945/xxx=/ws open_sheet -s 4t89qge6twivirzx shell input tap 968 2186
set -e
cd "$(dirname "$0")"
WS=$1; LABEL=$2; shift 2
ADB=/opt/homebrew/share/android-commandlinetools/platform-tools/adb

dart vm_timeline.dart "$WS" 3500 "$LABEL" &
TIMELINE_PID=$!
# vm_timeline 启动后先回放/排空缓存（约 1.5s），等排空完再触发操作
sleep 1.9
"$ADB" "$@"
wait $TIMELINE_PID
