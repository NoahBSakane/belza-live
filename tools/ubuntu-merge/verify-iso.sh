#!/bin/sh
# 統合 ISO の中身から層の同一性を検証する(重量級。make test には入れない)。
# 使い方: sh tools/ubuntu-merge/verify-iso.sh
#   (1) 対照: build/layers の層で検証が通ること。
#   (2) 本体: ISO の /casper から取り出した層で検証が通ること。
set -eu
HERE=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
TOOLS=$HERE/tools/ubuntu-merge
ISO=$HERE/build/ubuntu-merge-26.04.1-amd64.iso
LOG=$HERE/build/work/logs/verify-iso.log
TMP=$HERE/build/work/iso-new
WORKBASE=$HERE/build/work/stage/verify-iso-work
[ -f "$ISO" ] || { echo "no ISO: $ISO" >&2; exit 2; }
[ -d "$HERE/build/work/inv" ] || { echo "no inventory" >&2; exit 2; }
mkdir -p "$TMP" "$WORKBASE"
: > "$LOG"
log() { printf '%s %s\n' "$(date '+%m-%d %H:%M:%S')" "$*" | tee -a "$LOG"; }
run_verify() {
    name=$1; newdir=$2
    log "verify from $name"
    rm -rf "$WORKBASE/work-$name"
    if python3 -I "$TOOLS/verify.py" "$HERE/build/work/inv" \
        "$HERE/build/work/plan/ochains.json" "$newdir" \
        "$HERE/build/work/plan/chains.json" "$WORKBASE/work-$name" > "$WORKBASE/$name.log" 2>&1; then
        cat "$WORKBASE/$name.log" | tee -a "$LOG"
    else
        cat "$WORKBASE/$name.log" | tee -a "$LOG"
        return 1
    fi
}
log "control: layers straight from build"
run_verify build "$HERE/build/layers"
log "extract layers from ISO"
rm -rf "$TMP/iso"
mkdir -p "$TMP/iso"
for f in common common.dl common.dl.ubuntu common.dl.lubuntu common.server; do
    xorriso -indev "$ISO" -osirrox on \
        -extract "/casper/$f.squashfs" "$TMP/iso/$f.squashfs" >> "$LOG" 2>&1
done
log "main: layers extracted from ISO"
run_verify iso "$TMP/iso"
log "verify-iso done"
