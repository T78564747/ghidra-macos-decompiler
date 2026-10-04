#!/usr/bin/env python3
"""Add the shared Ghidra MCP server to every coding agent on this Mac (merge-safe).

What it does
  * Adds or updates ONLY the `ghidra` entry in each agent's MCP config; nothing else is rewritten.
    Settings you added to that entry yourself (for example "disabled" or "autoApprove") are kept.
  * Backs up every file it changes to ~/.agents/ghidra/backups/<timestamp>/ (private, mode 700) first.
  * Writes atomically, writes through symlinked config files, and refuses to touch a file it cannot parse.
  * Never copies secrets. With --with-shared-servers it also mirrors the secret-free local servers listed
    in ~/.agents/mcp_config.json into agents that have none yet (Codex, VS Code Copilot); servers whose
    env keys, env values or arguments look like credentials are always skipped.

Usage
  python3 configure_ghidra_agents.py [--dry-run] [--with-shared-servers] [--host H] [--port P]

Exit status is 0 when every agent is configured or skipped as not installed, and 1 when an agent
needs attention. All agents share one server (default http://127.0.0.1:8000/mcp) managed by `ghidra-mcp`.
"""

import argparse
import glob
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

try:
    import tomllib  # Python 3.11+
except ImportError:  # older Pythons fall back to a conservative text check
    tomllib = None

HOME = os.path.expanduser("~")
STAMP = time.strftime("%Y%m%d-%H%M%S")
BACKUP_DIR = os.path.join(HOME, ".agents", "ghidra", "backups", STAMP)
BEGIN = "# >>> ghidra-macos-natives (managed) >>>"
END = "# <<< ghidra-macos-natives (managed) <<<"

SECRET_NAME_RE = re.compile(r"token|secret|password|passwd|api[_-]?key|auth|bearer|credential|private", re.IGNORECASE)
TOKEN_PREFIX_RE = re.compile(r"^(?:sk-|sk_|ghp_|gho_|ghs_|ghu_|github_pat_|glpat-|xox[abprs]-|AKIA|ASIA|AIza|sbp_|eyJ)")
OPAQUE_RE = re.compile(r"^[A-Za-z0-9_\-+=.]{32,}$")  # long random-looking strings; paths contain "/" and never match
# Transport fields of an existing `ghidra` entry are replaced; every other field the user set is kept.
TRANSPORT_KEYS = ("command", "args", "env", "url", "serverUrl", "httpUrl", "type", "transport")

results = []


def p(rel):
    return os.path.join(HOME, rel)


def short(path):
    return path.replace(HOME, "~", 1)


def note(agent, status, detail=""):
    results.append((agent, status, detail))
    print(f"  [{status:^8}] {agent}" + (f" - {detail}" if detail else ""))


