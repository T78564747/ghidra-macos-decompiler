#!/usr/bin/env bash
# Install the shared Ghidra MCP stack (macOS) for your coding agents.
#
#   1. Ghidra         official NSA release, SHA-256 verified   -> ~/Applications/ghidra_<ver>_PUBLIC
#      + the macOS decompiler, built from those sources by ../build_natives_macos.sh
#   2. pyghidra-mcp   PyPI, `uv tool` on a managed Python 3.13  -> ~/.local/bin/pyghidra-mcp
#   3. ghidra-mcp     control script + folders                  -> ~/.agents/ghidra/ (or $GHIDRA_MCP_HOME)
#   4. --launchagent  start the server automatically at login
#
# Re-runnable: finished steps are skipped. --check only reports state and changes nothing.
# Afterwards run:  python3 configure_ghidra_agents.py   (adds the server to every agent)
#
# Heads-up: on the first import of a binary, ChromaDB (a pyghidra-mcp dependency) downloads
# its default embedding model (~83 MB, all-MiniLM-L6-v2 from chroma-onnx-models.s3.amazonaws.com,
# SHA-256 checked by chromadb) into ~/.cache/chroma. It powers semantic code search.

set -euo pipefail

GHIDRA_VERSION="12.1.4"
GHIDRA_DATE="20260921"
GHIDRA_SHA256="ddac49f903da9d5bac833e5cc79395098b9c33cfd3279be5f31bd00387d2d4db"
PYGHIDRA_MCP_VERSION="0.2.7"
PYTHON_VERSION="3.13"

GHIDRA_DIR_NAME="ghidra_${GHIDRA_VERSION}_PUBLIC"
GHIDRA_ZIP="ghidra_${GHIDRA_VERSION}_PUBLIC_${GHIDRA_DATE}.zip"
GHIDRA_URL="https://github.com/NationalSecurityAgency/ghidra/releases/download/Ghidra_${GHIDRA_VERSION}_build/${GHIDRA_ZIP}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPS_DIR="$HOME/Applications"
GHIDRA_HOME="$APPS_DIR/$GHIDRA_DIR_NAME"
MCP_HOME="${GHIDRA_MCP_HOME:-$HOME/.agents/ghidra}"
BUILDER="$SCRIPT_DIR/../build_natives_macos.sh"

TMP=""
cleanup() { if [ -n "$TMP" ]; then rm -rf "$TMP"; fi; }
trap cleanup EXIT

CHECK_ONLY=0
WITH_LAUNCHAGENT=0
for arg in "$@"; do
  case "$arg" in
    --check) CHECK_ONLY=1 ;;
    --launchagent) WITH_LAUNCHAGENT=1 ;;
    -h|--help) sed -n '2,/^$/p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 1 ;;
  esac
done

[ "$(id -u)" -ne 0 ] || { echo "Run as your normal user, not root." >&2; exit 1; }
[ "$(uname -s)" = "Darwin" ] || { echo "macOS only." >&2; exit 1; }

say() { printf '%s\n' "$*"; }

MISSING=0
need() { command -v "$1" >/dev/null 2>&1 || { say "missing prerequisite: $1 ($2)"; MISSING=1; }; }
need curl "built in"
need shasum "built in"
need unzip "built in"
need uv "curl -LsSf https://astral.sh/uv/install.sh | sh"
JAVA_FOUND="$(/usr/libexec/java_home -v 21+ 2>/dev/null || true)"
[ -n "$JAVA_FOUND" ] || { say "missing prerequisite: JDK 21+ (https://adoptium.net/temurin/releases)"; MISSING=1; }
[ -x "$BUILDER" ] || { say "missing $BUILDER (keep this repo's folder layout)"; MISSING=1; }
[ "$MISSING" -eq 0 ] || exit 1
say "Java:         $JAVA_FOUND"

# 1. Ghidra
if [ -x "$GHIDRA_HOME/ghidraRun" ]; then
  say "Ghidra:       $GHIDRA_HOME (already installed)"
elif [ -e "$GHIDRA_HOME" ]; then
  say "Ghidra:       $GHIDRA_HOME exists but looks incomplete (no ghidraRun)."
  say "              Move it aside and re-run; it is never overwritten automatically."
  exit 1
