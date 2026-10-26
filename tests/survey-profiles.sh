#!/bin/sh
# test-survey.sh の偽媒体とコマンドを引き継ぐ。単独では実行しない。
set -eu
S=$1 WORK=$2
HERE=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
fail() { echo "FAIL: $*" >&2; exit 1; }
has() { grep -F -- "$2" "$1" >/dev/null || { cat "$1" >&2; fail "$1: $2 がない"; }; }
lacks() { if grep -F -- "$2" "$1" >/dev/null; then fail "$1: $2 が残る"; fi; }
# root・負荷・メモリ・サービスの呼び出しをすべて隔離する。
for cmd in id swapoff modprobe stress-ng memtester rfkill iw sensors hdparm sleep; do
    cat > "$WORK/bin/$cmd" <<'STUB'
#!/bin/sh
cmd=${0##*/}
printf '%s %s\n' "$cmd" "$*" >> "$MOCK_LOG"
case "$cmd" in
    id) echo 0 ;;
    stress-ng) /bin/sleep 0.1 ;;
    sensors)
        if [ "${MOCK_HOT:-0}" = 1 ]; then echo 'temp1_input: 99.000'; echo 'temp1_crit: 100.000'; exit; fi
        printf '%s\n' 'coretemp-isa-0000' 'temp1_input: 52.000' 'temp1_crit: 100.000' ;;
    hdparm)
        case "$*" in
            '-I '*) printf '\tSecurity:\n\t\tnot enabled\n\t\tnot locked\n\t\tfrozen\n' ;;
            '-t --direct '*) echo 'Timing O_DIRECT disk reads: 300 MB in 3 seconds = 100.00 MB/sec' ;;
            *) exit 99 ;;
        esac ;;
    rfkill) printf 'Soft blocked: no\nHard blocked: no\n' ;;
    iw) case "$1" in dev) echo 'Interface wlan0' ;; list) echo '* 2412 MHz [1]' ;; esac ;;
esac
STUB
    chmod +x "$WORK/bin/$cmd"
done
cat > "$WORK/bin/dmidecode" <<'STUB'
#!/bin/sh
if [ "$1" = -s ]; then
    case "$2" in
        system-product-name) key=product_name ;;
        system-version) key=product_version ;;
        system-family) key=product_family ;;
    esac
    cat "$HW_SYSFS/class/dmi/id/$key"
else
    printf 'Memory Device\n\tSize: 4096 MB\n\tSpeed: 1067 MT/s\n\tPart Number: FIXTURE-4GB\n'
fi
STUB
cat > "$WORK/bin/lspci" <<'STUB'
#!/bin/sh
cat "$HW_PROC/pci"
STUB
cat > "$WORK/bin/ethtool" <<'STUB'
#!/bin/sh
speed=1000
if grep -q 10ec:8136 "$HW_PROC/pci"; then speed=100; fi
printf '\tSpeed: %sMb/s\n\tDuplex: Full\n\tLink detected: yes\n' "$speed"
STUB
cat > "$WORK/bin/efibootmgr" <<'STUB'
#!/bin/sh
echo 'EFI variables are not supported on this system.'; exit 2
STUB
chmod +x "$WORK/bin/"*
# SMART long の状態・結果を、既存の属性データの前に差し込む。
cp "$WORK/bin/smartctl" "$WORK/bin/smartctl-data"
cat > "$WORK/bin/smartctl" <<'STUB'
#!/bin/sh
case "$*" in
    '-l selftest '*)
        if [ ! -f "$HW_PROC/long-${3##*/}" ]; then exit 0; fi
        echo '# 1 Extended offline Completed without error 00% 1234 -'; exit 0 ;;
    '-t long '*|'-c '*)
        case "$*" in '-t long '*) touch "$HW_PROC/long-${3##*/}" ;; esac
        printf 'smartctl %s\n' "$*" >> "$MOCK_LOG"
        echo '# 1 Extended offline Completed without error 00% 1234 -'; exit 0 ;;
