# Simulates installing the Tamlil MCP on a fresh machine with nothing
# preinstalled. The macOS app (swift build, SMAppService, codesign, /Applications)
# cannot run in a Linux container, so this covers only the consumer data-access
# half: empty box -> uv -> `uv tool install` -> a working `tamlil-mcp` that
# Claude can query. Run it with test/container/run.sh.
FROM ubuntu:24.04

# A bare box: curl to bootstrap uv (as the real installer does), git + certs.
# Deliberately no uv and no project deps preinstalled.
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl ca-certificates git xz-utils \
    && rm -rf /var/lib/apt/lists/*

ENV HOME=/root
WORKDIR /repo

# Only the Python package is needed here, not the Swift app or git history.
# pyproject's readme points at README.md and license-files at LICENSE, so the
# build backend needs both.
COPY pyproject.toml uv.lock README.md LICENSE /repo/
COPY src /repo/src
COPY test/container /repo/test/container

CMD ["bash", "/repo/test/container/smoke.sh"]
