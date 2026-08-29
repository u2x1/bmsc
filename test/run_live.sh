#!/usr/bin/env bash
# 一键 live 集成测试（人工介入最小化）
#
# 行为：
#   1. 已有缓存登录态（test/credentials/live_session.json，约 180 天有效）→ 全自动跑
#   2. 无缓存/已失效 → 提示并进入扫码模式：手机 App 扫一次二维码即完成登录，
#      登录态自动缓存，此后全自动
#
# 用法：
#   flutter test/test/run_live.sh            # 常规
#   BMSC_LOGIN=1 flutter test/test/run_live.sh   # 强制重新扫码（换账号等）
#
# CI / 无终端环境：不进入扫码模式，登录态用例自动降级；可设 BMSC_COOKIE 提供登录态。
set -euo pipefail
cd "$(dirname "$0")/.."

export BMSC_LIVE=1

# 无缓存登录态且未显式提供 cookie -> 允许扫码（有终端时才真正交互）
if [ ! -f test/credentials/live_session.json ] && [ -z "${BMSC_COOKIE:-}" ]; then
  if [ -t 1 ] || [ "${BMSC_LOGIN:-0}" = "1" ]; then
    echo ">> 未找到缓存登录态，将尝试扫码登录（仅首次需要，登录一次后自动复用）"
    export BMSC_LOGIN=1
  else
    echo ">> 无缓存登录态且无终端（CI?）。登录态用例将降级。设 BMSC_COOKIE 可提供登录态。"
  fi
fi

exec flutter test test/integration "${@}"