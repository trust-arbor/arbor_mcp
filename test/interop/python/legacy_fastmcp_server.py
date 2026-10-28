"""A FastMCP stdio server from the Python SDK, run with an `mcp` that predates
server/discover. `mcp` 1.8.1 exits when that probe arrives before initialize.
"""

from mcp.server.fastmcp import FastMCP

mcp = FastMCP("python-legacy-server")


@mcp.tool()
def echo(text: str) -> str:
    """Echo text."""
    return text


if __name__ == "__main__":
    mcp.run()
