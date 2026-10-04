#!/usr/bin/env bash
# ghidra-mcp - control the shared Ghidra MCP server (pyghidra-mcp over streamable HTTP).
#
# One long-running server holds the Ghidra project and every coding agent connects to
# the same URL (default http://127.0.0.1:8000/mcp): a single JVM, no project-lock
# fights between agents, and every agent sees the same renames and comments.
#
# Usage:
#   ghidra-mcp status               is the server up? (default)
#   ghidra-mcp start | stop | restart
#   ghidra-mcp logs [N]             tail the server log (default 100 lines)
#   ghidra-mcp url                  print the MCP endpoint
#   ghidra-mcp selftest [ARGS]      import, analyze, decompile and search a harmless binary end to end
#   ghidra-mcp gui                  run with the Ghidra GUI attached (headless server restarts on exit)
#   ghidra-mcp run                  foreground server (used by launchd)
#   ghidra-mcp install-launchagent  start automatically at login
#   ghidra-mcp remove-launchagent
#   ghidra-mcp launchagent-plist    print the LaunchAgent definition without installing it
#
# Settings live in ~/.agents/ghidra/ghidra.env (sourced as shell, KEY=value lines), so the
# LaunchAgent sees them too:
#   GHIDRA_INSTALL_DIR JAVA_HOME GHIDRA_MCP_HOST GHIDRA_MCP_PORT
#   GHIDRA_MCP_PROJECT_DIR GHIDRA_MCP_PROJECT_NAME PYGHIDRA_MCP_BIN
#   GHIDRA_MCP_SYMBOLS=1       allow PDB lookups on public symbol servers (Microsoft, Mozilla, Chromium);
#                              off by default so analysis never fetches files or leaks PDB IDs on its own
#   GHIDRA_MCP_ALLOW_REMOTE=1  allow a non-loopback GHIDRA_MCP_HOST. The server has no authentication.
# GHIDRA_MCP_HOME (environment only) relocates this folder; the default is ~/.agents/ghidra.

set -u

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
GHIDRA_MCP_HOME="${GHIDRA_MCP_HOME:-$HOME/.agents/ghidra}"
ENV_FILE="$GHIDRA_MCP_HOME/ghidra.env"
if [ -f "$ENV_FILE" ]; then
  # shellcheck disable=SC1090
  . "$ENV_FILE"
fi

HOST="${GHIDRA_MCP_HOST:-127.0.0.1}"
PORT="${GHIDRA_MCP_PORT:-8000}"
case "$PORT" in ''|*[!0-9]*) echo "ghidra-mcp: GHIDRA_MCP_PORT must be a number, got '$PORT'" >&2; exit 2 ;; esac
# Ghidra rejects project paths that contain a dot-directory (such as ~/.agents/...), so the
# project lives in a normal home folder instead.
PROJECT_DIR="${GHIDRA_MCP_PROJECT_DIR:-$HOME/ghidra-projects}"
PROJECT_NAME="${GHIDRA_MCP_PROJECT_NAME:-agents}"
BIN="${PYGHIDRA_MCP_BIN:-$HOME/.local/bin/pyghidra-mcp}"
if [ "${GHIDRA_MCP_SYMBOLS:-0}" = "1" ]; then SYMBOL_FLAG="--with-symbols"; else SYMBOL_FLAG="--no-symbols"; fi
LOG_DIR="$GHIDRA_MCP_HOME/logs"
LOG_FILE="$LOG_DIR/server.log"
PID_FILE="$GHIDRA_MCP_HOME/server.pid"
LABEL="local.ghidra-macos-natives.ghidra-mcp"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"
case "$HOST" in *:*) URL="http://[$HOST]:$PORT/mcp" ;; *) URL="http://$HOST:$PORT/mcp" ;; esac

usage() { sed -n '2,/^$/p' "$SELF"; }