elif [ "$CHECK_ONLY" -eq 1 ]; then
  say "Ghidra:       NOT installed (would download $GHIDRA_ZIP, ~570 MB)"
else
  TMP="$(mktemp -d)"
  say "Downloading $GHIDRA_ZIP ..."
  # -C - resumes and --retry-all-errors retries after stalls, instead of starting over.
  curl -fL -sS -C - --retry 5 --retry-delay 3 --retry-all-errors -o "$TMP/$GHIDRA_ZIP" "$GHIDRA_URL"
  ACTUAL="$(shasum -a 256 "$TMP/$GHIDRA_ZIP" | awk '{print $1}')"
  [ "$ACTUAL" = "$GHIDRA_SHA256" ] || { say "SHA-256 mismatch ($ACTUAL); refusing to install."; exit 1; }
  say "SHA-256 verified."
  # Extract next to the download, then move into place, so an interrupted run never leaves half a Ghidra.
  unzip -q "$TMP/$GHIDRA_ZIP" -d "$TMP/extract"
  [ -x "$TMP/extract/$GHIDRA_DIR_NAME/ghidraRun" ] || { say "Unexpected archive layout."; exit 1; }
  mkdir -p "$APPS_DIR"
  mv "$TMP/extract/$GHIDRA_DIR_NAME" "$GHIDRA_HOME"
  say "Ghidra:       installed to $GHIDRA_HOME"
fi

# 1b. Native decompiler. Public Ghidra releases ship natives only for Windows and Linux, so on macOS
#     it is built once from the sources in your install (see ../build_natives_macos.sh for the limits).
if [ ! -x "$GHIDRA_HOME/ghidraRun" ]; then
  say "decompiler:   skipped (Ghidra is not installed yet)"
elif [ "$CHECK_ONLY" -eq 1 ]; then
  "$BUILDER" --check "$GHIDRA_HOME"
else
  "$BUILDER" "$GHIDRA_HOME"
fi

# 2. pyghidra-mcp
has_pyghidra_mcp() {
  uv tool list 2>/dev/null | awk -v v="v$PYGHIDRA_MCP_VERSION" '$1 == "pyghidra-mcp" && $2 == v { found = 1 } END { exit !found }'
}
if has_pyghidra_mcp; then
  say "pyghidra-mcp: v${PYGHIDRA_MCP_VERSION} (already installed)"
elif [ "$CHECK_ONLY" -eq 1 ]; then
  say "pyghidra-mcp: NOT installed at v${PYGHIDRA_MCP_VERSION}"
else
  uv tool install --python "$PYTHON_VERSION" "pyghidra-mcp==${PYGHIDRA_MCP_VERSION}"
  has_pyghidra_mcp || { say "pyghidra-mcp did not install; see the uv output above."; exit 1; }
  say "pyghidra-mcp: v${PYGHIDRA_MCP_VERSION} installed"
fi

# 3. Control script + folders
if [ "$CHECK_ONLY" -eq 1 ]; then
  if [ -x "$MCP_HOME/bin/ghidra-mcp" ]; then say "ghidra-mcp:   installed"; else say "ghidra-mcp:   NOT installed"; fi
else
  mkdir -p "$MCP_HOME/bin" "$MCP_HOME/logs" "$HOME/ghidra-projects/binaries"
  cp "$SCRIPT_DIR/ghidra-mcp.sh" "$MCP_HOME/bin/ghidra-mcp"
  chmod 755 "$MCP_HOME/bin/ghidra-mcp"
  cp "$SCRIPT_DIR/selftest.py" "$MCP_HOME/selftest.py"
  say "ghidra-mcp:   $MCP_HOME/bin/ghidra-mcp"
fi

# 4. Auto-start at login
if [ "$WITH_LAUNCHAGENT" -eq 1 ] && [ "$CHECK_ONLY" -eq 0 ]; then
  GHIDRA_MCP_HOME="$MCP_HOME" "$MCP_HOME/bin/ghidra-mcp" install-launchagent
fi

say ""
say "Next: python3 \"$SCRIPT_DIR/configure_ghidra_agents.py\"   (adds the server to every agent)"
