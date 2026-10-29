#!/bin/sh
# bootkit-ramsel の injection アーカイブを作る。
# Ventoy の injection はこの tar.gz を initramfs の / に展開する。
# 使い方: sh ventoy/ramsel/make-injection.sh [出力.tar.gz]
# 既定の出力: ventoy/ramsel/bootkit-ramsel-injection.tar.gz
set -eu
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
SRC=$HERE/ventoy/ramsel
OUT=${1:-$SRC/bootkit-ramsel-injection.tar.gz}
WORK=$(mktemp -d "$HERE/ventoy/ramsel/.injection.XXXXXX")
trap 'rm -rf "$WORK"' 0
trap 'exit 1' HUP INT TERM
sh -n "$SRC/30bootkit-ramsel"
mkdir -p "$WORK/scripts/casper-premount"
cp "$SRC/30bootkit-ramsel" "$WORK/scripts/casper-premount/30bootkit-ramsel"
cp "$SRC/ORDER" "$WORK/scripts/casper-premount/ORDER"
chmod 755 "$WORK/scripts/casper-premount/30bootkit-ramsel"
chmod 644 "$WORK/scripts/casper-premount/ORDER"
tar -czf "$OUT" -C "$WORK" scripts
printf 'wrote %s (%s bytes)\n' "$OUT" "$(wc -c <"$OUT")"
tar -tzf "$OUT"
