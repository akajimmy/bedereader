#!/bin/bash
# Runs a test file against the development branch's versions of some lib files (the unfixed code), then restores the
# branch's (committed). The development branch is the newest version branch (1.5, 1.6 ...) unless BASE names another.
# usage: breakcheck_old.sh <test file> <lib files...>
cd /c/Claude/KomgaClient/komga_reader || exit 1
test=$1; shift
base=${BASE:-$(git branch --list | sed 's/^[* +]*//' | grep -E '^[0-9]+\.[0-9]+$' | sort -t. -k1,1n -k2,2n | tail -1)}
if [ -z "$base" ]; then echo "no version branch found - set BASE"; exit 1; fi
if [ -n "$(git status --porcelain -- "$@" "$test")" ]; then echo "uncommitted changes - commit first"; exit 1; fi
echo "old code from: $base"
git checkout "$base" -- "$@"
if [ -n "$HOOK" ]; then python "$HOOK"; fi
timeout 150 /c/Dev/flutter/bin/flutter.bat test "$test" 2>&1 | grep -E "Expected|Actual|\[E\]|passed|failed|Error:" | head -20
git checkout HEAD -- "$@"
git status --short -- "$@"
echo "restored (no changes listed above = same as the commit)"
