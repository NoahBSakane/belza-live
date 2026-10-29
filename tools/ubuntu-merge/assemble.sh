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
avail_kb=$(df -k "$HERE/build" | awk 'NR==2 {print $4}')
# 10GiB を残す。既存 ISO は数 MiB の追記、新規は ISO と pool の段階物も見込む。
need_kb=10500000
if [ ! -f "$OUT" ]; then
    need_kb=26214400
    [ "$WITH_POOL" -eq 1 ] || need_kb=20971520
fi
[ "$avail_kb" -ge "$need_kb" ] || die "空き容量不足: ${avail_kb} KiB (必要 ${need_kb})"

# 更新では ISO 全体・層・pool を複製せず、少量の差分だけを追記する。
if [ -f "$OUT" ]; then
    [ "$WITH_POOL" -eq 1 ] || die "--no-pool は新規作成専用。既存 ISO の pool は変更しない"
    log "update ISO in place"
    mkdir -p "$ROOT/casper" "$ROOT/.disk" "$ROOT/boot/grub"
    python3 -I "$HERE/ventoy/ramsel/make-cpio.py" "$ROOT/casper/bootkit-ramsel.cpio.gz"
    python3 -I "$HERE/tools/ubuntu-merge/grub.py" > "$ROOT/boot/grub/grub.cfg"
    for pair in 'ubuntu:ubuntu-26.04.1-desktop-amd64' 'lubuntu:lubuntu-26.04.1-desktop-amd64' 'server:ubuntu-26.04.1-live-server-amd64'; do
        os=${pair%%:*}; iso=${pair#*:}
        xorriso -indev "$SRC/$iso.iso" -osirrox on -extract /.disk/casper-uuid-generic "$ROOT/.disk/casper-uuid-$os" >> "$LOG" 2>&1
    done
    xorriso -dev "$OUT" -boot_image any replay \
        -map "$ROOT/boot/grub/grub.cfg" /boot/grub/grub.cfg \
        -map "$ROOT/casper/bootkit-ramsel.cpio.gz" /casper/bootkit-ramsel.cpio.gz \
        -map "$ROOT/.disk" /.disk >> "$LOG" 2>&1
    python3 -I "$HERE/tools/ubuntu-merge/fix-pvd.py" "$OUT" >> "$LOG" 2>&1
    xorriso -indev "$OUT" -ls /casper -- >> "$LOG" 2>&1
    log "iso updated: $(wc -c < "$OUT") bytes"
    exit 0
fi

log "stage casper layers"
for f in common common.dl common.dl.ubuntu common.dl.lubuntu common.server; do
    ln -f "$HERE/build/layers/$f.squashfs" "$ROOT/casper/$f.squashfs"
done
log "stage initrd and vmlinuz"
xorriso -indev "$SRC/ubuntu-26.04.1-desktop-amd64.iso" -osirrox on \
    -extract /casper/initrd "$ROOT/casper/initrd.ubuntu" >> "$LOG" 2>&1
xorriso -indev "$SRC/lubuntu-26.04.1-desktop-amd64.iso" -osirrox on \
    -extract /casper/initrd "$ROOT/casper/initrd.lubuntu" >> "$LOG" 2>&1
xorriso -indev "$SRC/ubuntu-26.04.1-live-server-amd64.iso" -osirrox on \
    -extract /casper/initrd "$ROOT/casper/initrd.server" >> "$LOG" 2>&1
cp "$HERE/build/work/bootimg/vmlinuz-desktop" "$ROOT/casper/vmlinuz"
chmod u+w "$ROOT/casper/"initrd.* "$ROOT/casper/vmlinuz"

log "stage boot tree from desktop ISO"
# 統合 grub.cfg を退避してから boot ツリーを展開し、戻す。
grubcfg=$(mktemp "$HERE/build/work/grubcfg.XXXXXX")
python3 -I "$HERE/tools/ubuntu-merge/grub.py" > "$grubcfg"
xorriso -indev "$SRC/ubuntu-26.04.1-desktop-amd64.iso" -osirrox on \
    -extract /boot "$ROOT/boot" -extract /EFI "$ROOT/EFI" >> "$LOG" 2>&1
chmod -R u+w "$ROOT/boot" "$ROOT/EFI"
cp "$grubcfg" "$ROOT/boot/grub/grub.cfg"
rm -f "$grubcfg"
grep -q "bootkit.os" "$ROOT/boot/grub/grub.cfg" || die "integrated grub.cfg missing"
cp "$HERE/build/work/bootimg/efi.img" "$ROOT/boot/grub/efi.img"

python3 -I "$HERE/ventoy/ramsel/make-cpio.py" "$ROOT/casper/bootkit-ramsel.cpio.gz"

log "stage .disk"
printf '%s\n' 'Ubuntu Merge 26.04.1 LTS "Resolute Raccoon" - Release amd64 (20260826)' > "$ROOT/.disk/info"
# 各公式 initrd が要求する UUID をすべて残す。matches_uuid は接尾辞を問わない。
for pair in 'ubuntu:ubuntu-26.04.1-desktop-amd64' 'lubuntu:lubuntu-26.04.1-desktop-amd64' 'server:ubuntu-26.04.1-live-server-amd64'; do
    os=${pair%%:*}; iso=${pair#*:}
    xorriso -indev "$SRC/$iso.iso" -osirrox on -extract /.disk/casper-uuid-generic "$ROOT/.disk/casper-uuid-$os" >> "$LOG" 2>&1
done
for pair in 'desktop:ubuntu-26.04.1-desktop-amd64' 'lubuntu:lubuntu-26.04.1-desktop-amd64' 'server:ubuntu-26.04.1-live-server-amd64'; do
    os=${pair%%:*}; iso=${pair#*:}
    python3 -I "$HERE/tools/ubuntu-merge/stage-meta.py" "$SRC/$iso.iso" "$ROOT/casper/bootkit-meta/$os" >> "$LOG" 2>&1
done
for f in base_installable cd_type; do
    cp "$ROOT/casper/bootkit-meta/desktop/disk/$f" "$ROOT/.disk/$f"
done
# 連鎖は再生成した層の計画から作る。
python3 -I - "$HERE" "$ROOT" <<'PYMETA'
import json, pathlib, sys
here, root = map(pathlib.Path, sys.argv[1:])
chains = json.loads((here / 'build/work/plan/chains.json').read_text())
dest = root / 'casper/bootkit-chains'
dest.mkdir(parents=True, exist_ok=True)
for osname, chain in chains.items():
    osname = {'desktop': 'ubuntu'}.get(osname, osname)
    (dest / (osname + '.list')).write_text(''.join(x + '.squashfs\n' for x in chain))
PYMETA

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
# 新規 ISO だけを作る (既存 ISO の削除・複製はしない)。
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
