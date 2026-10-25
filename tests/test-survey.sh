#!/bin/sh
# 実機には触れず、偽 sysfs/proc と外部コマンドで実行する。
set -eu
HERE=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-$HERE}/test-survey.XXXXXX")
trap 'rm -rf "$WORK"' 0
trap 'exit 1' HUP INT TERM
SURVEY_SOURCE=${SURVEY_SOURCE:-$HERE/auto/survey}
cp -R "$SURVEY_SOURCE" "$WORK/survey"
S=$WORK/survey
mkdir -p "$WORK/bin" "$WORK/sys/block" "$WORK/proc/self" "$WORK/proc/sys/kernel" "$WORK/by-id"
HW_SYSFS=$WORK/sys HW_PROC=$WORK/proc HW_BY_ID=$WORK/by-id
MOCK_LOG=$WORK/calls MOCK_DD_BAD=$WORK/dd-bad MOCK_FS=tmpfs MOCK_DD_FAIL=0
export HW_SYSFS HW_PROC HW_BY_ID MOCK_LOG MOCK_DD_BAD MOCK_FS MOCK_DD_FAIL
: > "$MOCK_LOG"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
has() { grep -F -- "$2" "$1" >/dev/null || fail "$1: $2 がない"; }
lacks() { if grep -F -- "$2" "$1" >/dev/null; then fail "$1: $2 が残る"; fi; }
mkdisk() {
    name=$1; path=$2; sectors=$3; removable=$4; model=$5; rotational=$6
    dir=$HW_SYSFS/devices/$path/block/$name
    mkdir -p "$dir/device" "$dir/queue"
    printf '%s\n' "$sectors" > "$dir/size"
    printf '%s\n' "$removable" > "$dir/removable"
    printf '%s\n' "$model" > "$dir/device/model"
    printf 'SERIAL-%s-123456\n' "$name" > "$dir/device/serial"
    printf '%s\n' "$rotational" > "$dir/queue/rotational"
    echo 1 > "$dir/ro"
    ln -s "../devices/$path/block/$name" "$HW_SYSFS/block/$name"
    ln -s "$dir" "$HW_BY_ID/ata-$name"
}
mkdisk sda pci/ata1 468862128 0 '  SanDisk SSD  ' 0
mkdisk sdb pci/ata2 1953525168 0 'ST1000 HDD' 1
mkdisk sdc pci/usb2/2-1 1953525168 0 'USB BRIDGE' 0
mkdisk sdd pci/ata3 1953525168 1 'REMOVABLE HDD' 1
mkdisk sde pci/ata4 62500000 0 'LIVE BOOT' 0
mkdisk nvme0n1 pci/nvme/nvme0 1000000000 0 'NVME TEST' 0
mkdir -p "$HW_SYSFS/block/sde/sde1"
echo 1 > "$HW_SYSFS/block/sde/sde1/partition"
printf '%s\n' '/dev/mapper/ventoy /run/live/medium iso9660 ro 0 0' > "$HW_PROC/mounts"
printf '%s\n' '20 1 8:65 / /run/live/medium ro - iso9660 /dev/mapper/ventoy ro' > "$HW_PROC/self/mountinfo"
mkdir -p "$HW_SYSFS/class/dmi/id" "$HW_SYSFS/class/net/eth0" "$HW_SYSFS/class/net/lo"
echo 'ThinkPad TEST' > "$HW_SYSFS/class/dmi/id/product_name"
echo T420 > "$HW_SYSFS/class/dmi/id/product_version"
echo 1.46 > "$HW_SYSFS/class/dmi/id/bios_version"
echo 2020-01-01 > "$HW_SYSFS/class/dmi/id/bios_date"
echo SECRET-SYSTEM-SERIAL > "$HW_SYSFS/class/dmi/id/product_serial"
printf 'model name : Fake CPU\nflags : aes sse4_2 popcnt vmx lm\n' > "$HW_PROC/cpuinfo"
echo 'MemTotal: 8388608 kB' > "$HW_PROC/meminfo"
echo 6.12-test > "$HW_PROC/sys/kernel/osrelease"
echo up > "$HW_SYSFS/class/net/eth0/operstate"
echo 1000 > "$HW_SYSFS/class/net/eth0/speed"
echo full > "$HW_SYSFS/class/net/eth0/duplex"
bat=$HW_SYSFS/class/power_supply/BAT0
mkdir -p "$bat" "$HW_SYSFS/class/power_supply/AC"
echo 30000000 > "$bat/energy_full"
echo 50000000 > "$bat/energy_full_design"
echo 123 > "$bat/cycle_count"
echo 80 > "$bat/charge_control_end_threshold"
echo 'POWER_SUPPLY_STATUS=Discharging' > "$bat/uevent"
echo 1 > "$HW_SYSFS/class/power_supply/AC/online"
cat > "$WORK/bin/smartctl" <<'STUB'
#!/bin/sh
printf 'smartctl %s\n' "$*" >> "$MOCK_LOG"
case "$*" in
    *'/dev/sdc') case "$*" in *'-d sat'*) ;; *) echo 'Unknown USB bridge'; exit 2 ;; esac ;;