def read_text(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def json_indent(text):
    """The indentation an existing JSON file uses, so a rewrite keeps its style."""
    match = re.search(r"\n([ \t]+)\S", text)
    if not match:
        return 2
    return "\t" if match.group(1).startswith("\t") else len(match.group(1))


def backup(path, dry):
    if dry or not os.path.exists(path):
        return
    os.makedirs(BACKUP_DIR, exist_ok=True)
    for folder in (os.path.dirname(BACKUP_DIR), BACKUP_DIR):
        os.chmod(folder, 0o700)  # backups can contain tokens from the originals
    shutil.copy2(path, os.path.join(BACKUP_DIR, path.lstrip("/").replace("/", "__")))


def atomic_write(path, text, dry):
    if dry:
        return
    path = os.path.realpath(path)  # write through symlinks instead of replacing them
    directory = os.path.dirname(path)
    os.makedirs(directory, exist_ok=True)
    mode = (os.stat(path).st_mode & 0o777) if os.path.exists(path) else 0o644
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".ghidra-mcp-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def merge_json_server(agent, path, key, forced, dry, *, defaults=None, create=False, extra=None):
    """Point data[key]['ghidra'] at the shared server, keeping the user's own fields in that entry."""
    exists = os.path.exists(path)
    if not exists and not create:
        note(agent, "skip", "not installed / no config yet")
        return
    try:
        text = read_text(path) if exists else ""
        data = json.loads(text) if text.strip() else {}
    except (OSError, ValueError) as e:
        note(agent, "SKIPPED", f"cannot read {os.path.basename(path)} ({type(e).__name__}); left untouched")
        return
    servers = data.get(key, {}) if isinstance(data, dict) else None
    if not isinstance(servers, dict):
        note(agent, "SKIPPED", f"unexpected structure in {os.path.basename(path)}; left untouched")
        return
    current = servers.get("ghidra")
    entry = {k: v for k, v in current.items() if k not in TRANSPORT_KEYS} if isinstance(current, dict) else {}
    for k, v in (defaults or {}).items():
        entry.setdefault(k, v)
    entry.update(forced)
    changed = entry != current
    servers["ghidra"] = entry
    for name, server in (extra or {}).items():
        if name not in servers:
            servers[name] = server
            changed = True
    if not changed:
        note(agent, "ok", "already configured")
        return
    data[key] = servers
    backup(path, dry)
    atomic_write(path, json.dumps(data, indent=json_indent(text), ensure_ascii=False) + "\n", dry)
    note(agent, "dry-run" if dry else "updated", short(path))


def version_key(path):
    return [int(part) if part.isdigit() else part for part in re.split(r"(\d+)", path)]


def find_claude_cli():
    candidates = []
    found = shutil.which("claude")
    if found:
        candidates.append(found)
    for pattern in (
        ".vscode/extensions/anthropic.claude-code-*/resources/native-binary/claude",
        "Library/Application Support/Claude/claude-code/*/claude",
        "Library/Application Support/Claude/claude-code/*/*.app/Contents/MacOS/claude",
    ):
        candidates += sorted(glob.glob(p(pattern)), key=version_key, reverse=True)
    for candidate in candidates:
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    return None


def run_cli(cmd):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, cwd=HOME, timeout=60, check=False)
    except (OSError, subprocess.SubprocessError) as e:
        return subprocess.CompletedProcess(cmd, 1, "", f"{type(e).__name__}: {e}")


def claude_ghidra_entry(cfg):
    servers = json.loads(read_text(cfg)).get("mcpServers", {}) if os.path.exists(cfg) else {}
    return servers.get("ghidra") if isinstance(servers, dict) else None


def configure_claude_code(url, dry):
    agent = "Claude Code (user scope)"
    cfg = p(".claude.json")
    try:
        current = claude_ghidra_entry(cfg)
    except (OSError, ValueError, AttributeError) as e:
        note(agent, "SKIPPED", f"cannot read ~/.claude.json ({type(e).__name__}); left untouched")
        return
    if isinstance(current, dict) and current.get("type") == "http" and current.get("url") == url:
        note(agent, "ok", "already configured")
        return
    cli = find_claude_cli()
    if not cli and not os.path.exists(cfg):
        note(agent, "skip", "Claude Code not installed")
        return
    if not cli:
        manual = f"claude mcp add --scope user --transport http ghidra {url}"
        note(agent, "SKIPPED", f"no Claude Code CLI found; run: {manual}")
        return
    if dry:
        note(agent, "dry-run", f"would run: claude mcp add --scope user --transport http ghidra {url}")
        return
    backup(cfg, dry)
    # The official CLI edits ~/.claude.json safely even while Claude Code is running.
    if current is not None:
        run_cli([cli, "mcp", "remove", "ghidra", "--scope", "user"])
    result = run_cli([cli, "mcp", "add", "--scope", "user", "--transport", "http", "ghidra", url])
    try:
        entry = claude_ghidra_entry(cfg)
    except (OSError, ValueError, AttributeError):
        entry = None
    if isinstance(entry, dict) and entry.get("url") == url:
        note(agent, "updated", "via claude mcp add")
    else:
        detail = (result.stderr or result.stdout or "unknown error").strip()[:160]
        note(agent, "FAILED", f"{detail} (backup of ~/.claude.json is in {short(BACKUP_DIR)})")


def looks_secret(value):
    text = str(value)
    return bool(TOKEN_PREFIX_RE.match(text) or OPAQUE_RE.match(text))


def shared_servers():
    """Secret-free local stdio servers from the shared ~/.agents/mcp_config.json."""
    try:
        servers = json.loads(read_text(p(".agents/mcp_config.json"))).get("mcpServers", {})
    except (OSError, ValueError, AttributeError):
        return {}
    if not isinstance(servers, dict):
        return {}
    out = {}
    for name, server in servers.items():
        if name == "ghidra" or not isinstance(server, dict) or "command" not in server:
            continue  # remote servers need their own auth flow
        env = server.get("env") or {}
        args = [str(a) for a in server.get("args") or []]
        if not isinstance(env, dict):
            continue
        if any(SECRET_NAME_RE.search(k) or looks_secret(v) for k, v in env.items()):
            continue  # never copy credentials
        if any(SECRET_NAME_RE.search(a) or looks_secret(a) for a in args):
            continue
        command = str(server["command"])
        if not (os.path.exists(command) or shutil.which(command)):
            continue  # not installed on this Mac
        out[name] = {"command": command, "args": args, "env": {k: str(v) for k, v in env.items()}}
    return out


