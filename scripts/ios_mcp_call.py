#!/usr/bin/env python3
import json
import sys
import urllib.request


def main():
    if len(sys.argv) < 2:
        raise SystemExit("usage: ios_mcp_call.py TOOL [JSON_ARGS] [HOST]")
    tool = sys.argv[1]
    args = json.loads(sys.argv[2]) if len(sys.argv) > 2 else {}
    host = sys.argv[3] if len(sys.argv) > 3 else "192.168.0.190"
    body = json.dumps({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "tools/call",
        "params": {
            "name": tool,
            "arguments": args,
        },
    }).encode()
    request = urllib.request.Request(
        f"http://{host}:8090/mcp",
        data=body,
        headers={
            "Content-Type": "application/json",
            "MCP-Protocol-Version": "2025-11-25",
        },
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=35) as response:
        print(json.dumps(json.load(response), indent=2))


if __name__ == "__main__":
    main()
