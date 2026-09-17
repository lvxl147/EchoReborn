#!/bin/zsh
# Call an ios-mcp tool on the device: mcp.sh <tool> ['<json-args>']
TOOL="$1"
ARGS="$2"
if [ -z "$ARGS" ]; then ARGS="{}"; fi
curl -s -m 60 -X POST http://192.168.0.190:8090/mcp \
  -H "Content-Type: application/json" \
  -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"$TOOL\",\"arguments\":$ARGS}}"
