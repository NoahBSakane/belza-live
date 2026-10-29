#!/bin/sh
# 試作の統合 ISO を組み立てる。
# 本物の 3 ISO の層を T1 と同じ命名規則 (ドット連鎖) で並べ、
# 各 OS の initrd に bootkit-ramsel の premount 一式を入れて再構成する。
# 層の中身は無改変で写すだけ (同一性の検証は T1 の担当)。
#
# 使い方: sh ventoy/ramsel/make-trial-iso.sh
# 入力: $BOOTKIT_ISO_DIR の 3 つの公式 ISO (既定は司令塔取得の置き場)。
# 出力: build/bootkit-ramsel-trial.iso (約 11GB)。
# 中間物 (build/trial-stage、約 11GB) は ISO 化の直後に消す。
# 空きは開始前に確かめ、足りなければ何もせず終わる。
#
# T1 の本番 ISO ができたら、この試作 ISO は捨て、本番 ISO に
# injection アーカイブ (make-injection.sh の成果物) を載せて使う。
set -eu
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
RAMSEL=$HERE/ventoy/ramsel
ISO_DIR=${BOOTKIT_ISO_DIR:-/Users/nbs/Downloads/ubuntu-merge-research-20261029}
BUILD=$HERE/build
STAGE=$BUILD/trial-stage
OUT=$BUILD/bootkit-ramsel-trial.iso
LOG=$BUILD/make-trial-iso.log

DESKTOP_ISO=$ISO_DIR/ubuntu-26.04.1-desktop-amd64.iso
LUBUNTU_ISO=$ISO_DIR/lubuntu-26.04.1-desktop-amd64.iso
SERVER_ISO=$ISO_DIR/ubuntu-26.04.1-live-server-amd64.iso

# 連鎖の合計 (バイト)。QEMU の記録と突き合わせるための確定値。層の中身は同じ。
# ubuntu: 3432136704+590053376+793112576=4815302656
# lubuntu: 2037972992+1691181056+28471296=3757625344
# server: 1335115776+156299264+27041792+98304=1518555136
# 注意: casper の layerfs-path 導出は点を削り続け、点なし名の層まで要求する。
# そのため各連鎖の根は点なし名 (ubuntu・lubuntu・server) にする。

log() {
    printf '%s %s\n' "$(date '+%H:%M:%S')" "$*" | tee -a "$LOG"
}

fail() {
    log "失敗: $*"
    exit 1
}

need() {
    command -v "$1" >/dev/null 2>&1 || fail "道具が無い: $1"
}

mkdir -p "$BUILD"
: >"$LOG"
log "trial ISO の組み立てを開始"
for t in xorriso bsdtar 7zz zstd python3; do need "$t"; done
[ -f "$DESKTOP_ISO" ] || fail "入力が無い: $DESKTOP_ISO"
[ -f "$LUBUNTU_ISO" ] || fail "入力が無い: $LUBUNTU_ISO"
[ -f "$SERVER_ISO" ] || fail "入力が無い: $SERVER_ISO"
sh -n "$RAMSEL/30bootkit-ramsel"
[ -f "$RAMSEL/ORDER" ] || fail "ORDER が無い"

# 開始前の空き (KiB)。段階物と ISO で約 21GB 使う。並行作業と共用のため
# 23GB 未満なら止める。失敗時は段階物を消して空きを戻す。
avail_kb=$(df -k "$BUILD" | awk 'NR==2{ print $4 }')
log "空き: ${avail_kb} KiB"
if [ "$avail_kb" -lt 24117248 ]; then
    fail "空きが 23GB 未満のため止める"
fi

# 前回の読み取り専用の残骸があれば書き込み可にしてから消す (ISO 展開物の権限)。
[ -d "$STAGE" ] && chmod -R u+w "$STAGE"
rm -rf "$STAGE" "$OUT"
mkdir -p "$STAGE/casper" "$STAGE/casper/bootkit-chains"

log "boot 系を desktop ISO から写す"
bsdtar -xf "$DESKTOP_ISO" -C "$STAGE" ./boot ./EFI ./.disk 2>>"$LOG" ||
    fail "boot 系の展開に失敗"
rm -f "$STAGE/boot.catalog"
chmod -R u+w "$STAGE"

log "EFI の FAT イメージを公式から抜く (隠し eltorito 用)"
eval "$(xorriso -indev "$DESKTOP_ISO" -report_el_torito plain 2>&1 | tee -a "$LOG" | awk '/EFI image start and load size/{ print "EFI_LBA=" $10; print "EFI_BLK=" $14 }')"
[ -n "${EFI_LBA:-}" ] && [ -n "${EFI_BLK:-}" ] || fail "EFI イメージの位置が読めない"
dd if="$DESKTOP_ISO" of="$STAGE/boot/grub/efi.img" bs=2048 "skip=$EFI_LBA" "count=$(( (EFI_BLK * 512 + 2047) / 2048 ))" 2>>"$LOG" ||
    fail "EFI イメージの抜き出しに失敗"
python3 -I - "$STAGE/boot/grub/efi.img" <<'PY'
import sys
data = open(sys.argv[1], 'rb').read()
assert data[510:512] == b'\x55\xaa', 'FAT の署名が無い'
assert data[:3][0] in (0xEB, 0xE9), 'FAT の先頭が変だ'
print('efi.img: %d バイト、FAT 署名あり' % len(data))
PY

