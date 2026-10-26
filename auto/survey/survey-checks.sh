#!/bin/sh
# shellcheck disable=SC2154,SC2012
# survey から読み込む。判定用の情報も RAM ログだけを参照する。
field() { sed -n "s/^[[:space:]]*$2: *//p" "$1" | head -n 1; }
temperature() {
    awk '/temp[0-9]+_input:/ {if(!n++||$2>max) max=$2} END {if(n) print max}' "$1"
}
frequency() {
    awk -F ': *' '/^cpu MHz/ {if(!n++||$2>max) max=$2} END {if(n) print max}' "$HW_PROC/cpuinfo" 2>/dev/null
}
profile_checks() {
    bios=$(read_value "$HW_SYSFS/class/dmi/id/bios_version")
    note=FAIR
    printf '%s\n' "$bios" | grep -Eq "$BIOS_PATTERN" || note="$EXPECT_NOTE"
    printf 'BIOS: %s (%s; legacy: no EFI variables is normal)\n' "$bios" "$note"
    if [ "$profile" != generic ]; then
        missing_pci=
        for pci in $EXPECTED_PCI; do
            grep -qi "$pci" "$out/pci.txt" || missing_pci="$missing_pci $pci"
        done
        if grep -q 'N-A' "$out/pci.txt"; then echo 'PCI: N-A';
        elif [ -n "$missing_pci" ]; then printf 'PCI: %s:%s\n' "$EXPECT_NOTE" "$missing_pci"
        else echo 'PCI: GOOD (expected IDs match)'; fi
    else printf 'PCI: %s\n' "$(head -n 1 "$out/pci.txt")"; fi
    if [ "$profile" = g560 ]; then
        ids=$(grep -Eo '[0-9a-fA-F]{4}:[0-9a-fA-F]{4}' "$out/pci.txt" | sort -u | tr '\n' ' ')
        printf 'PCI IDs (update HINT): %s\n' "${ids:-N-A}"
    fi
    # cycle_count は判定に使わない。設計値が無ければ健康度を推定しない。
    found=0
    for bat in "$HW_SYSFS"/class/power_supply/BAT*; do
        [ -d "$bat" ] || continue
        found=1
        f=$(read_value "$bat/energy_full"); d=$(read_value "$bat/energy_full_design")
        unit=Wh
        if [ "$f" = N-A ] || [ "$d" = N-A ]; then
            f=$(read_value "$bat/charge_full"); d=$(read_value "$bat/charge_full_design"); unit=Ah
        fi
        awk -v f="$f" -v d="$d" -v u="$unit" -v n="${bat##*/}" -v expected="$BATTERY_WH" 'BEGIN {
            if(f !~ /^[0-9]+$/||d !~ /^[0-9]+$/||d<=0) {print n ": N-A: battery health"; exit}
            h=f/d*100; v=h>=70?"GOOD":h>=50?"FAIR":"BAD"
            printf "%s: %s %.1f%% design %.2f%s (HINT %.2fWh; no cycle rating)\n",n,v,h,d/1e6,u,expected
        }'
    done
    [ "$found" = 1 ] || echo 'Battery: N-A: no BAT*'
    mem=$(awk '/^MemTotal:/ {printf "%.2f GiB",$2/1048576}' "$HW_PROC/meminfo" 2>/dev/null)
    speeds=$(sed -n 's/^[[:space:]]*Configured Memory Speed: *//p' "$out/memory.txt")
    [ -n "$speeds" ] || speeds=$(sed -n 's/^[[:space:]]*Speed: *//p' "$out/memory.txt")
    note='FAIR (HINT ~1067MT/s)'
    [ -n "$speeds" ] || note=N-A
    printf '%s\n' "$speeds" | grep -q '^800 ' && note='FAIR/WARN: 800MT/s (HINT)'
    printf 'Memory: %s / %s / %s (slots/parts in logs)\n' "${mem:-N-A}" "$(printf '%s' "$speeds" | tr '\n' '/')" "$note"
    if [ "$profile" = g560 ]; then
        gpu='N-A'; grep -qi '8086:0046' "$out/pci.txt" && gpu=UMA
        grep -qi '10de:0a70' "$out/pci.txt" && gpu=DIS
        sata=N-A; grep -qi '8086:3b29' "$out/pci.txt" && sata=AHCI
        grep -qi '8086:3b28' "$out/pci.txt" && sata=IDE
        printf 'G560 HINT: GPU=%s SATA=%s RAM max 8GB (SMBIOS 16GB not guaranteed)\n' "$gpu" "$sata"
        EXPECT_LAN=0
        grep -qi '10ec:8136' "$out/pci.txt" && EXPECT_LAN=100
        grep -qi '10ec:8168' "$out/pci.txt" && EXPECT_LAN=1000
        num=$(printf '%s' "$bios" | sed -n 's/^29CN\([0-9][0-9]\)WW.*/\1/p')
        if [ "$gpu" = DIS ] && [ -n "$num" ] && [ "$num" -lt 31 ]; then
            echo 'G560 HINT: known VBIOS display bug possible (older than 29CN31WW)'
        fi
        echo 'G560: absent TrackPoint/fingerprint/TPM is OK; MANUAL: radio switch'
    fi
    input=$(read_value "$HW_PROC/bus/input/devices")
    if [ "$input" = N-A ]; then echo 'Input: N-A'; else
        for device in 'AT Translated Set 2 keyboard' 'SynPS/2 Synaptics TouchPad'; do
            if printf '%s' "$input" | grep -Fq "$device"; then printf 'Input: FAIR %s (MANUAL function test)\n' "$device";
            else printf 'Input: UNTESTED %s not detected\n' "$device"; fi
        done
        if [ "$EXPECT_TRACKPOINT" = 1 ]; then
            if printf '%s' "$input" | grep -Fq 'TPPS/2 IBM TrackPoint'; then echo 'TrackPoint: FAIR (detected; MANUAL function test)';
            else echo 'TrackPoint: BAD-CANDIDATE (not detected; MANUAL check)'; fi
        fi
    fi
    drm=
    for port in "$HW_SYSFS"/class/drm/card*-*; do
        [ -r "$port/status" ] || continue
        drm="$drm ${port##*/}:$(read_value "$port/status"):$(read_value "$port/modes")"
    done
    printf 'LCD/DRM: %s (HINT 1366x768) backlight:%s\n' "${drm:-N-A}" "$(ls "$HW_SYSFS/class/backlight" 2>/dev/null | tr '\n' ' ')"
    printf 'USB: %s (Edge/G560 HINT: EHCI 480M; ports UNTESTED)\n' "$(head -n 1 "$out/usb.txt")"
    wireless=N-A
    grep -qi '8086:0084' "$out/pci.txt" && wireless='Intel 1000: 2.4GHz only is normal'
    grep -qi '8086:422c' "$out/pci.txt" && wireless='Intel 6200: 2.4/5GHz HINT'
    grep -qi '14e4:4727' "$out/pci.txt" && wireless='BCM4313: 2.4GHz/firmware-brcm80211 HINT'
    grep -qi '168c:002b' "$out/pci.txt" && wireless='AR9285: ath9k HINT'
    if [ "$wireless" = N-A ] && grep -qi 'Intel.*Wireless\|Wireless.*Intel' "$out/pci.txt"; then wireless='Intel (see logs)'; fi
    printf 'WiFi: %s / iw:%s\n' "$wireless" "$(head -n 1 "$out/iw-dev.txt")"
    printf 'rfkill: %s (Hard blocked: MANUAL switch check)\n' "$(grep -E 'blocked:|N-A' "$out/rfkill.txt" | tr '\n' ' ')"
    if grep -Ei '(iwlwifi|firmware).*(fail|error|not found)' "$out/dmesg.txt" > "$out/firmware-errors.txt"; then echo 'WiFi: FAIR/WARN: firmware failed (see logs)'; fi
    if [ -r "$out/details/hw-ports.txt" ]; then
        awk -v e="$EXPECT_LAN" -v n="$EXPECT_NOTE" '/^NIC / {
            v="UNTESTED"; if($0 ~ /link=yes|link=up/) {
                if(e==0) v="FAIR (expected speed unverified)"
                else if(index($0,"Speed=" e "Mb/s duplex=Full")) v="GOOD"
                else v=n " (CHECK speed/duplex/cable)"
            }
            print "LAN: " v " " $0
        }' "$out/details/hw-ports.txt"
    fi
    vmx=N-A
    if [ -r "$HW_PROC/cpuinfo" ]; then
        vmx='NO (i3/i5: check BIOS; Celeron/Pentium: may be unsupported)'
        grep -Eq '(^| )vmx( |$)' "$HW_PROC/cpuinfo" && vmx=YES
    fi
    printf 'Virtualization vmx: %s\n' "$vmx"
}
disk_checks() {
    if [ ! -s "$out/internal-disks.txt" ]; then echo 'Internal disks: UNTESTED (boot disk unknown or no targets)'; fi
    while IFS= read -r disk; do
        # 既存 hw-disks の情報を再利用し、SMART を重ねて取得しない。
        awk -v disk="$disk" '
            /^Disk:/ {active=($2==disk)} active {print}
        ' "$out/details/hw-disks.txt" > "$out/disk-$disk.txt"
        data=$out/disk-$disk.txt
        verdict=N-A
        health=$(field "$data" 'SMART health')
        [ "$health" != PASSED ] || verdict=FAIR
        case "$health" in *FAIL*) verdict=BAD ;; esac
        if awk '/^SMART (197|198) / && $4+0>0 {bad=1} END {exit !bad}' "$data"; then verdict=BAD; fi
        if grep -Eq '^[[:space:]]*locked[[:space:]]*$' "$out/security-$disk.txt"; then verdict=BAD; fi
        attrs=$(awk '/^SMART (5|197|198|187|196|199|10|194) / {printf "%s=%s ",$2,$4}' "$data")
        note=
        if awk '/^SMART 5 / && $4+0>0 {bad=1} END {exit !bad}' "$data"; then note='WARN:5>0'; fi
        printf 'Disk %s: %s %s %s SATA:%s (HINT 3.0Gb/s) ' "$disk" "$verdict" "$note" "$attrs" "$(field "$data" 'SATA link')"
        security=$(sed -n '/^[[:space:]]*Security:/,/^[^[:space:]]/p' "$out/security-$disk.txt" | grep -E 'locked|enabled|frozen|supported' | tr '\n' ' ')
        printf 'Security %s: %s (frozen is normal)\n' "$disk" "${security:-N-A}"
    done < "$out/internal-disks.txt"
    if [ -r "$out/details/hw-disk-speed.txt" ]; then grep -E 'median|N-A|read error' "$out/details/hw-disk-speed.txt" || :; else echo 'Speed: N-A'; fi
    if grep -Ei 'limiting speed|(^|[^[:alpha:]])PIO([^[:alpha:]]|$)' "$out/dmesg.txt" > "$out/sata-errors.txt"; then echo 'SATA: FAIR/WARN: limiting speed/PIO (see logs)'; fi
}
cooling_check() {
    idle=$(temperature "$out/idle-sensors.txt")
    crit=$(awk '/temp[0-9]+_crit:/ && $2>0 {if(!n++||$2<c) c=$2} END {if(n) print c}' "$out/idle-sensors.txt")
    [ -n "$crit" ] || crit=95
    if [ "$swap_ready" != 1 ] || [ -z "$idle" ] || ! command -v stress-ng >/dev/null 2>&1; then
        echo 'Cooling: UNTESTED (swap stop, sensor or stress-ng unavailable)'; return
    fi
    if awk -v t="$idle" -v c="$crit" 'BEGIN {exit !(t>=c-5)}'; then
        printf 'Cooling: BAD-CANDIDATE idle=%sC (near crit=%s; load skipped)\n' "$idle" "$crit"; return
    fi
    peak=$idle; lowclock=$(frequency); highclock=$lowclock; stopped=0
    stress-ng --cpu 2 --timeout 180s > "$out/stress.txt" 2>&1 &
    stress_pid=$!
    trap 'kill "$stress_pid" 2>/dev/null || :; wait "$stress_pid" 2>/dev/null || :; exit 130' HUP INT TERM
    while kill -0 "$stress_pid" 2>/dev/null; do
        run sensors -u 'coretemp-*' > "$out/current-sensors.txt"
        cat "$out/current-sensors.txt" >> "$out/load-sensors.txt"
        current=$(temperature "$out/current-sensors.txt")
        if [ -n "$current" ]; then peak=$(awk -v a="$peak" -v b="$current" 'BEGIN {print (a>b?a:b)}'); fi
        if [ -z "$current" ] || awk -v t="$current" -v c="$crit" 'BEGIN {exit !(t>=c-5)}'; then
            stopped=1; kill "$stress_pid" 2>/dev/null || :; break
        fi
        clock=$(frequency)
        printf 'MHz %s\n' "${clock:-N-A}" >> "$out/clocks.txt"
        if [ -n "$clock" ]; then
            lowclock=$(awk -v a="$lowclock" -v b="$clock" 'BEGIN {print (a==""||b<a?b:a)}')
            highclock=$(awk -v a="$highclock" -v b="$clock" 'BEGIN {print (b>a?b:a)}')
        fi
        sleep 2
    done
    status=0; wait "$stress_pid" || status=$?
    trap - HUP INT TERM
    verdict=GOOD
    [ "$status" = 0 ] || verdict='UNTESTED (stress-ng failed)'
    [ "$stopped" = 0 ] || verdict='BAD-CANDIDATE (stopped: near crit or sensor unavailable)'
    clocknote=
    if [ -n "$highclock" ] && [ -n "$lowclock" ] && awk -v a="$lowclock" -v b="$highclock" 'BEGIN {exit !(a<b*0.7)}'; then clocknote='clock drop (MANUAL: distinguish power saving)'; fi
    printf 'Cooling: %s idle=%s/max=%sC (HINT 45-65; crit=%s) MHz=%s-%s %s\n' "$verdict" "$idle" "$peak" "$crit" "${lowclock:-N-A}" "${highclock:-N-A}" "$clocknote"
    echo 'Fan: MANUAL (Edge readings/missing data do not prove failure)'
}
long_checks() {
    [ "$long" = 1 ] || { echo 'SMART long / RAM test: UNTESTED (enable with --long)'; return; }
    # 長時間試験はディスク同士を並列実行し、CPU負荷試験のあとにメモリを確保する。
    pids=
    while IFS= read -r disk; do
        (
            if ! command -v smartctl >/dev/null 2>&1; then missing smartctl; exit; fi
            smartctl -l selftest "/dev/$disk" > "$out/before-long-$disk.txt" 2>&1 || :
            if ! smartctl -t long "/dev/$disk" > "$out/long-$disk.txt" 2>&1; then
                echo 'N-A: SMART long start failed' >> "$out/long-$disk.txt"; exit
            fi
            poll=0
            while [ "$poll" -lt 360 ]; do
                sleep 60
                smartctl -c "/dev/$disk" > "$out/progress-$disk.txt" 2>&1 || {
                    echo 'N-A: SMART long status' >> "$out/long-$disk.txt"; exit;
                }
                if ! grep -qi 'in progress' "$out/progress-$disk.txt"; then
                    smartctl -l selftest "/dev/$disk" >> "$out/long-$disk.txt" 2>&1 || :
                    exit
                fi
                poll=$((poll+1))
            done
            echo 'UNTESTED: SMART long 6h timeout' >> "$out/long-$disk.txt"
        ) &
        pids="$pids $!"
    done < "$out/internal-disks.txt"
    available=$(awk '/^MemAvailable:/ {print int($2/2048)}' "$HW_PROC/meminfo" 2>/dev/null)
    memstatus=UNTESTED
    if [ "$swap_ready" = 1 ] && [ -n "$available" ] && [ "$available" -gt 0 ] && command -v memtester >/dev/null 2>&1; then
        if memtester "${available}M" 1 > "$out/memtester.txt" 2>&1; then memstatus=GOOD; else memstatus=BAD; fi
    fi
    for pid in $pids; do wait "$pid" || :; done
    printf 'RAM test: %s (<= half MemAvailable: %sMiB / 1 pass; swap off)\n' "$memstatus" "${available:-N-A}"
    while IFS= read -r disk; do
        verdict=N-A
        latest=$(grep -E '^#[[:space:]]*1[[:space:]]' "$out/long-$disk.txt" | head -n 1)
        previous=$(grep -E '^#[[:space:]]*1[[:space:]]' "$out/before-long-$disk.txt" | head -n 1)
        if [ -n "$latest" ] && [ "$latest" != "$previous" ]; then
            printf '%s' "$latest" | grep -q 'Extended.*Completed without error' && verdict=GOOD
            printf '%s' "$latest" | grep -Ei 'read failure|electrical failure|servo.*failure' >/dev/null && verdict=BAD
        fi
        printf 'SMART long %s: %s (see logs; unsupported/aborted = UNTESTED)\n' "$disk" "$verdict"
    done < "$out/internal-disks.txt"
}
