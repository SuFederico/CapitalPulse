#!/bin/bash
# CapitalPulse 本地开发启动器：同时启动 API 与 Next.js 开发服务器。
set -u

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$BASE_DIR" || exit 1

api_pid=""
web_pid=""
stopping=0

is_alive() {
  [ -n "$1" ] && kill -0 "$1" 2>/dev/null
}

cleanup() {
  [ "$stopping" -eq 0 ] || return 0
  stopping=1
  trap - EXIT INT TERM
  for pid in "$api_pid" "$web_pid"; do
    if is_alive "$pid"; then
      kill "$pid" 2>/dev/null || true
    fi
  done
  wait "$api_pid" 2>/dev/null || true
  wait "$web_pid" 2>/dev/null || true
}

trap cleanup EXIT
trap 'cleanup; exit 0' INT TERM

python -m uvicorn main:app --app-dir ./backend --reload --port 8100 &
api_pid=$!
node frontend/node_modules/next/dist/bin/next dev frontend -p 3000 &
web_pid=$!

while [ "$stopping" -eq 0 ]; do
  sleep 1
  if [ -n "$api_pid" ] && ! is_alive "$api_pid"; then
    wait "$api_pid" 2>/dev/null || true
    exit 1
  fi
  if [ -n "$web_pid" ] && ! is_alive "$web_pid"; then
    wait "$web_pid" 2>/dev/null || true
    exit 1
  fi
done
