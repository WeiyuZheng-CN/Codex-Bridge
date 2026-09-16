"""MCP web-search bridge for the local Ollama-backed Codex profile.

The Qwen model remains local. Only the web_search and web_fetch tool calls use
Ollama's hosted API, authenticated by a private key file supplied through
OLLAMA_API_KEY_FILE. The key is never printed or persisted by this program.
"""

from __future__ import annotations

import asyncio
import os
import sys
from pathlib import Path
from typing import Any, Dict


def _load_api_key() -> str:
    key_file = os.environ.get("OLLAMA_API_KEY_FILE", "").strip()
    if not key_file:
        raise RuntimeError("OLLAMA_API_KEY_FILE is not configured.")

    path = Path(key_file)
    try:
        lines = [line.strip() for line in path.read_text(encoding="utf-8-sig").splitlines() if line.strip()]
    except OSError as exc:
        raise RuntimeError("The Ollama API-key file could not be read.") from exc

    if len(lines) != 1:
        raise RuntimeError("The Ollama API-key file must contain one non-empty line.")
    return lines[0]


try:
    os.environ["OLLAMA_API_KEY"] = _load_api_key()
except RuntimeError as exc:
    print(f"Ollama web-search MCP startup failed: {exc}", file=sys.stderr)
    raise SystemExit(1) from exc

from ollama import Client

try:
    from mcp.server.fastmcp import FastMCP

    _FASTMCP_AVAILABLE = True
except Exception:
    _FASTMCP_AVAILABLE = False

if not _FASTMCP_AVAILABLE:
    from mcp.server import Server
    from mcp.server.stdio import stdio_server


# The model endpoint is explicit so a user-level OLLAMA_HOST cannot redirect
# the local profile. web_search/web_fetch themselves use ollama.com.
client = Client(host="http://127.0.0.1:11434")


def _web_search_impl(query: str, max_results: int = 3) -> Dict[str, Any]:
    result = client.web_search(query=query, max_results=max_results)
    return result.model_dump()


def _web_fetch_impl(url: str) -> Dict[str, Any]:
    result = client.web_fetch(url=url)
    return result.model_dump()


if _FASTMCP_AVAILABLE:
    app = FastMCP("ollama-search-fetch")

    @app.tool()
    def web_search(query: str, max_results: int = 3) -> Dict[str, Any]:
        """Search the public web through Ollama's hosted search API."""

        return _web_search_impl(query=query, max_results=max_results)

    @app.tool()
    def web_fetch(url: str) -> Dict[str, Any]:
        """Fetch one public web page through Ollama's hosted fetch API."""

        return _web_fetch_impl(url=url)

    if __name__ == "__main__":
        app.run()
else:
    server = Server("ollama-search-fetch")

    @server.tool()
    async def web_search(query: str, max_results: int = 3) -> Dict[str, Any]:
        """Search the public web through Ollama's hosted search API."""

        return await asyncio.to_thread(_web_search_impl, query, max_results)

    @server.tool()
    async def web_fetch(url: str) -> Dict[str, Any]:
        """Fetch one public web page through Ollama's hosted fetch API."""

        return await asyncio.to_thread(_web_fetch_impl, url)

    async def _main() -> None:
        async with stdio_server() as (read, write):
            await server.run(read, write)

    if __name__ == "__main__":
        asyncio.run(_main())
