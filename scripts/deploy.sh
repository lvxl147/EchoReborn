#!/bin/zsh
# Build, install to device, respring. Prints the last build/install lines.
cd ~/Documents/MoarTweaks/CCAster || exit 1
BUILD_OUTPUT=$(make package 2>&1)
if echo "$BUILD_OUTPUT" | grep -q "error"; then
  echo "$BUILD_OUTPUT" | grep -B1 "error" | tail -6
  exit 1
fi
echo "$BUILD_OUTPUT" | grep "building package" | tail -1
DEB=$(ls -t packages/*.deb | head -1)
scp -q "$DEB" root@192.168.0.190:/tmp/latest.deb || exit 1
ssh root@192.168.0.190 "PATH=/var/jb/usr/bin:/var/jb/bin:/usr/bin:/bin dpkg -i /tmp/latest.deb" 2>&1 | tail -1
# sbreload drops the connection mid-respring; ignore its exit status.
ssh root@192.168.0.190 "PATH=/var/jb/usr/bin:/var/jb/bin:/usr/bin:/bin sbreload" > /dev/null 2>&1
echo deployed