log "grub.cfg を書く"
# 試作 ISO 現物は timeout=99 に同長 patch 済み (再構築時の値と合わせる)。
cat >"$STAGE/boot/grub/grub.cfg" <<'GRUB'
set timeout=99
set default=0
loadfont unicode
set menu_color_normal=white/black
set menu_color_highlight=black/light-gray
set gfxpayload=keep
menuentry "Ubuntu (RAM select)" {
    linux /casper/vmlinuz boot=casper toram bootkit.os=ubuntu layerfs-path=ubuntu.standard.live.squashfs console=ttyS0,115200 ---
    initrd /casper/initrd.ubuntu
}
menuentry "Lubuntu (RAM select)" {
    linux /casper/vmlinuz boot=casper toram bootkit.os=lubuntu layerfs-path=lubuntu.standard.live.squashfs console=ttyS0,115200 ---
    initrd /casper/initrd.lubuntu
}
menuentry "Ubuntu Server (RAM select)" {
    linux /casper/vmlinuz boot=casper toram bootkit.os=server layerfs-path=server.ubuntu-server.installer.generic.squashfs systemd.unit=multi-user.target console=ttyS0,115200 ---
    initrd /casper/initrd.server
}
if [ "$grub_platform" = "efi" ]; then
menuentry 'Boot from next volume' {
    exit 1
}
menuentry 'UEFI Firmware Settings' {
    fwsetup
}
fi
GRUB

log "連鎖ファイルを書く"
cat >"$STAGE/casper/bootkit-chains/ubuntu.list" <<'LIST'
ubuntu.squashfs
ubuntu.standard.squashfs
ubuntu.standard.live.squashfs
LIST
cat >"$STAGE/casper/bootkit-chains/lubuntu.list" <<'LIST'
lubuntu.squashfs
lubuntu.standard.squashfs
lubuntu.standard.live.squashfs
LIST
cat >"$STAGE/casper/bootkit-chains/server.list" <<'LIST'
server.squashfs
server.ubuntu-server.squashfs
server.ubuntu-server.installer.squashfs
server.ubuntu-server.installer.generic.squashfs
LIST

# 層の写し。srcISO内の名前 src名 -> 試作名。
copy_layer() {
    # $1: ISO、$2: ISO 内の層名、$3: 試作名
    log "層: $2 -> $3"
    bsdtar -xOf "$1" "casper/$2.squashfs" >"$STAGE/casper/$3.squashfs" 2>>"$LOG" ||
        fail "層の写しに失敗: $2"
    for ext in manifest manifest.full size; do
        if bsdtar -xOf "$1" "casper/$2.$ext" >"$STAGE/casper/$3.$ext" 2>/dev/null; then
            :
        else
            rm -f "$STAGE/casper/$3.$ext"
        fi
    done
}

copy_layer "$DESKTOP_ISO" minimal ubuntu
copy_layer "$DESKTOP_ISO" minimal.standard ubuntu.standard
copy_layer "$DESKTOP_ISO" minimal.standard.live ubuntu.standard.live
copy_layer "$LUBUNTU_ISO" minimal lubuntu
copy_layer "$LUBUNTU_ISO" minimal.standard lubuntu.standard
copy_layer "$LUBUNTU_ISO" minimal.standard.live lubuntu.standard.live
copy_layer "$SERVER_ISO" ubuntu-server-minimal server
copy_layer "$SERVER_ISO" ubuntu-server-minimal.ubuntu-server server.ubuntu-server
copy_layer "$SERVER_ISO" ubuntu-server-minimal.ubuntu-server.installer server.ubuntu-server.installer
copy_layer "$SERVER_ISO" ubuntu-server-minimal.ubuntu-server.installer.generic server.ubuntu-server.installer.generic

log "vmlinuz を写す (3 ISO で同一ハッシュ)"
bsdtar -xOf "$DESKTOP_ISO" casper/vmlinuz >"$STAGE/casper/vmlinuz" 2>>"$LOG" ||
    fail "vmlinuz の写しに失敗"

log "initrd を OS ごとに再構成する (premount 注入)"
rebuild_initrd() {
    # $1: 公式 ISO、$2: タグ、$3: 出力
    BOOTKIT_RAMSEL_SRC=$RAMSEL BOOTKIT_RAMSEL_LOG=$LOG \
        python3 -I "$RAMSEL/rebuild-initrd.py" "$1" "$2" "$3" >>"$LOG" 2>&1 ||
        fail "initrd 再構成に失敗: $2"
}
rebuild_initrd "$DESKTOP_ISO" ubuntu "$STAGE/casper/initrd.ubuntu"
rebuild_initrd "$LUBUNTU_ISO" lubuntu "$STAGE/casper/initrd.lubuntu"
rebuild_initrd "$SERVER_ISO" server "$STAGE/casper/initrd.server"
log "ISO 化する"
if ! xorriso -as mkisofs -r -V BOOTKIT_RAMSEL_TRIAL -J -joliet-long \
    -b boot/grub/i386-pc/eltorito.img -c boot.catalog -no-emul-boot \
    -boot-load-size 4 -boot-info-table --grub2-boot-info \
    -eltorito-alt-boot -e boot/grub/efi.img -no-emul-boot \
    -o "$OUT" "$STAGE" >>"$LOG" 2>&1; then
    rm -rf "$STAGE"
    fail "ISO 化に失敗 (段階物を消した)"
fi
log "段階物を消す"
rm -rf "$STAGE"
size=$(wc -c <"$OUT")
log "完成: $OUT ($size バイト)"
df -h "$BUILD" | tee -a "$LOG"