find_ghidra() {
  local candidate
  if [ -n "${GHIDRA_INSTALL_DIR:-}" ]; then
    [ -x "$GHIDRA_INSTALL_DIR/ghidraRun" ]
    return
  fi
  # Globs expand in sorted order, so the last valid match is the newest version.
  for candidate in "$HOME"/Applications/ghidra_*_PUBLIC; do
    if [ -x "$candidate/ghidraRun" ]; then GHIDRA_INSTALL_DIR="$candidate"; fi
  done
  [ -n "${GHIDRA_INSTALL_DIR:-}" ]
}

java_major() {
  local version major
  version="$("$1/bin/java" -version 2>&1 | sed -n 's/.*version "\([0-9][0-9.]*\).*/\1/p' | head -1)"
  major="${version%%.*}"
  if [ "$major" = "1" ]; then major="$(echo "$version" | cut -d. -f2)"; fi
  echo "${major:-0}"
}

find_java() {
  if [ -z "${JAVA_HOME:-}" ]; then JAVA_HOME="$(/usr/libexec/java_home -v 21+ 2>/dev/null || true)"; fi
  if [ -z "$JAVA_HOME" ] || [ ! -x "$JAVA_HOME/bin/java" ]; then return 1; fi
  [ "$(java_major "$JAVA_HOME")" -ge 21 ] 2>/dev/null
}

host_is_loopback() { case "$HOST" in 127.*|localhost|::1) return 0 ;; *) return 1 ;; esac; }

port_open() { nc -z "$HOST" "$PORT" >/dev/null 2>&1; }

mcp_ready() {
  local code
  code="$(curl -s -m 5 -o /dev/null -w '%{http_code}' -X POST "$URL" \
    -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"ghidra-mcp-probe","version":"1"}}}' 2>/dev/null)"
  [ "$code" = "200" ]
}

agent_loaded() { launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; }
agent_running() { launchctl print "$DOMAIN/$LABEL" 2>/dev/null | grep -q "state = running"; }

# launchctl bootout returns before launchd has finished tearing the job down.
wait_unloaded() {
  local i=0
  while agent_loaded && [ "$i" -lt 20 ]; do sleep 0.5; i=$((i + 1)); done
  ! agent_loaded
}

background_pid() {
  local pid
  [ -f "$PID_FILE" ] || return 1
  pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  # Only trust the PID while it is still our pyghidra-mcp (PIDs get reused).
  ps -p "$pid" -o command= 2>/dev/null | grep -q "pyghidra-mcp" || return 1
  echo "$pid"
}

wait_ready() {
  local i=0
  while [ "$i" -lt "$1" ]; do
    mcp_ready && return 0
    sleep 2; i=$((i + 2))
  done
  return 1
}

wait_port_closed() {
  local i=0
  while port_open && [ "$i" -lt 30 ]; do sleep 1; i=$((i + 1)); done
  ! port_open
}

tool_python() {
  local target candidate
  target="$(readlink "$BIN" 2>/dev/null || true)"
  for candidate in ${target:+"$(dirname "$target")/python"} \
                   "$HOME/.local/share/uv/tools/pyghidra-mcp/bin/python" \
                   "$(uv tool dir 2>/dev/null || echo /nonexistent)/pyghidra-mcp/bin/python"; do
    if [ -x "$candidate" ]; then echo "$candidate"; return 0; fi
  done
  return 1
}