def toml_key(name):
    return name if re.fullmatch(r"[A-Za-z0-9_-]+", name) else json.dumps(name)


def toml_defines_server(text, name):
    """True if the TOML text already defines mcp_servers.<name>, in any spelling."""
    if tomllib is not None:
        try:
            servers = tomllib.loads(text).get("mcp_servers", {})
        except tomllib.TOMLDecodeError:
            servers = None
        if isinstance(servers, dict):
            return name in servers
    quoted = re.escape(name)
    pattern = rf"^\s*\[?\s*mcp_servers\s*\.\s*(?:\"{quoted}\"|'{quoted}'|{quoted})\s*[\].=]"
    return re.search(pattern, text, re.MULTILINE) is not None


def render_toml(url, extra):
    lines = [
        BEGIN,
        "# Keep your own top-level settings ABOVE this block: TOML attaches keys below a table to that table.",
        "[mcp_servers.ghidra]",
        f"url = {json.dumps(url)}",
    ]
    for name, server in extra.items():
        lines += ["", f"[mcp_servers.{toml_key(name)}]", f"command = {json.dumps(server['command'])}"]
        if server.get("args"):
            lines.append("args = " + json.dumps(server["args"]))
        if server.get("env"):
            lines += ["", f"[mcp_servers.{toml_key(name)}.env]"]
            lines += [f"{toml_key(k)} = {json.dumps(str(v))}" for k, v in server["env"].items()]
    lines.append(END)
    return "\n".join(lines) + "\n"


def configure_codex(url, extra, dry):
    agent = "Codex (~/.codex/config.toml)"
    if not os.path.isdir(p(".codex")):
        note(agent, "skip", "Codex not installed")
        return
    path = p(".codex/config.toml")
    try:
        text = read_text(path) if os.path.exists(path) else ""
    except (OSError, ValueError) as e:
        note(agent, "SKIPPED", f"cannot read config.toml ({type(e).__name__}); left untouched")
        return
    if text.count(BEGIN) != text.count(END) or text.count(BEGIN) > 1:
        note(agent, "SKIPPED", "the managed block markers are unbalanced; fix config.toml by hand")
        return
    outside = re.sub(re.escape(BEGIN) + r".*?" + re.escape(END) + r"\n?", "", text, flags=re.DOTALL)
    if tomllib is not None and outside.strip():
        try:
            tomllib.loads(outside)
        except tomllib.TOMLDecodeError as e:
            note(agent, "SKIPPED", f"config.toml is not valid TOML ({e}); left untouched")
            return
    if toml_defines_server(outside, "ghidra"):
        note(agent, "skip", "a hand-written mcp_servers.ghidra already exists")
        return
    extra = {name: server for name, server in extra.items() if not toml_defines_server(outside, name)}
    new = outside.rstrip("\n") + ("\n\n" if outside.strip() else "") + render_toml(url, extra)
    if tomllib is not None:
        try:
            tomllib.loads(new)
        except tomllib.TOMLDecodeError as e:
            note(agent, "SKIPPED", f"the result would not be valid TOML ({e}); left untouched")
            return
    if new == text:
        note(agent, "ok", "already configured")
        return
    backup(path, dry)
    atomic_write(path, new, dry)
    note(agent, "dry-run" if dry else "updated", short(path))


def configure_vscode(url, extra, dry):
    agent = "VS Code / GitHub Copilot (mcp.json)"
    user_dir = p("Library/Application Support/Code/User")
    if not os.path.isdir(user_dir):
        note(agent, "skip", "VS Code not found")
        return
    vs_extra = {}
    for name, server in extra.items():
        entry = {"type": "stdio", "command": server["command"], "args": server.get("args", [])}
        if server.get("env"):
            entry["env"] = server["env"]
        vs_extra[name] = entry
    merge_json_server(agent, os.path.join(user_dir, "mcp.json"), "servers", {"type": "http", "url": url}, dry,
                      create=True, extra=vs_extra)


