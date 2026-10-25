#!/bin/sh
# disk-guard.sh — ディスクを消す無人インストールの前に、対象のディスクが想定どおりかを確かめる。
# 1 つでも想定と違えば、何も消さずに、終了コード 1 で終わる(preseed 側で、電源を切る)。
#
# 使い方: disk-guard.sh --expect "sda:MIN_GB:MAX_GB[:MODEL],sdb:MIN_GB:MAX_GB[:MODEL],..." [--sysfs /sys]
#   MIN_GB・MAX_GB: 容量(10 進の GB)の下限と上限。数字でなければ、失敗する(例の MIN・MAX を、書き換えないと通らない)。
#   MODEL:          省略可。ディスクの型番(/sys/block/<名前>/device/model)に含まれるべき文字列(大文字・小文字は区別しない)。
# 確かめること(すべて満たす必要がある):
#   1. 指定した全ディスクが存在する。
#   2. USB 接続でない(sysfs の実体のパスに "/usb" を含まない)。Ventoy の USB など、取り外せる媒体を消さないため。
#   3. 取り外し可能(removable)の印がない。
#   4. 容量が、下限と上限の範囲内。
#   5. 型番の指定があれば、型番に含まれる。
#   6. 区画の名前(ラベル)に Ventoy・VTOYEFI を含むものがない(blkid がある場合)。
set -u
SYSFS=/sys
EXPECT=
while [ $# -gt 0 ]; do
	case "$1" in
		--expect) EXPECT="$2"; shift 2 ;;
		--sysfs) SYSFS="$2"; shift 2 ;;
		*) echo "disk-guard: unknown option: $1" >&2; exit 2 ;;
	esac
done
[ -n "$EXPECT" ] || { echo "disk-guard: --expect is required" >&2; exit 2; }

fail=0
bad() { echo "disk-guard: NG: $*" >&2; fail=1; }

IFS_SAVE=$IFS
IFS=,
set -- $EXPECT
IFS=$IFS_SAVE
for entry in "$@"; do
	dev=${entry%%:*}
	rest=${entry#*:}
	min=${rest%%:*}
	rest=${rest#*:}
	max=${rest%%:*}
	model=
	case "$rest" in *:*) model=${rest#*:} ;; esac
	[ "$dev" != "$entry" ] || { bad "bad entry: $entry"; continue; }
	case "$min$max" in *[!0-9]* | "") bad "$dev: MIN/MAX must be numbers (got '$min' '$max')"; continue ;; esac
	blk="$SYSFS/block/$dev"
	[ -e "$blk" ] || { bad "$dev: not found"; continue; }
	real=$(readlink -f "$blk" 2>/dev/null || echo "$blk")
	case "$real" in */usb*) bad "$dev: USB-attached ($real)"; continue ;; esac
	rem=$(cat "$blk/removable" 2>/dev/null || echo 1)
	[ "$rem" = 0 ] || { bad "$dev: removable media"; continue; }
	sectors=$(cat "$blk/size" 2>/dev/null || echo 0)
	gb=$((sectors * 512 / 1000000000))
	if [ "$gb" -lt "$min" ] || [ "$gb" -gt "$max" ]; then bad "$dev: size ${gb}GB is outside ${min}-${max}GB"; continue; fi
	if [ -n "$model" ]; then
		have=$(cat "$blk/device/model" 2>/dev/null || echo)
		case "$(echo "$have" | tr 'A-Z' 'a-z')" in
			*"$(echo "$model" | tr 'A-Z' 'a-z')"*) : ;;
			*) bad "$dev: model '$have' does not contain '$model'"; continue ;;
		esac
	fi
	if command -v blkid >/dev/null 2>&1 && [ "$SYSFS" = /sys ]; then
		if blkid "/dev/$dev"* 2>/dev/null | grep -qi -E 'LABEL="?(Ventoy|VTOYEFI)'; then bad "$dev: has a Ventoy partition"; continue; fi
	fi
	echo "disk-guard: OK: $dev ${gb}GB ${model:+model~$model }$(echo "$real" | sed 's|.*/devices/||' | cut -c1-60)" >&2
done
[ "$fail" = 0 ] || { echo "disk-guard: REFUSING to continue (nothing was changed)" >&2; exit 1; }
exit 0