esac
exec "$(dirname "$0")/smartctl-data" "$@"
STUB
chmod +x "$WORK/bin/smartctl"
SURVEY_RAM_ROOT=$WORK; export SURVEY_RAM_ROOT
mkdir -p "$HW_PROC/bus/input" "$HW_SYSFS/class/drm/card0-LVDS-1" "$HW_SYSFS/class/backlight/intel_backlight"
echo connected > "$HW_SYSFS/class/drm/card0-LVDS-1/status"
echo 1366x768 > "$HW_SYSFS/class/drm/card0-LVDS-1/modes"
printf 'MemTotal: 8388608 kB\nMemAvailable: 2097152 kB\n' > "$HW_PROC/meminfo"
# 先の多数NIC検査のダミーを片付ける。
for nic in "$HW_SYSFS"/class/net/eth*; do [ "${nic##*/}" = eth0 ] || rmdir "$nic"; done
for pid in edge14-0578 g560; do
    fixture=$HERE/tests/fixtures/survey/$pid
    for key in product_name product_version bios_version product_family; do cp "$fixture/$key" "$HW_SYSFS/class/dmi/id/$key"; done
    cp "$fixture/pci" "$HW_PROC/pci"
    cp "$fixture/input" "$HW_PROC/bus/input/devices"
    : > "$MOCK_LOG"
    rm -f "$HW_PROC/"long-*
    "$S/survey" < /dev/null > "$WORK/$pid-short"
    lacks "$MOCK_LOG" 'smartctl -t '
    lacks "$MOCK_LOG" 'memtester '
    has "$WORK/$pid-short" 'SMART long / RAM test: UNTESTED'
    : > "$MOCK_LOG"
    "$S/survey" --long < /dev/null > "$WORK/$pid-summary"
    has "$WORK/$pid-summary" "/ $pid =="
    has "$WORK/$pid-summary" 'BAT0: FAIR 60.0%'
    has "$WORK/$pid-summary" 'Disk sda: BAD'
    has "$WORK/$pid-summary" '197=4'
    has "$WORK/$pid-summary" 'median 100.00 MB/s'
    has "$WORK/$pid-summary" 'RAM test: GOOD'
    has "$WORK/$pid-summary" 'SMART long sda: GOOD'
    has "$WORK/$pid-summary" 'Cooling: GOOD'
    has "$MOCK_LOG" 'memtester 1024M 1'
    has "$MOCK_LOG" 'swapoff -a'
    has "$MOCK_LOG" 'stress-ng --cpu 2 --timeout 180s'
    [ "$(grep -c '^hdparm -t --direct /dev/sda$' "$MOCK_LOG")" = 3 ] || fail 'hdparm 回数'
    for excluded in sdc sdd sde; do
        lacks "$MOCK_LOG" "hdparm -t --direct /dev/$excluded"
        lacks "$MOCK_LOG" "smartctl -t long /dev/$excluded"
        lacks "$MOCK_LOG" "dd if=/dev/$excluded "
    done
    if [ "$pid" = edge14-0578 ]; then
        has "$WORK/$pid-summary" 'PCI: GOOD'; has "$WORK/$pid-summary" 'TrackPoint: FAIR'
    else
        has "$WORK/$pid-summary" 'GPU=DIS SATA=IDE'
        has "$WORK/$pid-summary" 'known VBIOS'
        has "$WORK/$pid-summary" 'Speed=100Mb/s'
        lacks "$WORK/$pid-summary" 'TrackPoint: BAD'
    fi
    logdir=$(sed -n 's/^Survey: .*; logs: //p' "$WORK/$pid-summary")
    [ "$(wc -l < "$logdir/summary.txt")" -le 40 ] || fail 'プロファイルの要約が40行超過'
    has "$logdir/memory.txt" 'Part Number: FIXTURE-4GB'
