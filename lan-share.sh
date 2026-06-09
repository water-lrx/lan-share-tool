#!/bin/sh
set -eu

LABEL="local.lan-share"
TOOL_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
APP_SUPPORT_DIR="$HOME/Library/Application Support/LANShare"
CONFIG_FILE="$APP_SUPPORT_DIR/config.env"
[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"
PORT="${LAN_SHARE_PORT:-8000}"
SOURCE_DIR="${LAN_SHARE_SOURCE:-$HOME/Desktop/share}"
SHARE_DIR="${LAN_SHARE_DIR:-$HOME/Public/share}"
SERVER_SCRIPT="$APP_SUPPORT_DIR/share_server.rb"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
OUT_LOG="/tmp/$LABEL.out.log"
ERR_LOG="/tmp/$LABEL.err.log"

usage() {
  cat <<EOF
Usage: $(basename "$0") <command>

Commands:
  setup        Create share directory, install auto-start service, and start it
  start        Start the local HTTP file share
  stop         Stop the local HTTP file share
  restart      Restart the local HTTP file share
  status       Show service status and access URLs
  sync         Copy files from $SOURCE_DIR to $SHARE_DIR
  uninstall    Stop and remove the auto-start service

Environment:
  LAN_SHARE_PORT=8000
  LAN_SHARE_DIR=$HOME/Public/share
  LAN_SHARE_SOURCE=$HOME/Desktop/share
EOF
}

uid() {
  id -u
}

ip_addresses() {
  for iface in en0 en1; do
    ipconfig getifaddr "$iface" 2>/dev/null || true
  done | awk 'NF && !seen[$0]++'
}

ensure_share_dir() {
  mkdir -p "$SHARE_DIR"
  chmod 755 "$SHARE_DIR"
}

install_server_script() {
  mkdir -p "$APP_SUPPORT_DIR"
  cp "$TOOL_DIR/share_server.rb" "$SERVER_SCRIPT"
  chmod 644 "$SERVER_SCRIPT"
}

write_plist() {
  mkdir -p "$HOME/Library/LaunchAgents"
  install_server_script
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/ruby</string>
    <string>$SERVER_SCRIPT</string>
  </array>
  <key>WorkingDirectory</key>
  <string>$APP_SUPPORT_DIR</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>LAN_SHARE_DIR</key>
    <string>$SHARE_DIR</string>
    <key>LAN_SHARE_PORT</key>
    <string>$PORT</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$OUT_LOG</string>
  <key>StandardErrorPath</key>
  <string>$ERR_LOG</string>
</dict>
</plist>
EOF
  plutil -lint "$PLIST" >/dev/null
}

bootout() {
  launchctl bootout "gui/$(uid)" "$PLIST" 2>/dev/null || true
}

bootstrap() {
  launchctl bootstrap "gui/$(uid)" "$PLIST"
  launchctl enable "gui/$(uid)/$LABEL"
  launchctl kickstart -k "gui/$(uid)/$LABEL"
}

clear_logs() {
  : > "$OUT_LOG"
  : > "$ERR_LOG"
}

is_running() {
  curl -fsS --max-time 1 "http://127.0.0.1:$PORT/" >/dev/null 2>&1
}

wait_until_running() {
  tries=0
  while [ "$tries" -lt 10 ]; do
    if is_running; then
      return 0
    fi
    tries=$((tries + 1))
    sleep 1
  done
  return 1
}

sync_files() {
  ensure_share_dir
  if [ ! -d "$SOURCE_DIR" ]; then
    echo "Source directory does not exist: $SOURCE_DIR"
    echo "Put files directly in: $SHARE_DIR"
    return 0
  fi
  rsync -a "$SOURCE_DIR/" "$SHARE_DIR/"
  echo "Synced files from:"
  echo "  $SOURCE_DIR"
  echo "to:"
  echo "  $SHARE_DIR"
}

start_service() {
  ensure_share_dir
  write_plist
  bootout
  clear_logs
  bootstrap
  wait_until_running || true
  show_status
}

stop_service() {
  bootout
  echo "Stopped $LABEL"
}

show_status() {
  echo "Share directory:"
  echo "  $SHARE_DIR"
  echo
  echo "Access URLs:"
  ips="$(ip_addresses)"
  if [ -n "$ips" ]; then
    echo "$ips" | while IFS= read -r ip; do
      echo "  http://$ip:$PORT"
    done
  else
    echo "  No LAN IP detected. Check Wi-Fi/network connection."
  fi
  echo
  if is_running; then
    echo "Status: running on port $PORT"
  else
    echo "Status: not responding on port $PORT"
  fi
  echo
  echo "Recent errors:"
  if [ -s "$ERR_LOG" ] && grep -E 'ERROR|Errno|Exception|Traceback|Address already in use' "$ERR_LOG" >/dev/null 2>&1; then
    grep -E 'ERROR|Errno|Exception|Traceback|Address already in use' "$ERR_LOG" | tail -10
  else
    echo "  none"
  fi
}

case "${1:-}" in
  setup)
    sync_files
    start_service
    ;;
  start)
    start_service
    ;;
  stop)
    stop_service
    ;;
  restart)
    stop_service
    start_service
    ;;
  status)
    show_status
    ;;
  sync)
    sync_files
    ;;
  uninstall)
    stop_service
    rm -f "$PLIST"
    echo "Removed $PLIST"
    ;;
  -h|--help|help|"")
    usage
    ;;
  *)
    echo "Unknown command: $1" >&2
    usage >&2
    exit 2
    ;;
esac
