#!/bin/bash
# macOS で、Mac に接続した USB の Ventoy を更新する(MBR のディスク)。update-ventoy-mbr.py を、検査つきで呼ぶ。
# 使い方: bash ventoy/update-ventoy-mac.sh <ボリューム名> <展開した ventoy-X.Y.Z のフォルダ> [退避先フォルダ]
# 途中で sudo のパスワードを聞かれる。第 1 パーティション(ISO などのデータ)には触れない。
set -eu
VOL=${1:?ボリューム名(例: /Volumes の下の名前)を指定してください}
VD=${2:?展開した ventoy-X.Y.Z のフォルダを指定してください}
HERE="$(cd "$(dirname "$0")" && pwd)"
BK=${3:-"$PWD/ventoy-backup-$(date +%Y%m%d-%H%M%S)"}
V="/Volumes/$VOL"
[ -d "$V" ] || { echo "$V が見えません。USB を差し直してください" >&2; exit 1; }
[ -f "$VD/boot/boot.img" ] || { echo "Ventoy の配布物ではありません: $VD" >&2; exit 1; }
DISK=$(diskutil info "$V" | awk -F': *' '/Part of Whole/{print $2}')
case "$DISK" in disk[0-9]*) ;; *) echo "ディスク名を特定できない: $DISK" >&2; exit 1;; esac
INFO=$(diskutil info "$DISK")
echo "$INFO" | grep -q "Device Location:.*External" || { echo "外付けでない: $DISK" >&2; exit 1; }
echo "$INFO" | grep -q "Protocol:.*USB" || { echo "USB でない: $DISK" >&2; exit 1; }
echo "対象: $DISK ($(echo "$INFO" | awk -F': *' '/Device \/ Media Name/{print $2}'))  ボリューム: $V"
sync
diskutil unmountDisk "$DISK"
echo "--- 検査(書き込みなし)"
sudo python3 -I "$HERE/update-ventoy-mbr.py" --ventoy-dir "$VD" "/dev/r$DISK"
echo "--- 更新(退避 → 書き込み → 読み戻し照合)"
sudo python3 -I "$HERE/update-ventoy-mbr.py" --ventoy-dir "$VD" --backup-dir "$BK" --apply "/dev/r$DISK"
diskutil mountDisk "$DISK" >/dev/null || true
echo "完了。退避: $BK"
