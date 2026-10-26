#!/bin/sh
# 各試験は独立した領域で実行。テスト数 N に対し起動・集計は O(N)。
set -eu
HERE=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d "$HERE/test-results.XXXXXX")
trap 'rm -rf "$WORK"' 0
trap 'exit 1' HUP INT TERM
cd "$HERE"
TMPDIR=$WORK
PYTHONDONTWRITEBYTECODE=1
BOOTKIT_TEST_LINK_TMPDIR=$WORK
export TMPDIR PYTHONDONTWRITEBYTECODE BOOTKIT_TEST_LINK_TMPDIR
pids=
for test in tests/test-*.sh tests/test-forky-deps.py; do
    # パス試験は全試験をコピーするため、この段階では除き、独立して実行する。
    [ "$test" != tests/test-path-with-space.sh ] || continue
    (
        case "$test" in *.py) python3 "$test" ;; *) sh "$test" ;; esac
    ) > "$WORK/${test##*/}.log" 2>&1 &
    pids="$pids $!"
done
failed=0
for pid in $pids; do wait "$pid" || failed=1; done
for log in "$WORK/"*.log; do printf '\n=== %s ===\n' "${log##*/}"; cat "$log"; done
# コピー対象に終了済み試験のログを残さない。
rm -f "$WORK/"*.log
if ! sh tests/test-path-with-space.sh; then failed=1; fi
exit "$failed"
