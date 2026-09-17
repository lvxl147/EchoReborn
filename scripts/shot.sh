#!/bin/zsh
# Capture a device screenshot to EchoReborn/scripts/shots/<name>.jpg
DIR="${0:a:h}"
NAME="${1:-shot}"
mkdir -p "$DIR/shots"
"$DIR/mcp.sh" screenshot > /tmp/ershot.json
/usr/bin/python3 "$DIR/save_shot.py" "$DIR/shots/$NAME.jpg" < /tmp/ershot.json
