#!/bin/sh
# Create a new regular file only; never format an existing file or device.
set -eu
allow_external=false
case "${1:-}" in --allow-external) allow_external=true; shift ;; esac
if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    echo '使い方: make-persistence.sh [--allow-external] <出力ファイル> [サイズMiB: 4096]' >&2
    exit 2
fi
output=$1
size=${2:-4096}
case "$size" in ''|*[!0-9]*) echo 'サイズは正の整数です' >&2; exit 2 ;; esac
if [ "$size" -lt 16 ] || [ "$size" -gt 1048576 ]; then
    echo 'サイズは 16〜1048576 MiB で指定してください' >&2
    exit 2
fi
case "$output" in
    /Volumes/*) $allow_external || { echo '/Volumes/ への直接作成は拒否します' >&2; exit 1; } ;;
esac
parent=$(CDPATH='' cd -P -- "$(dirname -- "$output")" && pwd)
output=$parent/$(basename -- "$output")
case "$output" in
    /Volumes/*) $allow_external || { echo '/Volumes/ への直接作成は拒否します' >&2; exit 1; } ;;
    /dev/*) echo 'デバイスへの書き込みは拒否します' >&2; exit 1 ;;
esac
if [ -e "$output" ] || [ -L "$output" ]; then
    echo '既存の出力先は上書きしません' >&2
    exit 1
fi
case "$(uname -s)" in
    Linux)
        if ! command -v truncate >/dev/null 2>&1 || ! command -v mkfs.ext4 >/dev/null 2>&1; then
            echo 'truncate と e2fsprogs (mkfs.ext4) を導入してください' >&2; exit 77
        fi
        formatter=mkfs.ext4 ;;
    Darwin)
        formatter=/opt/homebrew/opt/e2fsprogs/sbin/mke2fs
        [ -x "$formatter" ] || {
            echo 'brew install e2fsprogs を実行してください' >&2; exit 77;
        } ;;
    *) echo 'Linux または macOS が必要です' >&2; exit 77 ;;
esac
# noclobber reserves a new regular file, before -F is ever used.
(set -C; : > "$output") || exit 1
complete=false
trap '$complete || rm -f -- "$output"' 0
trap 'exit 1' HUP INT TERM
if [ "$formatter" = mkfs.ext4 ]; then
    truncate -s "${size}M" "$output"
    mkfs.ext4 -F -L casper-rw "$output"
else
    # mke2fs accepts a block count: 1024 blocks of 1 KiB per MiB.
    "$formatter" -t ext4 -F -L casper-rw -b 1024 "$output" "$((size * 1024))"
fi
complete=true
printf '作成: %s (%s MiB, ext4, casper-rw)\n' "$output" "$size"
