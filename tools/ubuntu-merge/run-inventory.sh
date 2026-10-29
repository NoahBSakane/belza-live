#!/bin/sh
# 全主要層の抽出と棚卸しを順次行う。長時間かかるためログへ直接書く。
# 使い方: sh tools/ubuntu-merge/run-inventory.sh
set -eu
HERE=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
SRC=/Users/nbs/Downloads/ubuntu-merge-research-20261029
ORIG=$HERE/build/work/orig
INV=$HERE/build/work/inv
STAGE=$HERE/build/work/stage
LOG=$HERE/build/work/logs/inventory.log
mkdir -p "$ORIG" "$INV" "$STAGE" "$(dirname "$LOG")"
log() { printf '%s %s\n' "$(date '+%m-%d %H:%M:%S')" "$*" >> "$LOG"; }
log "inventory start"
# ISO:member:tag の一覧
list='
ubuntu-26.04.1-desktop-amd64.iso:casper/minimal.squashfs:d-minimal
ubuntu-26.04.1-desktop-amd64.iso:casper/minimal.standard.squashfs:d-standard
ubuntu-26.04.1-desktop-amd64.iso:casper/minimal.standard.live.squashfs:d-live
lubuntu-26.04.1-desktop-amd64.iso:casper/minimal.squashfs:l-minimal
lubuntu-26.04.1-desktop-amd64.iso:casper/minimal.standard.squashfs:l-standard
lubuntu-26.04.1-desktop-amd64.iso:casper/minimal.standard.live.squashfs:l-live
ubuntu-26.04.1-live-server-amd64.iso:casper/ubuntu-server-minimal.squashfs:s-minimal
ubuntu-26.04.1-live-server-amd64.iso:casper/ubuntu-server-minimal.ubuntu-server.squashfs:s-server
ubuntu-26.04.1-live-server-amd64.iso:casper/ubuntu-server-minimal.ubuntu-server.installer.squashfs:s-installer
ubuntu-26.04.1-live-server-amd64.iso:casper/ubuntu-server-minimal.ubuntu-server.installer.generic.squashfs:s-generic
'
printf '%s\n' "$list" | grep . | while IFS=: read -r iso mem tag; do
    if [ ! -f "$ORIG/$tag.squashfs" ]; then
        log "extract $tag"
        xorriso -indev "$SRC/$iso" -osirrox on \
            -extract "/$mem" "$ORIG/$tag.squashfs" >> "$LOG" 2>&1
        log "extracted $tag $(wc -c < "$ORIG/$tag.squashfs")"
    else
        log "skip extract $tag (exists)"
    fi
    if [ ! -f "$INV/$tag.jsonl" ]; then
        dir=$STAGE/inv_$tag
        rm -rf "$dir"
        log "pfmeta $tag"
        unsquashfs -pf - "$ORIG/$tag.squashfs" > "$INV/$tag.pfmeta" 2>> "$LOG"
        # デバイスとそのハードリンクは非 root 展開で致命になるため除外する。
        python3 -I "$HERE/tools/ubuntu-merge/pf2pseudo.py" \
            --exclude-file "$INV/$tag.excl" "$INV/$tag.pfmeta" \
            "$INV/$tag.pseudo0" >> "$LOG" 2>&1 || true
        rm -f "$INV/$tag.pseudo0" "$INV/$tag.pfmeta"
        log "unsquashfs $tag excl=$(wc -l < "$INV/$tag.excl")"
        if [ -s "$INV/$tag.excl" ]; then
            unsquashfs -no-xattrs -f -d "$dir" \
                -exclude-file "$INV/$tag.excl" \
                "$ORIG/$tag.squashfs" >> "$LOG" 2>&1 || true
        else
            unsquashfs -no-xattrs -f -d "$dir" \
                "$ORIG/$tag.squashfs" >> "$LOG" 2>&1 || true
        fi
        log "inventory $tag"
        python3 -I "$HERE/tools/ubuntu-merge/inventory.py" \
            "$ORIG/$tag.squashfs" "$tag" "$INV" "$dir" >> "$LOG" 2>&1
        rm -rf "$dir"
        log "done $tag"
    else
        log "skip inventory $tag (exists)"
    fi
done
log "inventory all done"
