#!/usr/bin/env python3
"""Read an ios-mcp JSON-RPC response on stdin, save image content to argv[1]."""
import sys, json, base64

raw = sys.stdin.read()
try:
    response = json.loads(raw)
except json.JSONDecodeError:
    sys.exit("not json: " + raw[:200])
result = response.get("result")
if not result:
    sys.exit("no result: " + raw[:300])
for item in result.get("content", []):
    if item.get("type") == "image":
        with open(sys.argv[1], "wb") as fh:
            fh.write(base64.b64decode(item["data"]))
        print("saved", sys.argv[1])
        break
else:
    sys.exit("no image in response: " + raw[:300])
