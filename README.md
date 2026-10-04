# Ghidra on macOS: build the missing native decompiler

> **Unofficial.** This project is not affiliated with or endorsed by the NSA or the Ghidra project.
> It contains **no Ghidra code and no binaries**, only helper scripts. Ghidra itself is Apache-2.0:
> <https://github.com/NationalSecurityAgency/ghidra>

## The problem

Public Ghidra releases since 12.1 (12.1.2 was a one-off) ship native components only for Windows and
Linux. Ghidra still runs on macOS, but its decompiler cannot start, and tools built on it (headless
analysis, MCP servers) silently return empty decompilation. The Ghidra maintainers explain why in
[discussion #9536](https://github.com/NationalSecurityAgency/ghidra/discussions/9536): their new build
pipeline cannot produce macOS natives, and the old prebuilt ones were unsigned, so Gatekeeper blocked
them. They consider building the natives yourself the better approach.

## Recommended: the official route

```bash
cd <GhidraInstallDir>/support/gradle
./gradlew buildNatives
```

This builds every native component. It needs Xcode Command Line Tools (`xcode-select --install`), a
JDK, and internet access, because the wrapper downloads Gradle (about 150 MB for Ghidra 12.1.4).
See "Building Native Components" in Ghidra's `GettingStarted.md`.

## This repo: a lightweight alternative

`build_natives_macos.sh` builds **only the decompiler** with Ghidra's own Makefile. It takes about 15
seconds and needs no Gradle download.

```bash
./build_natives_macos.sh --check                       # report only, changes nothing
./build_natives_macos.sh                               # newest ~/Applications/ghidra_*_PUBLIC
./build_natives_macos.sh /path/to/ghidra_12.1.4_PUBLIC # a specific install
./build_natives_macos.sh --force                       # rebuild an existing decompiler
```

What it does: copies the decompiler's C++ sources from **your own** Ghidra install to a temp folder,
builds the `ghidra_opt` target for your CPU, and installs the result as
`Ghidra/Features/Decompiler/os/mac_arm_64/decompile` (or `mac_x86_64`). The Makefile hard-codes
`-arch x86_64` on macOS, so the script overrides the architecture. The new binary is swapped in with an
atomic rename, so a decompiler that is running at that moment is not disturbed. Nothing is downloaded.

### Limits, please read

- It builds **1 of Ghidra's 5 native components** (the decompiler). The two GNU demanglers, `sleigh`
  and `lzfse` are not built. Use the official route if you need them.
- It uses the Makefile, not the Gradle task that upstream documents, so treat it as a convenience
  for the common case (decompiling on Apple Silicon), not as a replacement for the official build.
- **Tested only on:** Ghidra 12.1.4, Apple Silicon, Xcode Command Line Tools, decompiling small
  Mach-O binaries. The Intel (`x86_64`) path is untested. Run it from a native terminal: under Rosetta
  it would build an Intel binary, and it warns you if that is the case.
- The result is **ad-hoc signed**, which is fine for local use because nothing is quarantined when you
  build it yourself. Two builds from the same sources were byte-for-byte identical.

### Why no prebuilt binaries here?

An unsigned binary downloaded from the internet is quarantined by macOS, and Gatekeeper blocks it.
That is exactly the problem the Ghidra maintainers describe. A binary built on your own machine from
the sources you already have avoids both the block and the question of trusting someone else's build.
Check your Ghidra download against the SHA-256 on its official release page before building.

## Checks

```bash
tests/run_tests.sh                                                         # offline checks and unit tests
GHIDRA_INSTALL_DIR=~/Applications/ghidra_12.1.4_PUBLIC tests/run_tests.sh  # plus a real build
```

They cover shell syntax under macOS's own bash 3.2, Python 3.9+ syntax, ShellCheck and ruff (when
installed), unit tests for the agent configurator, and the build script's failure handling.

## Optional extra: Ghidra for your coding agents

[`ghidra-mcp/`](ghidra-mcp/README.md) installs one headless Ghidra server (via
[pyghidra-mcp](https://github.com/clearbluejar/pyghidra-mcp)) that Claude Code, Codex, Cline, Copilot
and other MCP clients can share, plus a skill that teaches agents how to use it. It is independent of
the script above, but it uses it to get a working decompiler.

## License

Apache-2.0, matching Ghidra. See [LICENSE](LICENSE).