def write_server_file(url, dry):
    agent = "Shared server file (~/.agents/servers/ghidra.json)"
    path = p(".agents/servers/ghidra.json")
    if not os.path.isdir(p(".agents")):
        note(agent, "skip", "no ~/.agents folder")
        return
    data = {
        "id": "ghidra",
        "label": "Ghidra Reverse Engineering (shared)",
        "description": "pyghidra-mcp server shared by all agents; start with: ghidra-mcp start",
        "transport": "streamable-http",
        "command": None,
        "args": [],
        "env": {},
        "url": url,
        "headers": {},
    }
    try:
        if os.path.exists(path) and json.loads(read_text(path)) == data:
            note(agent, "ok", "already configured")
            return
    except (OSError, ValueError):
        pass  # unreadable or stale: it is ours, so it is rewritten below
    backup(path, dry)
    atomic_write(path, json.dumps(data, indent=2) + "\n", dry)
    note(agent, "dry-run" if dry else "updated", short(path))


def parse_args(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dry-run", action="store_true", help="show what would change, write nothing")
    ap.add_argument("--with-shared-servers", action="store_true",
                    help="also mirror the secret-free servers from ~/.agents/mcp_config.json into Codex and Copilot")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8000)
    args = ap.parse_args(argv)
    if not 1 <= args.port <= 65535:
        ap.error("--port must be between 1 and 65535")
    host = args.host.strip("[]")
    if not re.fullmatch(r"[A-Za-z0-9.\-]+|[0-9A-Fa-f:]+", host):
        ap.error("--host must be a hostname or an IP address")
    args.host = f"[{host}]" if ":" in host else host
    return args


def main(argv=None):
    args = parse_args(argv)
    url = f"http://{args.host}:{args.port}/mcp"
    dry = args.dry_run

    print(f"Ghidra MCP endpoint: {url}" + ("   (dry run)" if dry else ""))
    if args.host not in ("127.0.0.1", "localhost", "[::1]"):
        print("warning: the Ghidra MCP server has no authentication; use a non-loopback host only on a trusted network")
    extra = shared_servers() if args.with_shared_servers else {}
    if extra:
        print("Mirroring secret-free servers from ~/.agents/mcp_config.json into Codex / VS Code: "
              + ", ".join(sorted(extra)))
    print()

    configure_claude_code(url, dry)
    cline_forced = {"type": "streamableHttp", "url": url}
    cline_defaults = {"disabled": False, "autoApprove": []}
    merge_json_server("Cline (~/.cline)", p(".cline/data/settings/cline_mcp_settings.json"), "mcpServers",
                      cline_forced, dry, defaults=cline_defaults)
    global_storage = "Library/Application Support/Code/User/globalStorage"
    for extension in ("saoudrizwan.cline-nightly", "saoudrizwan.claude-dev"):
        merge_json_server(f"Cline ({extension})", p(f"{global_storage}/{extension}/settings/cline_mcp_settings.json"),
                          "mcpServers", cline_forced, dry, defaults=cline_defaults)
    merge_json_server("Shared (~/.agents/mcp_config.json)", p(".agents/mcp_config.json"), "mcpServers",
                      {"serverUrl": url}, dry, defaults={"disabled": False})
    merge_json_server("Antigravity / Gemini (~/.gemini/config/mcp_config.json, path inferred)",
                      p(".gemini/config/mcp_config.json"), "mcpServers", {"serverUrl": url}, dry,
                      defaults={"disabled": False})
    merge_json_server("Gemini CLI (~/.gemini/settings.json)", p(".gemini/settings.json"), "mcpServers",
                      {"httpUrl": url}, dry)
    write_server_file(url, dry)
    configure_codex(url, extra, dry)
    configure_vscode(url, extra, dry)
    note("Claude Desktop (chat app)", "manual",
         f"its config only supports stdio; to add Ghidra there use: npx -y mcp-remote {url}")

    print()
    changed = sum(1 for _, status, _ in results if status in ("updated", "dry-run"))
    problems = [r for r in results if r[1] in ("FAILED", "SKIPPED")]
    print(f"{changed} config(s) {'would change' if dry else 'changed'}; {len(problems)} need attention.")
    if changed and not dry:
        print(f"Backups: {short(BACKUP_DIR)}")
        print("Restart each agent (or reload its MCP servers) to pick up the new server.")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
