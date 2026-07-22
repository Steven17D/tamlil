# SPDX-FileCopyrightText: Copyright 2026 Steven Dashevsky
# SPDX-License-Identifier: Apache-2.0

"""Connect to the installed tamlil-mcp over stdio exactly as Claude Code does,
and assert it serves the staged recording. Launches the production binary
(TAMLIL_MCP_BIN), inheriting the staging env. Fails non-zero on any mismatch."""

import asyncio
import json
import os

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

EXPECTED_TOOLS = ["get_meeting", "get_transcript", "list_meetings", "search_transcripts"]
EXPECTED_TRANSCRIPT = [
    "[0:00] Me: let's review the deploy",
    "[0:02] Maya: the pipeline is green",
    "[0:05] Speaker 2: ship it after standup",
]


def payload(result):
    """Pull the return value out of a CallToolResult. FastMCP wraps non-dict
    returns (list, str) as structuredContent {"result": ...}; dict returns are
    the structuredContent itself. Fall back to parsing the text block."""
    sc = getattr(result, "structuredContent", None)
    if isinstance(sc, dict):
        return sc.get("result", sc)
    if sc is not None:
        return sc
    data = json.loads(result.content[0].text)
    if isinstance(data, dict) and set(data.keys()) == {"result"}:
        return data["result"]
    return data


async def main() -> None:
    params = StdioServerParameters(
        command=os.environ["TAMLIL_MCP_BIN"],
        env=dict(os.environ),
    )
    async with stdio_client(params) as (read, write), ClientSession(read, write) as session:
        await session.initialize()

        tools = sorted(t.name for t in (await session.list_tools()).tools)
        assert tools == EXPECTED_TOOLS, f"tools mismatch: {tools}"
        print(f"tools: {tools}")

        meetings = payload(await session.call_tool("list_meetings", {}))
        ids = [m["id"] for m in meetings]
        assert ids == ["2026-06-10-zoom"], f"meetings mismatch: {ids}"
        assert meetings[0]["title"] == "Deploy review", meetings[0]
        print(f"list_meetings: {ids}")

        transcript = payload(
            await session.call_tool("get_transcript", {"meeting_id": "2026-06-10-zoom"})
        )
        lines = transcript.splitlines()
        assert lines == EXPECTED_TRANSCRIPT, f"transcript mismatch: {lines}"
        print("get_transcript: speaker resolution OK (Me / Maya / Speaker 2)")

        hits = payload(await session.call_tool("search_transcripts", {"query": "pipeline"}))
        assert [h["id"] for h in hits] == ["2026-06-10-zoom"], hits
        print("search_transcripts: hit OK")


asyncio.run(main())
print("mcp_smoke: PASS")