preflight() {
  local alt
  if ! host_is_loopback && [ "${GHIDRA_MCP_ALLOW_REMOTE:-0}" != "1" ]; then
    echo "ghidra-mcp: refusing to listen on $HOST because the server has no authentication." >&2
    echo "            Use 127.0.0.1, or set GHIDRA_MCP_ALLOW_REMOTE=1 in $ENV_FILE if you really mean it." >&2
    return 2
  fi
  case "/$PROJECT_DIR/" in
    */.*) echo "ghidra-mcp: Ghidra rejects project paths with a dot-folder: $PROJECT_DIR" >&2; return 2 ;;
  esac
  find_ghidra || {
    echo "ghidra-mcp: no Ghidra install found${GHIDRA_INSTALL_DIR:+ at $GHIDRA_INSTALL_DIR} (set GHIDRA_INSTALL_DIR in $ENV_FILE)." >&2
    return 2
  }
  find_java || {
    echo "ghidra-mcp: Ghidra needs JDK 21 or newer${JAVA_HOME:+, but JAVA_HOME is $JAVA_HOME}. Set JAVA_HOME in $ENV_FILE." >&2
    return 2
  }
  if [ ! -x "$BIN" ] && command -v uv >/dev/null 2>&1; then
    alt="$(uv tool dir --bin 2>/dev/null || true)/pyghidra-mcp"
    if [ -x "$alt" ]; then BIN="$alt"; fi
  fi
  [ -x "$BIN" ] || { echo "ghidra-mcp: $BIN not found. Run install_ghidra_macos.sh." >&2; return 2; }
  mkdir -p "$PROJECT_DIR" "$LOG_DIR" || return 2
  export GHIDRA_INSTALL_DIR JAVA_HOME
}

cmd_run() {
  preflight || exit 2
  exec "$BIN" --transport streamable-http --host "$HOST" --port "$PORT" \
    --project-path "$PROJECT_DIR" --project-name "$PROJECT_NAME" "$SYMBOL_FLAG" "$@"
}

cmd_start() {
  if mcp_ready; then echo "Already running at $URL"; return 0; fi
  if port_open; then
    echo "ghidra-mcp: port $PORT is already used by another program. Free it or set GHIDRA_MCP_PORT in $ENV_FILE." >&2
    return 1
  fi
  preflight || return 2
  if [ -f "$PLIST" ]; then
    if agent_running; then
      :  # launchd already runs it; it may still be starting up
    elif agent_loaded; then
      launchctl kickstart "$DOMAIN/$LABEL" || { echo "ghidra-mcp: launchctl kickstart failed" >&2; return 1; }
    else
      launchctl bootstrap "$DOMAIN" "$PLIST" || { echo "ghidra-mcp: launchctl bootstrap failed" >&2; return 1; }
    fi
  elif ! background_pid >/dev/null; then
    nohup "$SELF" run >>"$LOG_FILE" 2>&1 &
    echo $! >"$PID_FILE"
  fi
  echo "Starting Ghidra MCP server (Ghidra needs 10-60s to start)..."
  if wait_ready 120; then echo "Ready at $URL"; else echo "Not ready after 120s. Check: ghidra-mcp logs" >&2; return 1; fi
}

cmd_stop() {
  local stopped=0 pid
  if [ -f "$PLIST" ] && agent_loaded; then
    if launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null; then
      stopped=1
      wait_unloaded || true
      echo "Stopped LaunchAgent (use 'ghidra-mcp start' to bring it back)."
    fi
  fi
  if pid="$(background_pid)"; then
    if kill "$pid" 2>/dev/null; then stopped=1; echo "Stopped background server (pid $pid)."; fi
  fi
  rm -f "$PID_FILE"
  if [ "$stopped" -eq 0 ]; then echo "Nothing to stop."; return 0; fi
  wait_port_closed || { echo "ghidra-mcp: port $PORT is still in use after 30s" >&2; return 1; }
}

cmd_status() {
  local pid
  echo "URL:          $URL"
  if [ -f "$PLIST" ]; then
    echo "LaunchAgent:  installed ($(agent_loaded && echo loaded || echo not loaded))"
  else
    echo "LaunchAgent:  not installed"
  fi
  if pid="$(background_pid)"; then echo "Background:   running (pid $pid)"; fi
  if port_open; then echo "Port $PORT:     listening"; else echo "Port $PORT:     closed"; fi
  if mcp_ready; then echo "MCP:          responding"; else echo "MCP:          not responding"; return 1; fi
}

