#!/bin/bash
# 1.2.2-73 · 每次构建后自动备份：提交 + 打标签（有凭据时自动推送）。
set -u
cd "$(dirname "$0")/.." || exit 1
VERSION=$(grep -m1 '^Version:' control | awk '{print $2}')
[ -z "${VERSION:-}" ] && { echo "no version"; exit 1; }

git add -A
git -c user.name='EchoReborn Build' -c user.email='build@local' commit -m "build: ${VERSION}" >/dev/null 2>&1
git tag -f "v${VERSION}" >/dev/null 2>&1
echo "committed + tagged v${VERSION}"

if git push origin main >/dev/null 2>&1 && git push -f origin "v${VERSION}" >/dev/null 2>&1; then
    echo "pushed v${VERSION} to origin"
else
    echo "push skipped (no credentials) — local commit kept"
fi