done
# 電池の境界と既に高温の場合の負荷中止。
echo 37500000 > "$HW_SYSFS/class/power_supply/BAT0/energy_full"
: > "$MOCK_LOG"
MOCK_HOT=1 "$S/survey" --profile edge14-0578 < /dev/null > "$WORK/hot"
has "$WORK/hot" 'BAT0: GOOD 75.0%'
has "$WORK/hot" 'Cooling: BAD-CANDIDATE'
lacks "$MOCK_LOG" 'stress-ng --cpu'
echo 24500000 > "$HW_SYSFS/class/power_supply/BAT0/energy_full"
# 期待値と違う G560 は不合格にせず、実測値を更新材料にする。
echo 'unknown PCI' > "$HW_PROC/pci"
"$S/survey" --profile g560 < /dev/null > "$WORK/g560-different"
has "$WORK/g560-different" 'HINT mismatch (update needed)'
has "$WORK/g560-different" 'GPU=N-A SATA=N-A'
has "$WORK/g560-different" 'BAT0: BAD 49.0%'
echo UNKNOWN > "$HW_SYSFS/class/dmi/id/product_name"
echo UNKNOWN > "$HW_SYSFS/class/dmi/id/product_version"
echo UNKNOWN > "$HW_SYSFS/class/dmi/id/product_family"
# 欠けたセンサーの扱い(本物へフォールバックしない)。
printf '#!/bin/sh\necho "N-A: sensors missing"\n' > "$WORK/bin/sensors"
"$S/survey" < /dev/null > "$WORK/generic-summary"
has "$WORK/generic-summary" '/ generic =='
has "$WORK/generic-summary" 'Cooling: UNTESTED'
"$S/survey" --profile generic --long < /dev/null > "$WORK/generic-long"
has "$WORK/generic-long" 'RAM test: GOOD'
has "$WORK/generic-long" 'SMART long sda: N-A'
lacks "$WORK/generic-long" 'SMART long sda: GOOD'
MOCK_FS=ext4 "$S/survey" --profile generic < /dev/null > "$WORK/ram-refused" 2>&1 && fail 'survey がディスク出力を許可'
has "$WORK/ram-refused" 'RAM output directory'
"$S/survey" --list > "$WORK/profiles"
for pid in edge14-0578 g560 generic; do has "$WORK/profiles" "$pid"; done
if "$S/survey" --profile '../../invalid' > "$WORK/invalid-profile" 2>&1; then fail '不明プロファイルを許可'; fi
# usage とエラーは終了コードも照合し、出力を ASCII 検査へ渡す。
error_case() {
    expected=$1; name=$2; shift 2
    status=0
    "$@" < /dev/null > "$WORK/error-$name" 2>&1 || status=$?
    [ "$status" = "$expected" ] || fail "$name: status $status, expected $expected"
}
error_case 2 survey-usage "$S/survey" --unknown
has "$WORK/error-survey-usage" 'Usage: survey'
error_case 2 survey-profile-value "$S/survey" --profile
error_case 2 survey-profile-invalid "$S/survey" --profile invalid
has "$WORK/error-survey-profile-invalid" 'Unknown profile'
error_case 2 hw-usage "$S/hw-survey" --unknown
has "$WORK/error-hw-usage" 'Usage: hw-survey'
error_case 2 hw-out-value "$S/hw-survey" --out
error_case 2 hw-mb-value "$S/hw-survey" --mb
error_case 2 hw-path "$S/hw-survey" --out "$WORK/./invalid"
error_case 1 hw-existing "$S/hw-survey" --out "$WORK/report"
has "$WORK/error-hw-existing" 'Output already exists'
error_case 2 speed-usage "$S/hw-disk-speed" --mb
has "$WORK/error-speed-usage" 'Usage: hw-disk-speed'
for value in invalid 0 2147483648; do
    error_case 2 "hw-mb-$value" "$S/hw-survey" --mb "$value"
    error_case 2 "speed-mb-$value" "$S/hw-disk-speed" --mb "$value"
done
"$S/hw-disk-speed" unknown > "$WORK/speed-excluded" 2>&1
has "$WORK/speed-excluded" 'unknown: excluded'
# sudo の再実行引数(元のコマンドは実行せず記録だけする)。
printf '#!/bin/sh\necho 1000\n' > "$WORK/bin/id"
# shellcheck disable=SC2016
printf '#!/bin/sh\nprintf "sudo %%s\\n" "$*" >> "$MOCK_LOG"\n' > "$WORK/bin/sudo"
chmod +x "$WORK/bin/sudo"
"$S/survey" --profile g560 --long > /dev/null
has "$MOCK_LOG" 'survey --profile g560 --long'
echo 'PASS: Edge/G560/generic, expectations, SMART BAD, long, exclusions, N-A, sudo, usage/errors'
