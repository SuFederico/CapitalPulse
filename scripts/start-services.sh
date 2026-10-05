#!/bin/bash
# CapitalPulse 常驻服务监督器：前后端始终运行，任一进程异常退出时自动拉起。
set -u

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="${CAPITALPULSE_LOG_DIR:-$HOME/Library/Logs/CapitalPulse}"
SUPERVISOR_LOG="$LOG_DIR/supervisor.log"
API_LOG="$LOG_DIR/api.log"
WEB_LOG="$LOG_DIR/web.log"
PYTHON="${CAPITALPULSE_PYTHON:-/usr/local/Caskroom/miniconda/base/envs/capitalpulse/bin/python}"
NODE="${CAPITALPULSE_NODE:-/Users/fico/.nvm/versions/node/v24.18.0/bin/node}"
WEB_DIR="$BASE_DIR/frontend/.next/standalone/frontend"
WEB_SERVER="$WEB_DIR/server.js"

export PATH="/usr/local/Caskroom/miniconda/base/envs/capitalpulse/bin:/Users/fico/.bun/bin:/Users/fico/.nvm/versions/node/v24.18.0/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export TZ="Asia/Shanghai"
export VANE_API_URL="${VANE_API_URL:-http://127.0.0.1:8100}"

mkdir -p "$LOG_DIR"
cd "$BASE_DIR" || exit 1

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')" "$*" >> "$SUPERVISOR_LOG"
}

api_pid=""
web_pid=""
stopping=0

is_alive() {
  [ -n "$1" ] || return 1
  kill -0 "$1" 2>/dev/null || return 1
  case "$(ps -p "$1" -o stat= 2>/dev/null)" in
    Z*) return 1 ;;
  esac
}

start_api() {
  if [ ! -x "$PYTHON" ]; then
    log "API 未启动：Python 不存在或不可执行（$PYTHON）"
    return 1
  fi
  "$PYTHON" -m uvicorn main:app \
    --app-dir "$BASE_DIR/backend" \
    --host 0.0.0.0 \
    --port 8100 \
    >> "$API_LOG" 2>&1 &
  api_pid=$!
  log "API started pid=$api_pid"
}

ensure_web_assets() {
  if [ ! -e "$WEB_DIR/.next/static" ] && [ -d "$BASE_DIR/frontend/.next/static" ]; then
    ln -s "$BASE_DIR/frontend/.next/static" "$WEB_DIR/.next/static"
  fi
  if [ ! -e "$WEB_DIR/public" ] && [ -d "$BASE_DIR/frontend/public" ]; then
    ln -s "$BASE_DIR/frontend/public" "$WEB_DIR/public"
  fi
}

start_web() {
  if [ ! -x "$NODE" ]; then
    log "前端未启动：Node 不存在或不可执行（$NODE）"
    return 1
  fi
  if [ ! -f "$WEB_SERVER" ]; then
    log "前端未启动：Next.js standalone 构建不存在（$WEB_SERVER），请先执行 bun run build"
    return 1
  fi
  ensure_web_assets
  (
    cd "$WEB_DIR" || exit 1
    exec env NODE_ENV=production HOSTNAME=0.0.0.0 PORT=3000 VANE_API_URL="$VANE_API_URL" \
      "$NODE" server.js
  ) >> "$WEB_LOG" 2>&1 &
  web_pid=$!
  log "web started pid=$web_pid"
}

stop_pid() {
  local pid="$1"
  [ -n "$pid" ] || return 0
  if is_alive "$pid"; then
    kill "$pid" 2>/dev/null || true
    for _ in 1 2 3 4 5; do
      is_alive "$pid" || break
      sleep 1
    done
    if is_alive "$pid"; then
      kill -9 "$pid" 2>/dev/null || true
    fi
  fi
  wait "$pid" 2>/dev/null || true
}

cleanup() {
  [ "$stopping" -eq 0 ] || return 0
  stopping=1
  trap - EXIT INT TERM
  log "supervisor stopping"
  stop_pid "$api_pid"
  stop_pid "$web_pid"
}

trap cleanup EXIT
trap 'cleanup; exit 0' INT TERM

log "supervisor started"
start_api || true
start_web || true

while [ "$stopping" -eq 0 ]; do
  sleep 5

  if [ -z "$api_pid" ]; then
    start_api || true
  elif ! is_alive "$api_pid"; then
    wait "$api_pid" 2>/dev/null || true
    log "API exited; restarting"
    api_pid=""
    start_api || true
  fi

  if [ -z "$web_pid" ]; then
    start_web || true
  elif ! is_alive "$web_pid"; then
    wait "$web_pid" 2>/dev/null || true
    log "web exited; restarting"
    web_pid=""
    start_web || true
  fi
done
