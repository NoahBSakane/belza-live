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
    note=可
    printf '%s\n' "$bios" | grep -Eq "$BIOS_PATTERN" || note="$EXPECT_NOTE"
    printf 'BIOS: %s (%s; レガシーでは EFI variables 非対応は正常)\n' "$bios" "$note"
    if [ "$profile" != generic ]; then
        missing_pci=
        for pci in $EXPECTED_PCI; do
            grep -qi "$pci" "$out/pci.txt" || missing_pci="$missing_pci $pci"
        done
        if grep -q '未取得' "$out/pci.txt"; then echo 'PCI: 未取得';
        elif [ -n "$missing_pci" ]; then printf 'PCI: %s:%s\n' "$EXPECT_NOTE" "$missing_pci"
        else echo 'PCI: 良 (期待値一致)'; fi
    else printf 'PCI: %s\n' "$(head -n 1 "$out/pci.txt")"; fi
    if [ "$profile" = g560 ]; then
        ids=$(grep -Eo '[0-9a-fA-F]{4}:[0-9a-fA-F]{4}' "$out/pci.txt" | sort -u | tr '\n' ' ')
        printf 'PCI実測(目安の更新用): %s\n' "${ids:-未取得}"
    fi
    # cycle_count は判定に使わない。設計値が無ければ健康度を推定しない。
    found=0
    for bat in "$HW_SYSFS"/class/power_supply/BAT*; do
        [ -d "$bat" ] || continue
        found=1
        f=$(read_value "$bat/energy_full"); d=$(read_value "$bat/energy_full_design")
        unit=Wh
        if [ "$f" = 不明 ] || [ "$d" = 不明 ]; then
            f=$(read_value "$bat/charge_full"); d=$(read_value "$bat/charge_full_design"); unit=Ah
        fi
        awk -v f="$f" -v d="$d" -v u="$unit" -v n="${bat##*/}" -v expected="$BATTERY_WH" 'BEGIN {
            if(f !~ /^[0-9]+$/||d !~ /^[0-9]+$/||d<=0) {print n ": 未取得: 電池の健康度"; exit}
            h=f/d*100; v=h>=70?"良":h>=50?"可":"不可"
            printf "%s: %s %.1f%% 設計 %.2f%s (設計目安 %.2fWh; cycle不使用)\n",n,v,h,d/1e6,u,expected
        }'
    done
    [ "$found" = 1 ] || echo '電池: 未取得: BAT* なし'
    mem=$(awk '/^MemTotal:/ {printf "%.2f GiB",$2/1048576}' "$HW_PROC/meminfo" 2>/dev/null)
    speeds=$(sed -n 's/^[[:space:]]*Configured Memory Speed: *//p' "$out/memory.txt")
    [ -n "$speeds" ] || speeds=$(sed -n 's/^[[:space:]]*Speed: *//p' "$out/memory.txt")
    note='可 (1067MT/s 前後は目安)'
    [ -n "$speeds" ] || note=未取得
    printf '%s\n' "$speeds" | grep -q '^800 ' && note='可・注意: 800MT/s (目安)'
    printf 'メモリ: %s / %s / %s (スロット・部品番号は詳細)\n' "${mem:-未取得}" "$(printf '%s' "$speeds" | tr '\n' '/')" "$note"
    if [ "$profile" = g560 ]; then
        gpu='未取得'; grep -qi '8086:0046' "$out/pci.txt" && gpu=UMA
        grep -qi '10de:0a70' "$out/pci.txt" && gpu=DIS
        sata=未取得; grep -qi '8086:3b29' "$out/pci.txt" && sata=AHCI
        grep -qi '8086:3b28' "$out/pci.txt" && sata=IDE
        printf 'G560 目安: GPU=%s SATA=%s メモリ公式上限8GB(SMBIOS16GBは保証外)\n' "$gpu" "$sata"
        EXPECT_LAN=0
        grep -qi '10ec:8136' "$out/pci.txt" && EXPECT_LAN=100
        grep -qi '10ec:8168' "$out/pci.txt" && EXPECT_LAN=1000
        num=$(printf '%s' "$bios" | sed -n 's/^29CN\([0-9][0-9]\)WW.*/\1/p')
        if [ "$gpu" = DIS ] && [ -n "$num" ] && [ "$num" -lt 31 ]; then
            echo 'G560 目安: 画面異常は既知の VBIOS 不具合の範囲 (29CN31WWより古い)'
        fi
        echo 'G560: TrackPoint・指紋・TPM非搭載は減点しない。無線スイッチ位置は手動'
    fi
    input=$(read_value "$HW_PROC/bus/input/devices")
    if [ "$input" = 不明 ]; then echo '入力: 未取得'; else
        for device in 'AT Translated Set 2 keyboard' 'SynPS/2 Synaptics TouchPad'; do
            if printf '%s' "$input" | grep -Fq "$device"; then printf '入力: 可 %s (動作は手動)\n' "$device";
            else printf '入力: 未試験 %s 未認識\n' "$device"; fi
        done
        if [ "$EXPECT_TRACKPOINT" = 1 ]; then
            if printf '%s' "$input" | grep -Fq 'TPPS/2 IBM TrackPoint'; then echo 'TrackPoint: 可 (認識、動作は手動)';
            else echo 'TrackPoint: 不可候補 (未認識、手動確認)'; fi
        fi
    fi
    drm=
    for port in "$HW_SYSFS"/class/drm/card*-*; do
        [ -r "$port/status" ] || continue
        drm="$drm ${port##*/}:$(read_value "$port/status"):$(read_value "$port/modes")"
    done
    printf '液晶/DRM: %s (1366x768目安) backlight:%s\n' "${drm:-未取得}" "$(ls "$HW_SYSFS/class/backlight" 2>/dev/null | tr '\n' ' ')"
    printf 'USB: %s (Edge/G560: EHCI 480M目安、実ポートは未試験)\n' "$(head -n 1 "$out/usb.txt")"
    wireless=未取得
    grep -qi '8086:0084' "$out/pci.txt" && wireless='Intel 1000: 2.4GHzのみ正常'
    grep -qi '8086:422c' "$out/pci.txt" && wireless='Intel 6200: 2.4/5GHz目安'
    grep -qi '14e4:4727' "$out/pci.txt" && wireless='BCM4313: 2.4GHz/firmware-brcm80211目安'
    grep -qi '168c:002b' "$out/pci.txt" && wireless='AR9285: ath9k目安'
    if [ "$wireless" = 未取得 ] && grep -qi 'Intel.*Wireless\|Wireless.*Intel' "$out/pci.txt"; then wireless='Intel (構成は詳細)'; fi
    printf '無線: %s / iw:%s\n' "$wireless" "$(head -n 1 "$out/iw-dev.txt")"
    printf 'rfkill: %s (Hard blocked はスイッチも手動確認)\n' "$(grep -E 'blocked:|未取得' "$out/rfkill.txt" | tr '\n' ' ')"
    if grep -Ei '(iwlwifi|firmware).*(fail|error|not found)' "$out/dmesg.txt" > "$out/firmware-errors.txt"; then echo '無線: 可・注意: firmware失敗 (詳細ログ)'; fi
    if [ -r "$out/details/hw-ports.txt" ]; then
        awk -v e="$EXPECT_LAN" -v n="$EXPECT_NOTE" '/^NIC / {
            v="未試験"; if($0 ~ /リンク=yes|リンク=up/) {
                if(e==0) v="可 (期待速度は未確認)"
                else if(index($0,"速度=" e "Mb/s duplex=Full")) v="良"
                else v=n " (速度/duplex、ケーブルも確認)"
            }
            print "有線: " v " " $0
        }' "$out/details/hw-ports.txt"
    fi
    vmx=未取得
    if [ -r "$HW_PROC/cpuinfo" ]; then
        vmx='無 (i3/i5はBIOS無効候補、Celeron/Pentiumは仕様の可能性)'
        grep -Eq '(^| )vmx( |$)' "$HW_PROC/cpuinfo" && vmx=有
    fi
    printf '仮想化 vmx: %s\n' "$vmx"
}
disk_checks() {
    if [ ! -s "$out/internal-disks.txt" ]; then echo '内蔵ディスク: 未試験 (起動媒体未判定または対象なし)'; fi
    while IFS= read -r disk; do
        # 既存 hw-disks の情報を再利用し、SMART を重ねて取得しない。
        awk -v disk="$disk" '
            /^ディスク:/ {active=($2==disk)} active {print}
        ' "$out/details/hw-disks.txt" > "$out/disk-$disk.txt"
        data=$out/disk-$disk.txt
        verdict=未取得
        health=$(field "$data" 'SMART 健康')
        [ "$health" != PASSED ] || verdict=可
        case "$health" in *FAIL*) verdict=不可 ;; esac
        if awk '/^SMART (197|198) / && $4+0>0 {bad=1} END {exit !bad}' "$data"; then verdict=不可; fi
        if grep -Eq '^[[:space:]]*locked[[:space:]]*$' "$out/security-$disk.txt"; then verdict=不可; fi
        attrs=$(awk '/^SMART (5|197|198|187|196|199|10|194) / {printf "%s=%s ",$2,$4}' "$data")
        note=
        if awk '/^SMART 5 / && $4+0>0 {bad=1} END {exit !bad}' "$data"; then note='注意:5が非0'; fi
        printf 'ディスク %s: %s %s %s SATA:%s (3.0Gb/s目安) ' "$disk" "$verdict" "$attrs" "$note" "$(field "$data" 'SATA リンク')"
        security=$(sed -n '/^[[:space:]]*Security:/,/^[^[:space:]]/p' "$out/security-$disk.txt" | grep -E 'locked|enabled|frozen|supported' | tr '\n' ' ')
        printf 'Security %s: %s (frozenは正常)\n' "$disk" "${security:-未取得}"
    done < "$out/internal-disks.txt"
    if [ -r "$out/details/hw-disk-speed.txt" ]; then grep -E '中央値|未取得|読み出しエラー' "$out/details/hw-disk-speed.txt" || :; else echo '速度: 未取得'; fi
    if grep -Ei 'limiting speed|(^|[^[:alpha:]])PIO([^[:alpha:]]|$)' "$out/dmesg.txt" > "$out/sata-errors.txt"; then echo 'SATA: 可・注意: limiting speed/PIO (詳細ログ)'; fi
}
cooling_check() {
    idle=$(temperature "$out/idle-sensors.txt")
    crit=$(awk '/temp[0-9]+_crit:/ && $2>0 {if(!n++||$2<c) c=$2} END {if(n) print c}' "$out/idle-sensors.txt")
    [ -n "$crit" ] || crit=95
    if [ "$swap_ready" != 1 ] || [ -z "$idle" ] || ! command -v stress-ng >/dev/null 2>&1; then
        echo '冷却: 未試験 (swap停止・温度センサー・stress-ng のいずれか未取得)'; return
    fi
    if awk -v t="$idle" -v c="$crit" 'BEGIN {exit !(t>=c-5)}'; then
        printf '冷却: 不可候補 idle=%s°C (crit=%s近傍のため負荷省略)\n' "$idle" "$crit"; return
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
        printf 'MHz %s\n' "${clock:-未取得}" >> "$out/clocks.txt"
        if [ -n "$clock" ]; then
            lowclock=$(awk -v a="$lowclock" -v b="$clock" 'BEGIN {print (a==""||b<a?b:a)}')
            highclock=$(awk -v a="$highclock" -v b="$clock" 'BEGIN {print (b>a?b:a)}')
        fi
        sleep 2
    done
    status=0; wait "$stress_pid" || status=$?
    trap - HUP INT TERM
    verdict=良
    [ "$status" = 0 ] || verdict='未試験 (stress-ng失敗)'
    [ "$stopped" = 0 ] || verdict='不可候補 (crit近傍または温度取得不能で停止)'
    clocknote=
    if [ -n "$highclock" ] && [ -n "$lowclock" ] && awk -v a="$lowclock" -v b="$highclock" 'BEGIN {exit !(a<b*0.7)}'; then clocknote='クロック低下あり(省電力との切り分けは手動)'; fi
    printf '冷却: %s idle=%s/最大=%s°C (idle45〜65目安、crit=%s) MHz=%s〜%s %s\n' "$verdict" "$idle" "$peak" "$crit" "${lowclock:-未取得}" "${highclock:-未取得}" "$clocknote"
    echo 'ファン: 手動 (Edgeの読み値・未取得では故障判定しない)'
}
long_checks() {
    [ "$long" = 1 ] || { echo 'SMART long / メモリ実試験: 未試験 (--longで追加)'; return; }
    # 長時間試験はディスク同士を並列実行し、CPU負荷試験のあとにメモリを確保する。
    pids=
    while IFS= read -r disk; do
        (
            if ! command -v smartctl >/dev/null 2>&1; then missing smartctl; exit; fi
            smartctl -l selftest "/dev/$disk" > "$out/before-long-$disk.txt" 2>&1 || :
            if ! smartctl -t long "/dev/$disk" > "$out/long-$disk.txt" 2>&1; then
                echo '未取得: SMART long 開始失敗' >> "$out/long-$disk.txt"; exit
            fi
            poll=0
            while [ "$poll" -lt 360 ]; do
                sleep 60
                smartctl -c "/dev/$disk" > "$out/progress-$disk.txt" 2>&1 || {
                    echo '未取得: SMART long 状態' >> "$out/long-$disk.txt"; exit;
                }
                if ! grep -qi 'in progress' "$out/progress-$disk.txt"; then
                    smartctl -l selftest "/dev/$disk" >> "$out/long-$disk.txt" 2>&1 || :
                    exit
                fi
                poll=$((poll+1))
            done
            echo '未試験: SMART long 待機期限6時間' >> "$out/long-$disk.txt"
        ) &
        pids="$pids $!"
    done < "$out/internal-disks.txt"
    available=$(awk '/^MemAvailable:/ {print int($2/2048)}' "$HW_PROC/meminfo" 2>/dev/null)
    memstatus=未試験
    if [ "$swap_ready" = 1 ] && [ -n "$available" ] && [ "$available" -gt 0 ] && command -v memtester >/dev/null 2>&1; then
        if memtester "${available}M" 1 > "$out/memtester.txt" 2>&1; then memstatus=良; else memstatus=不可; fi
    fi
    for pid in $pids; do wait "$pid" || :; done
    printf 'メモリ実試験: %s (MemAvailable半分以下 %sMiB / 1パス、swap停止)\n' "$memstatus" "${available:-未取得}"
    while IFS= read -r disk; do
        verdict=未取得
        latest=$(grep -E '^#[[:space:]]*1[[:space:]]' "$out/long-$disk.txt" | head -n 1)
        previous=$(grep -E '^#[[:space:]]*1[[:space:]]' "$out/before-long-$disk.txt" | head -n 1)
        if [ -n "$latest" ] && [ "$latest" != "$previous" ]; then
            printf '%s' "$latest" | grep -q 'Extended.*Completed without error' && verdict=良
            printf '%s' "$latest" | grep -Ei 'read failure|electrical failure|servo.*failure' >/dev/null && verdict=不可
        fi
        printf 'SMART long %s: %s (詳細ログ、未対応・中断は未試験)\n' "$disk" "$verdict"
    done < "$out/internal-disks.txt"
}
