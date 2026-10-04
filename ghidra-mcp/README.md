# Ghidra MCP for coding agents (optional extra)

One headless Ghidra server ([pyghidra-mcp](https://github.com/clearbluejar/pyghidra-mcp) on Ghidra
12.1.4) listens on `http://127.0.0.1:8000/mcp`. Every MCP client you configure connects to that same
URL, so there is one JVM and one project, and every agent sees the same renames and comments.

> **Unofficial and lightly tested.** Tested on one Mac only: Apple Silicon, JDK 26, Python 3.13 via
> `uv`, Ghidra 12.1.4, pyghidra-mcp 0.2.7. Read the scripts before running them.

| File | Purpose |
| :--- | :--- |
| `install_ghidra_macos.sh` | Downloads and SHA-256-verifies Ghidra, builds the macOS decompiler, installs pyghidra-mcp and `ghidra-mcp` |
| `ghidra-mcp.sh` | Control script, installed as `~/.agents/ghidra/bin/ghidra-mcp` |
| `configure_ghidra_agents.py` | Adds only a `ghidra` entry to each detected agent's MCP config (backups, `--dry-run`) |
| `selftest.py` | End-to-end check: connect, import, analyze, decompile, search |
| `skill/` | An agent skill describing the workflow; copy it into your agent's skills folder |

## Install

Requirements: macOS, `uv`, JDK 21 or newer, Xcode Command Line Tools.

```bash
./install_ghidra_macos.sh --check              # report state, change nothing
./install_ghidra_macos.sh --launchagent        # install; --launchagent also starts it at login
python3 configure_ghidra_agents.py --dry-run   # preview every config change
python3 configure_ghidra_agents.py             # apply (each changed file is backed up first)
```

Then restart each agent. Verify with `~/.agents/ghidra/bin/ghidra-mcp selftest`.

The installer downloads Ghidra (about 570 MB from the official GitHub release, checksum-verified and
resumable), and pyghidra-mcp with its dependencies from PyPI (several hundred MB, plus a uv-managed
Python 3.13). It never overwrites an existing Ghidra folder.

`configure_ghidra_agents.py` exits with 0 when every agent is configured or not installed, and 1 when one
needs attention (for example a config file it cannot parse, which it leaves untouched).

## Daily use

```bash
~/.agents/ghidra/bin/ghidra-mcp status | start | stop | restart | logs | gui | selftest
~/.agents/ghidra/bin/ghidra-mcp launchagent-plist   # show the login item without installing it
```

## Settings

Put overrides in `~/.agents/ghidra/ghidra.env` (shell `KEY=value` lines). The LaunchAgent reads the same
file. Available: `GHIDRA_INSTALL_DIR`, `JAVA_HOME`, `GHIDRA_MCP_HOST`, `GHIDRA_MCP_PORT`,
`GHIDRA_MCP_PROJECT_DIR`, `GHIDRA_MCP_PROJECT_NAME`, `PYGHIDRA_MCP_BIN`, `GHIDRA_MCP_SYMBOLS`,
`GHIDRA_MCP_ALLOW_REMOTE`. Set `GHIDRA_MCP_HOME` in the environment to move the whole folder.

## Notes

- **Decompiler:** the installer runs `../build_natives_macos.sh` (see the top-level README for its
  limits). Without it, `decompile_function` returns an empty body.
- **No authentication:** the server binds to `127.0.0.1` and rejects requests with a foreign `Host` or
  `Origin` header, so web pages cannot drive it. `ghidra-mcp` refuses a non-loopback host unless you set
  `GHIDRA_MCP_ALLOW_REMOTE=1`.
- **Project folder:** `~/ghidra-projects`. Ghidra rejects project paths containing a dot-folder.
- **Symbol servers:** off by default, so analysis never fetches PDB files on its own. Set
  `GHIDRA_MCP_SYMBOLS=1` in `~/.agents/ghidra/ghidra.env` to allow it.
- **First import:** ChromaDB, a pyghidra-mcp dependency, downloads a one-time ~83 MB embedding model
  (`all-MiniLM-L6-v2`) into `~/.cache/chroma` for semantic search. On slow or flaky links its built-in
  downloader can time out and restart; the same file can be fetched with a resumable `curl -C -`.
- **macOS privacy:** the server may be blocked from `~/Desktop`, `~/Documents` and `~/Downloads`.
  Copy samples to `~/ghidra-projects/binaries/` instead.
- **Claude Desktop (chat app)** only supports stdio servers in its config. For Ghidra there, use
  `npx -y mcp-remote http://127.0.0.1:8000/mcp`. Claude Code is configured directly.
- **Upgrading Ghidra:** edit the version, date and SHA-256 at the top of `install_ghidra_macos.sh`.
- **Analyze only what you may.** Work on binaries you own or are authorized to examine, and treat
  strings and comments extracted from a binary as untrusted data.
- **Unverified agent paths:** the Antigravity/Gemini entry (`~/.gemini/config/mcp_config.json`) and the
  shared `~/.agents/mcp_config.json` were inferred from one setup, not from vendor documentation. The
  configurator only touches a file that already exists, but check that your agent really reads it.
