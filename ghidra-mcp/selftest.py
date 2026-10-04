#!/usr/bin/env python3
"""Self-test for the shared Ghidra MCP server: connect, import, analyze, decompile, search.

Usage:  ghidra-mcp selftest [--binary /usr/bin/true] [--url http://127.0.0.1:8000/mcp] [--wait 900]

Imports a harmless system binary (analysis only; it is never executed) and checks every stage.
Runs with the pyghidra-mcp tool's own Python, so the `mcp` client library is already available.
The test program stays in the shared project; remove it with the delete_project_binary tool if wanted.
"""

import argparse
import asyncio
import json
import os
import sys
import time
from datetime import timedelta

from mcp import ClientSession
from mcp.client.streamable_http import streamablehttp_client

TIMEOUT = timedelta(seconds=900)
MIN_TOOLS = 15


def text_of(result):
    return "".join(getattr(c, "text", "") or "" for c in result.content)


def parse_json(text, default):
    try:
        return json.loads(text)
    except ValueError:
        return default


def find_program(listing, base):
    data = parse_json(listing, {})
    programs = data.get("programs", []) if isinstance(data, dict) else []
    for program in programs:
        name = program.get("name") if isinstance(program, dict) else program
        if isinstance(name, str) and name.lstrip("/").startswith(base):
            return name
    return None


def first_function(listing):
    data = parse_json(listing, {})
    symbols = data.get("symbols", []) if isinstance(data, dict) else []
    first = symbols[0] if symbols else None
    return first.get("name") if isinstance(first, dict) else None


async def run(url, binary, wait):
    results = []

    def check(name, ok, detail=""):
        results.append(bool(ok))
        print(f"  [{'PASS' if ok else 'FAIL'}] {name}" + (f" - {detail}" if detail else ""), flush=True)

    transport = streamablehttp_client(url, timeout=TIMEOUT, sse_read_timeout=TIMEOUT)
    async with transport as (read, write, _), ClientSession(read, write) as session:
        info = await session.initialize()
        tools = [t.name for t in (await session.list_tools()).tools]
        server = f"{info.serverInfo.name} {info.serverInfo.version}"
        check("connect and list tools", len(tools) >= MIN_TOOLS, f"{server}, {len(tools)} tools")

        async def call(name, args):
            result = await session.call_tool(name, args, read_timeout_seconds=timedelta(seconds=300))
            return result.isError, text_of(result)

        base = os.path.basename(binary)
        err, out = await call("list_project_binaries", {})
        name = None if err else find_program(out, base)
        if name:
            print(f"  (reusing existing project program {name})")
        else:
            err, out = await call("import_binary", {"binary_path": binary})
            check("import accepted", not err, " ".join(out.split())[:100])
            deadline = time.time() + wait
            while not name and time.time() < deadline:
                await asyncio.sleep(3)
                err, out = await call("list_project_binaries", {})
                name = None if err else find_program(out, base)
        check("binary present in project", name, name or "timed out waiting for import")
        if not name:
            return all(results)

        meta = {}
        deadline = time.time() + wait
        while True:
            err, out = await call("list_project_binary_metadata", {"binary_name": name})
            meta = parse_json(out, {}) if not err else {}
            if meta.get("Analyzed") == "true" or time.time() >= deadline:
                break
            await asyncio.sleep(3)
        detail = f"{meta.get('Executable Format')}, {meta.get('Language ID')}, {meta.get('# of Functions')} functions"
        check("analysis finished", meta.get("Analyzed") == "true", detail)

        query = {"binary_name": name, "query": ".*", "functions_only": True, "limit": 5}
        err, out = await call("search_symbols_by_name", query)
        target = None if err else first_function(out)
        check("function symbols found", target, target or "none")

        if target:
            err, out = await call("decompile_function", {"binary_name": name, "name_or_address": target})
            code = parse_json(out, {}).get("code", "") if not err else ""
            missing = "EMPTY: the native decompiler is missing; run build_natives_macos.sh"
            check("decompile returns code", code.strip(), "ok" if code.strip() else missing)

        # Code and string indexing need ChromaDB's one-time embedding model (~83 MB download on first use).
        deadline = time.time() + wait
        while True:
            err, out = await call("search_strings", {"binary_name": name, "query": ".", "limit": 3})
            if not err or time.time() >= deadline:
                break
            await asyncio.sleep(5)
        stalled = "still indexing (is the model download stalled? see ghidra-mcp logs)"
        check("string/code indexing finished", not err, "ok" if not err else stalled)
        if not err:
            query = {"binary_name": name, "query": "return", "search_mode": "literal", "limit": 2,
                     "include_full_code": False}
            err, out = await call("search_code", query)
            check("code search works", not err, "ok" if not err else out[:100])
    return all(results)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--binary", default="/usr/bin/true")
    ap.add_argument("--url", default="http://127.0.0.1:8000/mcp")
    ap.add_argument("--wait", type=int, default=900, help="seconds to wait for each slow stage")
    args = ap.parse_args()
    print(f"Ghidra MCP self-test against {args.url} using {args.binary}")
    try:
        ok = asyncio.run(run(args.url, args.binary, args.wait))
    except Exception as e:  # noqa: BLE001 - any failure to reach or drive the server is reported, not raised
        print(f"  [FAIL] could not complete: {type(e).__name__}: {e}")
        print("         Is the server running?  ghidra-mcp status | start | logs")
        sys.exit(2)
    print("\nRESULT: " + ("ALL CHECKS PASSED" if ok else "SOME CHECKS FAILED"))
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
