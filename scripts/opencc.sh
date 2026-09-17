#!/bin/zsh
# Open Control Center (swipe down from top-right), then screenshot as cc.jpg
DIR="${0:a:h}"
"$DIR/mcp.sh" swipe_screen '{"fromX":355,"fromY":0,"toX":355,"toY":650,"duration":1.0}'
echo
sleep 2
"$DIR/shot.sh" cc
