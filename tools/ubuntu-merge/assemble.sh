#!/bin/sh
# 統合 ISO を組み立てる。casper/ の新層・initrd・chains・meta、
# boot/grub(統合 grub.cfg)・EFI・.disk・pool(3 OS の和集合)を載せ、
# BIOS+UEFI 起動可能な iso9660 を xorriso で作る。
# 使い方: sh tools/ubuntu-merge/assemble.sh [--no-pool]
#   成果物は build/ubuntu-merge-26.04.1-amd64.iso。
set -eu
HERE=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
SRC=/Users/nbs/Downloads/ubuntu-merge-research-20261029
ROOT=$HERE/build/iso-root
OUT=$HERE/build/ubuntu-merge-26.04.1-amd64.iso
LOG=$HERE/build/work/logs/assemble.log
WITH_POOL=1
if [ "${1:-}" = "--no-pool" ]; then WITH_POOL=0; fi
mkdir -p "$ROOT/casper" "$ROOT/boot/grub" "$ROOT/EFI" "$ROOT/.disk"
mkdir -p "$(dirname "$LOG")"
: > "$LOG"
log() { printf '%s %s\n' "$(date '+%m-%d %H:%M:%S')" "$*" | tee -a "$LOG"; }
die() { log "FATAL: $*"; exit 1; }
[ -f "$HERE/build/layers/common.squashfs" ] || die "no layers"
command -v xorriso >/dev/null 2>&1 || die "no xorriso"

log "stage casper layers"
for f in common common.dl common.dl.ubuntu common.dl.lubuntu common.server; do
    cp "$HERE/build/layers/$f.squashfs" "$ROOT/casper/$f.squashfs"
done
log "stage initrd and vmlinuz"
xorriso -indev "$SRC/ubuntu-26.04.1-desktop-amd64.iso" -osirrox on \
    -extract /casper/initrd "$ROOT/casper/initrd.ubuntu" >> "$LOG" 2>&1
xorriso -indev "$SRC/lubuntu-26.04.1-desktop-amd64.iso" -osirrox on \
    -extract /casper/initrd "$ROOT/casper/initrd.lubuntu" >> "$LOG" 2>&1
xorriso -indev "$SRC/ubuntu-26.04.1-live-server-amd64.iso" -osirrox on \
    -extract /casper/initrd "$ROOT/casper/initrd.server" >> "$LOG" 2>&1
cp "$HERE/build/work/bootimg/vmlinuz-desktop" "$ROOT/casper/vmlinuz"
chmod u+w "$ROOT/casper/"* 2>/dev/null || true

log "stage boot tree from desktop ISO"
# 統合 grub.cfg を退避してから boot ツリーを展開し、戻す。
grubcfg=$(mktemp "$HERE/build/work/grubcfg.XXXXXX")
cp "$ROOT/boot/grub/grub.cfg" "$grubcfg"
xorriso -indev "$SRC/ubuntu-26.04.1-desktop-amd64.iso" -osirrox on \
    -extract /boot "$ROOT/boot" -extract /EFI "$ROOT/EFI" >> "$LOG" 2>&1
chmod -R u+w "$ROOT/boot" "$ROOT/EFI"
cp "$grubcfg" "$ROOT/boot/grub/grub.cfg"
rm -f "$grubcfg"
grep -q "bootkit.os" "$ROOT/boot/grub/grub.cfg" || die "integrated grub.cfg missing"
cp "$HERE/build/work/bootimg/efi.img" "$ROOT/boot/grub/efi.img"

log "stage .disk"
printf '%s\n' 'Ubuntu Merge 26.04.1 LTS "Resolute Raccoon" - Release amd64 (20260826)' > "$ROOT/.disk/info"
# desktop の .disk を土台にする(casper-uuid は desktop の物)。
for f in base_installable casper-uuid-generic cd_type; do
    cp "$ROOT/casper/bootkit-meta/desktop/disk/$f" "$ROOT/.disk/$f"
done

if [ "$WITH_POOL" -eq 1 ]; then
    log "stage pool union"
    mkdir -p "$ROOT/pool"
    chmod -R u+w "$ROOT/pool" 2>/dev/null || true
    for iso in ubuntu-26.04.1-desktop-amd64 lubuntu-26.04.1-desktop-amd64 ubuntu-26.04.1-live-server-amd64; do
        xorriso -indev "$SRC/$iso.iso" -osirrox on \
            -extract /pool "$ROOT/pool" >> "$LOG" 2>&1
        chmod -R u+w "$ROOT/pool"
    done
else
    log "pool skipped (--no-pool)"
fi

log "build iso"
rm -f "$OUT"
xorriso -as mkisofs \
    -o "$OUT" \
    -V 'Ubuntu-Merge 26.04.1 amd64' \
    -r -J -joliet-long -l -iso-level 3 \
    -partition_offset 16 \
    -c boot.catalog \
    -b boot/grub/i386-pc/eltorito.img \
    -no-emul-boot -boot-load-size 4 -boot-info-table \
    -eltorito-alt-boot \
    -e boot/grub/efi.img \
    -no-emul-boot \
    -isohybrid-mbr "$HERE/build/work/bootimg/mbr.bin" \
    -isohybrid-gpt-basdat \
    "$ROOT" >> "$LOG" 2>&1
log "iso done: $(wc -c < "$OUT") bytes"
du -sh "$ROOT/casper" >> "$LOG"
