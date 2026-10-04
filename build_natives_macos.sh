#!/usr/bin/env bash
# Build the macOS native decompiler for an existing Ghidra install.
#
# Why: public Ghidra releases since 12.1 (12.1.2 excepted) ship native components only for
# Windows and Linux. On macOS the decompiler then fails (Ghidra reports that
# os/mac_arm_64/decompile does not exist) and tools built on top of it return empty output.
#
# What this does (about 15 seconds, no Gradle download):
#   1. copies the decompiler's C++ sources out of YOUR Ghidra install into a temp folder
#   2. builds the `ghidra_opt` make target for this Mac's CPU (arm64 or x86_64)
#   3. installs it as <install>/Ghidra/Features/Decompiler/os/<mac_arm_64|mac_x86_64>/decompile
#      with an atomic rename, so a decompiler that is running right now is never overwritten
#
# Limits: it builds ONLY the decompiler (1 of Ghidra's 5 native components) through the Makefile,
# which upstream does not document as the supported route. For the complete, supported set run:
#   cd <GhidraInstallDir>/support/gradle && ./gradlew buildNatives
#
# Usage: build_natives_macos.sh [--check] [--force] [GHIDRA_INSTALL_DIR]
#   GHIDRA_INSTALL_DIR  default: newest ~/Applications/ghidra_*_PUBLIC
#   --check             report whether the decompiler is built; change nothing
#   --force             rebuild even if it already exists
# Needs: Xcode Command Line Tools (xcode-select --install). Never needs sudo.

set -euo pipefail

CHECK_ONLY=0
FORCE=0
GHIDRA_HOME=""
for arg in "$@"; do
  case "$arg" in
    --check) CHECK_ONLY=1 ;;
    --force) FORCE=1 ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d'; exit 0 ;;
    -*) echo "unknown option: $arg" >&2; exit 1 ;;
    *) GHIDRA_HOME="$arg" ;;
  esac
done

[ "$(uname -s)" = "Darwin" ] || { echo "macOS only." >&2; exit 1; }
[ "$(id -u)" -ne 0 ] || { echo "Run as your normal user, not root." >&2; exit 1; }

if [ -z "$GHIDRA_HOME" ]; then
  # Globs expand in sorted order, so the last valid match is the newest version.
  for candidate in "$HOME"/Applications/ghidra_*_PUBLIC; do
    if [ -x "$candidate/ghidraRun" ]; then GHIDRA_HOME="$candidate"; fi
  done
fi
[ -n "$GHIDRA_HOME" ] || { echo "No Ghidra install found in ~/Applications. Pass its path as the argument." >&2; exit 1; }
[ "$GHIDRA_HOME" = "/" ] || GHIDRA_HOME="${GHIDRA_HOME%/}"

SRC="$GHIDRA_HOME/Ghidra/Features/Decompiler/src/decompile/cpp"
[ -f "$SRC/Makefile" ] || { echo "Not a Ghidra install (missing $SRC/Makefile): $GHIDRA_HOME" >&2; exit 1; }

case "$(uname -m)" in
  arm64)  ARCH="arm64";  OSDIR="mac_arm_64" ;;
  x86_64) ARCH="x86_64"; OSDIR="mac_x86_64" ;;
  *) echo "unsupported CPU: $(uname -m)" >&2; exit 1 ;;
esac
if [ "$ARCH" = "x86_64" ] && [ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" = "1" ]; then
  echo "warning: this shell runs under Rosetta, so an Intel (x86_64) decompiler will be built." >&2
  echo "         With an Apple Silicon JDK, run natively instead:  arch -arm64 $0 $GHIDRA_HOME" >&2
fi
DEST_DIR="$GHIDRA_HOME/Ghidra/Features/Decompiler/os/$OSDIR"
DEST="$DEST_DIR/decompile"

is_built() {
  [ -x "$DEST" ] || return 1
  case "$(file -b "$DEST" 2>/dev/null)" in *Mach-O*) return 0 ;; *) return 1 ;; esac
}

if [ "$CHECK_ONLY" -eq 1 ]; then
  if is_built; then echo "decompiler: built ($DEST)"; else echo "decompiler: NOT built (would build for $ARCH into $DEST)"; fi
  exit 0
fi
if is_built && [ "$FORCE" -eq 0 ]; then
  echo "decompiler: already built ($DEST). Use --force to rebuild."
  exit 0
fi

# Fail before compiling if the install cannot be written to.
probe="$DEST_DIR"
while [ ! -d "$probe" ]; do probe="$(dirname "$probe")"; done
[ -w "$probe" ] || { echo "No write permission for $probe. Use a Ghidra install you own, or fix its permissions." >&2; exit 1; }

xcode-select -p >/dev/null 2>&1 || { echo "Xcode Command Line Tools are required: run  xcode-select --install" >&2; exit 1; }

BUILD="$(mktemp -d)"
STAGED="$DEST_DIR/.decompile.tmp.$$"
trap 'rm -rf "$BUILD"; rm -f "$STAGED"' EXIT
cp -R "$SRC/." "$BUILD/"

echo "Building the Ghidra decompiler for macOS $ARCH from $GHIDRA_HOME ..."
# The Makefile hard-codes "-arch x86_64" on macOS, so the architecture is overridden here.
if ! make -C "$BUILD" -j"$(sysctl -n hw.ncpu)" ARCH_TYPE="-arch $ARCH" \
      ADDITIONAL_FLAGS="-mmacosx-version-min=11.0 -w" ghidra_opt >"$BUILD/build.log" 2>&1; then
  tail -25 "$BUILD/build.log" >&2
  echo "Build failed; the end of the log is shown above." >&2
  exit 1
fi

mkdir -p "$DEST_DIR"
cp "$BUILD/ghidra_opt" "$STAGED"
chmod 755 "$STAGED"
mv -f "$STAGED" "$DEST"
echo "decompiler: built -> $DEST"
echo "type:       $(file -b "$DEST" | cut -d, -f1)"
echo "signature:  $(codesign -dv "$DEST" 2>&1 | grep -E '^Signature' || echo 'none')"
