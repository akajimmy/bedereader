#!/bin/bash
# Runs a test file against 1.2's versions of some lib files (the unfixed code), then restores the branch's (committed).
# usage: breakcheck_old.sh <test file> <lib files...>
cd /c/Claude/KomgaClient/komga_reader || exit 1
test=$1; shift
if [ -n "$(git status --porcelain -- "$@" "$test")" ]; then echo "uncommitted changes - commit first"; exit 1; fi
git checkout 1.2 -- "$@"
if [ -n "$HOOK" ]; then python "$HOOK"; fi
timeout 150 /c/Dev/flutter/bin/flutter.bat test "$test" 2>&1 | grep -E "Expected|Actual|\[E\]|passed|failed|Error:" | head -20
git checkout HEAD -- "$@"
git status --short -- "$@"
echo "restored (no changes listed above = same as the commit)"
