#!/bin/zsh
# Swipe up within an open Control Center to advance one page, then screenshot.
DIR="${0:a:h}"
NAME="${1:-page}"
"$DIR/mcp.sh" swipe_screen '{"fromX":187,"fromY":600,"toX":187,"toY":250,"duration":0.4}' > /dev/null
sleep 1.5
"$DIR/shot.sh" "$NAME"