esac
case "$*" in
    *'/dev/nvme0n1')
        printf '%s\n' 'SMART overall-health self-assessment test result: PASSED' \
            'Power On Hours: 321' 'Percentage Used: 12%' 'Data Units Written: 12345' \
            'Data Units Read: 23456' 'Media and Data Integrity Errors: 0'
        exit 0 ;;
    *'/dev/sdb')
        printf '%s\n' 'SATA Version is: SATA 2.6 (current: 1.5Gb/s)' 'SMART Health Status: FAILED!' ;;
    *) printf '%s\n' 'SATA Version is: SATA 3.1, 6.0 Gb/s (current: 6.0 Gb/s)' \
        'SMART overall-health self-assessment test result: PASSED' ;;
esac
cat <<'DATA'
Serial Number: FALLBACK-654321
ID# ATTRIBUTE_NAME FLAG VALUE WORST THRESH TYPE UPDATED WHEN_FAILED RAW_VALUE
  5 Reallocated_Sector_Ct 0x0033 001 001 010 Pre-fail Always FAILING_NOW 2
  9 Power_On_Hours 0x0032 099 099 000 Old_age Always - 1234
 12 Power_Cycle_Count 0x0032 099 099 000 Old_age Always - 20
177 Wear_Leveling_Count 0x0032 099 099 000 Old_age Always - 95
187 Reported_Uncorrect 0x0032 099 099 000 Old_age Always - 3
188 Command_Timeout 0x0032 099 099 000 Old_age Always - 0
194 Temperature_Celsius 0x0032 099 099 000 Old_age Always - 35 (Min/Max 20/40)
197 Current_Pending_Sector 0x0032 099 099 000 Old_age Always - 4
198 Offline_Uncorrectable 0x0032 099 099 000 Old_age Always - 5
199 UDMA_CRC_Error_Count 0x0032 099 099 000 Old_age Always - 6
231 SSD_Life_Left 0x0032 099 099 000 Old_age Always - 98
233 Media_Wearout_Indicator 0x0032 099 099 000 Old_age Always - 97
241 Total_LBAs_Written 0x0032 099 099 000 Old_age Always - 999
242 Total_LBAs_Read 0x0032 099 099 000 Old_age Always - 888
DATA
case "$*" in *'/dev/sdb') exit 8 ;; esac
STUB
cat > "$WORK/bin/lsblk" <<'STUB'
#!/bin/sh
printf 'lsblk %s\n' "$*" >> "$MOCK_LOG"
printf '%s\n' ventoy sde1 sde
STUB
cat > "$WORK/bin/dmidecode" <<'STUB'
#!/bin/sh
printf 'Memory Device\n\tSize: 4096 MB\n\tLocator: DIMM0\n\tType: DDR3\n\tSpeed: 1333 MT/s\n'
STUB
cat > "$WORK/bin/ethtool" <<'STUB'
#!/bin/sh
printf '\tSpeed: 1000Mb/s\n\tDuplex: Full\n\tLink detected: yes\n'
STUB
cat > "$WORK/bin/lspci" <<'STUB'
#!/bin/sh
printf '%s\n' '00:01 SATA AHCI controller [0106]' '00:02 USB controller' '00:03 Ethernet controller' '00:04 CardBus PCMCIA FireWire'
STUB
cat > "$WORK/bin/lsusb" <<'STUB'
#!/bin/sh
printf '%s\n' '/: Bus 02 5000M USB'
STUB
cat > "$WORK/bin/dmesg" <<'STUB'
#!/bin/sh
n=0
while [ "$n" -lt 65 ]; do printf 'ata: SATA link up USB expresscard pcieport %s\n' "$n"; n=$((n+1)); done
STUB
cat > "$WORK/bin/dd" <<'STUB'
#!/bin/sh
printf 'dd %s\n' "$*" >> "$MOCK_LOG"
valid=0
for arg do
    case "$arg" in
        of=/dev/null) valid=1 ;;
        of=*) echo BAD > "$MOCK_DD_BAD"; exit 99 ;;
    esac
