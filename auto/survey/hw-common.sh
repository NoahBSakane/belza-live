#!/bin/sh
# 調査コマンド共通の読み取り処理。
export LC_ALL=C
HW_SYSFS=${HW_SYSFS:-/sys}
HW_PROC=${HW_PROC:-/proc}
read_value() {
    if [ -r "$1" ] && value=$(cat "$1" 2>/dev/null) && [ -n "$value" ]; then
        printf '%s' "$value" | tr '\n\t' '  ' | sed 's/^ *//;s/ *$//'
    else
        printf '%s' 不明
    fi
}
missing() { printf '未取得: %sなし\n' "$1"; }
disks() {
    for blk in "$HW_SYSFS"/block/*; do
        [ -e "$blk" ] || continue
        name=${blk##*/}
        case "$name" in loop*|ram*|sr*|zram*|fd*|md*|dm-*) continue ;; esac
        printf '%s\n' "$name"
    done
}
connection() {
    real=$(readlink -f "$HW_SYSFS/block/$1" 2>/dev/null)
    case "$real" in
        */usb*) printf usb ;;
        */nvme*) printf nvme ;;
        */ata*) printf ata ;;
        */virtio*) printf virtio ;;
        *) printf 不明 ;;
    esac
}
# Live のマウント元から祖先をたどる。mapper/ventoy やパーティションも含む。
boot_disks() {
    sources=$(
        if [ -r "$HW_PROC/mounts" ]; then
            awk '$2 == "/run/live/medium" || $2 == "/lib/live/mount/medium" {print $1}' "$HW_PROC/mounts"
        fi
        if [ -r "$HW_PROC/self/mountinfo" ]; then
            awk '$5 == "/run/live/medium" || $5 == "/lib/live/mount/medium" {
                for (i=6;i<=NF;i++) if ($i=="-") {print $(i+2); break}
            }' "$HW_PROC/self/mountinfo"
        fi
    )
    if [ -z "$sources" ] && command -v findmnt >/dev/null 2>&1; then
        sources=$(findmnt -n -o SOURCE /run/live/medium 2>/dev/null) || :
    fi
    [ -n "$sources" ] || { printf '%s\n' '!起動媒体未判定'; return; }
    for source in $sources; do
        ancestors=
        if command -v lsblk >/dev/null 2>&1; then
            ancestors=$(lsblk -snro KNAME "$source" 2>/dev/null) || :
        fi
        base=${source##*/}
        resolved=0
        for disk in $(disks); do
            if [ "$base" = "$disk" ] || [ -e "$HW_SYSFS/block/$disk/$base/partition" ] ||
                printf '%s\n' "$ancestors" | grep -Fqx "$disk"; then
                printf '%s\n' "$disk"
                resolved=1
            fi
        done
        [ "$resolved" = 1 ] || printf '%s\n' '!起動媒体未判定'
    done
    return 0
}
is_boot() { printf '%s\n' "$BOOT_DISKS" | grep -Fqx "$1"; }
capacity() {
    sectors=$(read_value "$HW_SYSFS/block/$1/size")
    awk -v s="$sectors" 'BEGIN {if(s ~ /^[0-9]+$/) printf "%.2f GB / %.2f GiB",s*512/1e9,s*512/1073741824; else printf "不明"}'
}
smart_data() {
    if ! command -v smartctl >/dev/null 2>&1; then missing smartctl; return; fi
    smart=$(smartctl -i -H -A "/dev/$1" 2>&1) || :
    if [ "$(connection "$1")" = usb ] &&
        ! printf '%s\n' "$smart" | grep -Eq 'SMART overall-health|SMART Health Status:|^[ ]*[0-9]+[ ]+[A-Za-z_]+[ ]+0x'; then
        smart=$(smartctl -d sat -i -H -A "/dev/$1" 2>&1) || :
    fi
    printf '%s\n' "$smart"
}
smart_health() {
    awk '/SMART overall-health.*result:|SMART Health Status:/ {sub(/^.*(result:|Status:)[ ]*/, ""); print; found=1; exit}
        END {if(!found) print "不明"}'
}
sata_link() {
    sed -n 's/.*SATA Version.*current: *\([0-9.]*\) *Gb\/s.*/\1Gb\/s/p' | head -n 1
}
smart_attributes() {
    awk '$1 ~ /^[0-9]+$/ && $2 ~ /^[A-Za-z_]+$/ && $3 ~ /^0x/ {
        id=$1+0
        if(id==5||id==10||id==196||id==9||id==12||id==177||id==231||id==233||id==187||id==188||id==194||id==197||id==198||id==199||id==241||id==242) {
            raw=$10; for(i=11;i<=NF;i++) raw=raw " " $i
            warn=($6+0>0 && $4+0<=$6+0)||($9!="-" && $9!="")
            printf "SMART %s %s: %s%s\n",id,$2,raw,warn?" [しきい値警告]":""
        }
    }'
}

# 自己診断・速度測定は共通で内蔵の固定媒体だけに限定する。
internal_disks() {
    BOOT_DISKS=$(boot_disks)
    printf '%s\n' "$BOOT_DISKS" | grep -Fqx '!起動媒体未判定' && return 0
    for candidate in $(disks); do
        is_boot "$candidate" && continue
        [ "$(connection "$candidate")" != usb ] || continue
        [ "$(read_value "$HW_SYSFS/block/$candidate/removable")" = 0 ] || continue
        printf '%s\n' "$candidate"
    done
}