cmd_logs() {
  case "$1" in ''|*[!0-9]*) echo "ghidra-mcp: logs takes a number of lines" >&2; return 2 ;; esac
  [ -f "$LOG_FILE" ] || { echo "No log yet: $LOG_FILE" >&2; return 1; }
  tail -n "$1" "$LOG_FILE"
}

cmd_selftest() {
  local py test_script
  py="$(tool_python)" || { echo "ghidra-mcp: cannot find the pyghidra-mcp Python. Is pyghidra-mcp installed?" >&2; return 2; }
  test_script="$(dirname "$SELF")/selftest.py"
  [ -f "$test_script" ] || test_script="$GHIDRA_MCP_HOME/selftest.py"
  [ -f "$test_script" ] || { echo "ghidra-mcp: selftest.py not found next to this script or in $GHIDRA_MCP_HOME" >&2; return 2; }
  "$py" "$test_script" --url "$URL" "$@"
}

cmd_gui() {
  preflight || exit 2
  echo "Stopping the headless server and launching Ghidra in GUI mode (it still serves $URL)."
  cmd_stop || exit 1
  trap 'echo "GUI closed; restarting the headless server..."; cmd_start' EXIT
  "$BIN" --gui --transport streamable-http --host "$HOST" --port "$PORT" \
    --project-path "$PROJECT_DIR" --project-name "$PROJECT_NAME" "$SYMBOL_FLAG"
}

xml_escape() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

cmd_plist() {
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$(xml_escape "$SELF")</string>
    <string>run</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ThrottleInterval</key><integer>30</integer>
  <key>StandardOutPath</key><string>$(xml_escape "$LOG_FILE")</string>
  <key>StandardErrorPath</key><string>$(xml_escape "$LOG_FILE")</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>$(xml_escape "$HOME/.local/bin"):/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>GHIDRA_MCP_HOME</key><string>$(xml_escape "$GHIDRA_MCP_HOME")</string>
  </dict>
</dict>
</plist>
EOF
}

cmd_install_launchagent() {
  local pid
  mkdir -p "$HOME/Library/LaunchAgents" "$LOG_DIR" || return 1
  cmd_plist >"$PLIST" || return 1
  plutil -lint "$PLIST" >/dev/null || { echo "ghidra-mcp: the generated plist is invalid: $PLIST" >&2; return 1; }
  # A background server started by 'ghidra-mcp start' would hold the port; hand over to launchd.
  if pid="$(background_pid)"; then kill "$pid" 2>/dev/null; rm -f "$PID_FILE"; wait_port_closed || true; fi
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  wait_unloaded || true
  launchctl bootstrap "$DOMAIN" "$PLIST" || { echo "ghidra-mcp: launchctl bootstrap failed" >&2; return 1; }
  echo "LaunchAgent installed and loaded: $PLIST"
}

cmd_remove_launchagent() {
  if [ ! -f "$PLIST" ] && ! agent_loaded; then echo "LaunchAgent not installed."; return 0; fi
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"
  if wait_unloaded; then
    echo "LaunchAgent removed."
  else
    echo "LaunchAgent removed; launchd still lists it until the server finishes exiting." >&2
  fi
}

case "${1:-status}" in
  run)                 shift; cmd_run "$@" ;;
  start)               cmd_start ;;
  stop)                cmd_stop ;;
  restart)             cmd_stop && cmd_start ;;
  status)              cmd_status ;;
  logs)                cmd_logs "${2:-100}" ;;
  url)                 echo "$URL" ;;
  gui)                 cmd_gui ;;
  selftest)            shift; cmd_selftest "$@" ;;
  install-launchagent) cmd_install_launchagent ;;
  remove-launchagent)  cmd_remove_launchagent ;;
  launchagent-plist)   cmd_plist ;;
  -h|--help|help)      usage ;;
  *)                   usage; exit 1 ;;
esac