done
[ "$valid" = 1 ] || { echo BAD > "$MOCK_DD_BAD"; exit 99; }
[ "$MOCK_DD_FAIL" = 0 ] || exit 1
count=128
for arg do case "$arg" in count=*) count=${arg#count=} ;; esac; done
printf '%s bytes copied, 2.0 s, 67.1 MB/s\n' "$((count * 1048576))" >&2
STUB
cat > "$WORK/bin/findmnt" <<'STUB'
#!/bin/sh
printf '%s\n' "$MOCK_FS"
STUB
# 電池の補助診断も実機・サービスへアクセスさせない。
for cmd in upower acpi tlp-stat; do
    printf '#!/bin/sh\nprintf "補助電池情報\\n"\n' > "$WORK/bin/$cmd"
done
chmod +x "$WORK/bin/"* "$S/"*
PATH=$WORK/bin:$PATH
export PATH
for script in "$S/"*; do sh -n "$script"; done
sh -n "$HERE/tests/test-survey.sh"
if command -v shellcheck >/dev/null 2>&1; then
    (cd "$HERE" && shellcheck -s sh auto/survey/* tests/test-survey.sh)
fi
# 危険な操作を、実行されないコメントや分岐内も含めて禁止する。
if grep -En 'mkfs|(^|[[:space:]])mount[[:space:]]|mdadm[[:space:]]+--assemble|smartctl[[:space:]]+-t|hdparm[[:space:]]+--security|blockdev[[:space:]]+--setrw' "$S/"*; then
    fail '禁止された操作がある'
fi
if grep -Eoh '>[[:space:]]*/dev/[^[:space:];|)]*' "$S/"* | grep -Ev '^>[[:space:]]*/dev/null$'; then
    fail 'デバイスへのリダイレクトがある'
fi
if grep -Eh 'dd[[:space:]]' "$S/"* | grep -Eo 'of=[^[:space:]]+' | grep -Ev '^of=/dev/null$'; then
    fail 'dd の書き込み先が危険'
fi
"$S/hw-system" > "$WORK/system"
has "$WORK/system" 'ThinkPad TEST'; has "$WORK/system" 'CPU: Fake CPU'
has "$WORK/system" 'メモリ: 8.00 GiB'; has "$WORK/system" 'DDR3'; has "$WORK/system" 'CPU 機能 aes: 有'
lacks "$WORK/system" SECRET-SYSTEM-SERIAL
"$S/hw-disks" > "$WORK/disks"
has "$WORK/disks" 'SanDisk SSD'; has "$WORK/disks" '240.06 GB / 223.57 GiB'
has "$WORK/disks" 'SATA リンク: 6.0Gb/s'; has "$WORK/disks" 'SMART 健康: PASSED'
has "$WORK/disks" 'SMART 5 Reallocated_Sector_Ct: 2 [しきい値警告]'
has "$WORK/disks" 'SMART 241 Total_LBAs_Written: 999'; has "$WORK/disks" '電源投入時間: 1234'
has "$WORK/disks" 'SATA低速'; has "$WORK/disks" 'SMART 健康: FAILED!';
has "$WORK/disks" 'NVMe Percentage Used: 12%'; has "$WORK/disks" '電源投入時間: 321';
has "$WORK/disks" '注意: 5=2'; has "$WORK/disks" 'ディスク: sde (起動媒体)'
has "$MOCK_LOG" 'smartctl -d sat -i -H -A /dev/sdc'
[ "$(grep -c 'smartctl .* /dev/sdc$' "$MOCK_LOG")" = 2 ] || fail 'USB の再取得回数'
"$S/hw-ports" > "$WORK/ports"
has "$WORK/ports" CardBus; has "$WORK/ports" 'NIC eth0: リンク=yes 速度=1000Mb/s'
if grep -q 'pcieport 4$' "$WORK/ports"; then fail 'dmesg が60行に絞れていない'; fi; has "$WORK/ports" 'pcieport 64'
"$S/hw-battery" > "$WORK/battery"
has "$WORK/battery" 'BAT0 健康度: 60.0%'; has "$WORK/battery" '注意: 電池の健康度が70%未満'
has "$WORK/battery" 'charge_control_end_threshold'; has "$WORK/battery" 'AC online=1'
"$S/disk-guard-suggest" > "$WORK/guard"
has "$WORK/guard" 'sda | SanDisk SSD | 240 | 228 | 252'
has "$WORK/guard" 'sdb | ST1000 HDD | 1000 | 950 | 1050'
has "$WORK/guard" 'nvme0n1:486:538:NVME'
has "$WORK/guard" "disk-guard.sh --expect 'nvme0n1:486:538:NVME,sda:228:252:SanDisk,sdb:950:1050:ST1000'"
has "$WORK/guard" 'ata-sda'; has "$WORK/guard" '人が一覧表で確かめてから使う'
for excluded in sdc sdd sde; do lacks "$WORK/guard" "$excluded:"; lacks "$WORK/guard" "$excluded |"; done
# guard 本体と同じく、SCSI など接続種別が不明でも USB・removable・起動媒体でなければ含む。
mkdisk sdf pci/host5 1953525168 0 'SCSI TEST' 1
"$S/disk-guard-suggest" > "$WORK/scsi-guard"
has "$WORK/scsi-guard" 'sdf:950:1050:SCSI'
rm "$HW_SYSFS/block/sdf" "$HW_BY_ID/ata-sdf"
printf "%s\n" "O'Neil SSD" > "$HW_SYSFS/block/sda/device/model"
"$S/disk-guard-suggest" > "$WORK/quoted-guard"
grep '^disk-guard.sh --expect ' "$WORK/quoted-guard" > "$WORK/quoted-command"
sh -n "$WORK/quoted-command"
cat > "$WORK/bin/disk-guard.sh" <<'STUB'
#!/bin/sh
printf '%s\n' "$2" > "$HW_PROC/quoted-expect"
STUB
chmod +x "$WORK/bin/disk-guard.sh"
sh "$WORK/quoted-command"
has "$HW_PROC/quoted-expect" "sda:228:252:O'Neil"
printf '%s\n' '  SanDisk SSD  ' > "$HW_SYSFS/block/sda/device/model"
"$S/hw-disk-speed" --mb 128 > "$WORK/speed"
has "$WORK/speed" 'sda: 先頭 67.11 / 中間 67.11 / 末尾 67.11 / 平均 67.11 MB/s'
lacks "$MOCK_LOG" 'dd if=/dev/sde '
has "$MOCK_LOG" 'skip=114404 count=128'; has "$MOCK_LOG" 'skip=228808 count=128'
"$S/hw-disk-speed" --mb 128 /dev/sde > "$WORK/boot-speed"
has "$WORK/boot-speed" '(起動媒体) 測定対象外'
MOCK_DD_FAIL=1 "$S/hw-disk-speed" --mb 128 sda sdb > "$WORK/speed-fail"
has "$WORK/speed-fail" 'sda: 読み出しエラー'; has "$WORK/speed-fail" 'sdb: 読み出しエラー'
"$S/hw-survey" --out "$WORK/report" --speed --mb 128 > "$WORK/summary"
[ "$(wc -l < "$WORK/summary")" -le 40 ] || fail '要約が40行を超えた'
has "$WORK/summary" 'ThinkPad TEST'; has "$WORK/summary" 'SN末尾:123456'
has "$WORK/summary" ' !5=2'; has "$WORK/summary" '平均 67.11 MB/s'
has "$WORK/summary" 'NIC eth0:'; has "$WORK/summary" 'BAT0 健康度: 60.0%'
has "$WORK/summary" "disk-guard.sh --expect '"
n=1
while [ "$n" -le 45 ]; do
    mkdir "$HW_SYSFS/class/net/eth$n"
    n=$((n+1))
done
"$S/hw-survey" --out "$WORK/many" > "$WORK/many-summary"
[ "$(wc -l < "$WORK/many-summary")" -le 40 ] || fail '多数の機器で40行を超えた'
has "$WORK/many-summary" '行は詳細ログを参照'
has "$WORK/many-summary" "disk-guard.sh --expect '"
: > "$MOCK_LOG"
"$S/hw-survey" --out "$WORK/no-speed" > "$WORK/no-speed-summary"
lacks "$MOCK_LOG" 'dd '
MOCK_FS=ext4
export MOCK_FS
if "$S/hw-survey" --out "$WORK/reject/new" > "$WORK/reject-log" 2>&1; then fail 'ディスク保存を許した'; fi
has "$WORK/reject-log" 'ディスクに書くことになる'
[ ! -e "$WORK/reject" ] || fail 'FS 判定前にディレクトリを作った'
"$S/hw-survey" --allow-disk --out "$WORK/allowed" > "$WORK/allow-log" 2>&1
has "$WORK/allow-log" 'ディスクに書くことになる'
# PATH を閉じ、インストール済みの本物の smartctl にフォールバックしない。
mkdir "$WORK/no-smart"
for cmd in awk sed grep head tail cat tr readlink dirname ls uname date sh; do
    tool=$(command -v "$cmd"); ln -s "$tool" "$WORK/no-smart/$cmd"
done
ln -s "$WORK/bin/dd" "$WORK/no-smart/dd"
PATH=$WORK/no-smart "$S/hw-disks" > "$WORK/no-smart-output"
has "$WORK/no-smart-output" '未取得: smartctlなし'
has "$WORK/no-smart-output" '未取得: 起動媒体の親ディスク'
PATH=$WORK/no-smart "$S/hw-ports" > "$WORK/no-tools-ports"
has "$WORK/no-tools-ports" '未取得: ethtoolなし'
has "$WORK/no-tools-ports" 'NIC eth0: リンク=up 速度=1000'
# sysfs は読み取り可能でも、リンクダウン時などに read が失敗することがある。
mv "$HW_SYSFS/class/net/eth0/speed" "$WORK/nic-speed"
mkdir "$HW_SYSFS/class/net/eth0/speed"
PATH=$WORK/no-smart "$S/hw-ports" > "$WORK/unreadable-speed"
has "$WORK/unreadable-speed" 'NIC eth0: リンク=up 速度=不明'
rmdir "$HW_SYSFS/class/net/eth0/speed"
mv "$WORK/nic-speed" "$HW_SYSFS/class/net/eth0/speed"
PATH=$WORK/no-smart "$S/hw-system" > "$WORK/no-tools-system"
has "$WORK/no-tools-system" '未取得: dmidecodeなし'
PATH=$WORK/no-smart "$S/hw-battery" > "$WORK/no-tools-battery"
has "$WORK/no-tools-battery" '未取得: upowerなし' 
# mapper の親が取得できなければ、安全側で両操作を省略する。
PATH=$WORK/no-smart "$S/hw-disk-speed" > "$WORK/no-parent-speed"
PATH=$WORK/no-smart "$S/disk-guard-suggest" > "$WORK/no-parent-guard"
has "$WORK/no-parent-guard" '未取得: 起動媒体の親ディスク'
has "$WORK/no-parent-speed" '未取得: 起動媒体の親ディスク'
# lsblk がなくても、直接のパーティションなら sysfs から親をたどれる。
printf '%s\n' '/dev/sde1 /lib/live/mount/medium iso9660 ro 0 0' > "$HW_PROC/mounts"
: > "$HW_PROC/self/mountinfo"
PATH=$WORK/no-smart "$S/hw-disks" > "$WORK/direct-boot"
has "$WORK/direct-boot" 'ディスク: sde (起動媒体)' 
[ ! -e "$MOCK_DD_BAD" ] || fail 'dd が /dev/null 以外へ書いた'
printf '%s\n' 'ALL PASS: survey (偽 sysfs/proc、SMART、起動媒体除外、速度、RAM 保存、要約、安全性)'
if [ "${SURVEY_SHOW_SAMPLE:-0}" = 1 ]; then cat "$WORK/summary"; fi
