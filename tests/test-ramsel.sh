#!/bin/sh
# bootkit-ramsel の静的試験と起動スクリプトの単体試験。通信不要。
# QEMU の実起動は含まない (重い検証は ventoy/ramsel/verify-qemu.py で行う)。
set -eu
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
RAMSEL=$HERE/ventoy/ramsel
WORK=$(mktemp -d "$HERE/test-ramsel.XXXXXX")
trap 'rm -rf "$WORK"' 0
trap 'exit 1' HUP INT TERM

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf 'ok: %s\n' "$*"; }
contains() { grep -Fqx -- "$2" "$1" || fail "$1: 次の行が無い: $2"; }

# 1. 構文と ORDER の固定。
sh -n "$RAMSEL/30bootkit-ramsel"
sh -n "$RAMSEL/make-injection.sh"
sh -n "$RAMSEL/make-trial-iso.sh"
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -s sh "$RAMSEL/30bootkit-ramsel" || fail 'shellcheck'
    shellcheck -s sh "$RAMSEL/make-injection.sh" || fail 'shellcheck'
    shellcheck -s sh "$RAMSEL/make-trial-iso.sh" || fail 'shellcheck'
fi
python3 -I -m py_compile "$RAMSEL/rebuild-initrd.py" "$RAMSEL/verify-qemu.py" ||
    fail 'py_compile'
python3 -I "$RAMSEL/verify-qemu.py" --help >/dev/null || fail '--help'
ok '構文'

# 置換 ORDER は標準の 4 行を含み、env/failed の接続を持つ。
for line in \
    '/scripts/casper-premount/10driver_updates "$@"' \
    '[ -e /conf/param.conf ] && . /conf/param.conf' \
    '/scripts/casper-premount/20iso_scan "$@"' \
    '/scripts/casper-premount/30bootkit-ramsel "$@"' \
    'if [ -f /run/bootkit-ramsel/env ]; then . /run/bootkit-ramsel/env; fi' \
    'if [ -f /run/bootkit-ramsel/failed ]; then panic "bootkit-ramsel: $(cat /run/bootkit-ramsel/failed)"; fi'; do
    contains "$RAMSEL/ORDER" "$line"
done
ok 'ORDER'

# 置換 ORDER に含まれる標準 4 行は rebuild-initrd.py の固定値と一致する (ずれ検出)。
python3 -I - "$RAMSEL/ORDER" "$RAMSEL/rebuild-initrd.py" <<'PY'
import importlib.util
import sys
order = open(sys.argv[1], 'rb').read()
spec = importlib.util.spec_from_file_location('rebuild_initrd', sys.argv[2])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
assert module.STOCK_ORDER in order, 'ORDER に標準 4 行が無い'
print('ok: ORDER の固定')
PY

# 2. 起動スクリプトの単体試験。mount/umount だけを stub にする。
STUBS=$WORK/stubs
mkdir -p "$STUBS"
cat >"$STUBS/mount" <<'STUB'
#!/bin/sh
# 最後の引数をマウント先とみなし、$FIXTURE_MEDIA の中身を写す。
printf '%s\n' "$*" >>"$MOUNT_LOG"
dest=""
for arg in "$@"; do dest=$arg; done
mkdir -p "$dest"
cp -a "$FIXTURE_MEDIA/." "$dest/"
exit 0
STUB
cat >"$STUBS/umount" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"$MOUNT_LOG"
exit 0
STUB
chmod +x "$STUBS/mount" "$STUBS/umount"

MEDIA=$WORK/media
mkdir -p "$MEDIA/casper/bootkit-chains" "$MEDIA/.disk"
printf 'x%.0s' $(seq 1 2048) >"$MEDIA/casper/test.base.squashfs"
printf 'y%.0s' $(seq 1 1024) >"$MEDIA/casper/test.base.plus.squashfs"
printf 'meta' >"$MEDIA/casper/test.base.manifest"
printf 'info' >"$MEDIA/.disk/info"
cat >"$MEDIA/casper/bootkit-chains/test.list" <<'LIST'
test.base.squashfs
test.base.plus.squashfs
LIST

env_for() {
    # $1: cmdline、$2: meminfo の MemAvailable 行
    printf '%s' "$1" >"$WORK/cmdline"
    printf '%s\n' "$2" 'MemFree:         1000 kB' >"$WORK/meminfo"
}

run_script() {
    RUN=$WORK/run-$1
    TARGET=$WORK/target-$1
    rm -rf "$RUN" "$TARGET"
    mkdir -p "$RUN" "$TARGET"
    export BOOTKIT_RAMSEL_CMDLINE=$WORK/cmdline BOOTKIT_RAMSEL_MEMINFO=$WORK/meminfo
    export BOOTKIT_RAMSEL_RUN=$RUN BOOTKIT_RAMSEL_TARGET=$TARGET
    export BOOTKIT_RAMSEL_SCAN_WAIT=1 FIXTURE_MEDIA=$MEDIA MOUNT_LOG=$WORK/mount-$1.log
    : >"$WORK/dev-fake"
    export BOOTKIT_RAMSEL_DEVICES=$WORK/dev-fake
    export PATH="$STUBS:/usr/bin:/bin"
    : >"$WORK/mount-$1.log"
    if sh "$RAMSEL/30bootkit-ramsel" >"$WORK/stdout-$1.log" 2>&1; then
        printf '0'
    else
        printf '1'
    fi
}

# 成功: toram + bootkit.os。
env_for 'BOOT_IMAGE=x toram bootkit.os=test --- quiet' 'MemAvailable:    8000000 kB'
[ "$(run_script good)" = 0 ] || fail '成功するはずが失敗'
[ ! -e "$WORK/run-good/failed" ] || fail 'failed が残った'
[ -f "$WORK/target-good/casper/test.base.squashfs" ] || fail '層が写っていない'
[ -f "$WORK/target-good/casper/test.base.plus.squashfs" ] || fail '層が写っていない (2)'
[ -f "$WORK/target-good/casper/test.base.manifest" ] || fail 'manifest が写っていない'
[ -f "$WORK/target-good/.disk/info" ] || fail '.disk が写っていない'
cmp -s "$MEDIA/casper/test.base.squashfs" "$WORK/target-good/casper/test.base.squashfs" ||
    fail '写し誤り'
contains "$WORK/run-good/env" 'LIVEMEDIA='"$WORK/target-good"
contains "$WORK/run-good/env" 'unset TORAM'
ok '成功 (選択複写と env)'

# toram が無い: 何もしない。
env_for 'BOOT_IMAGE=x bootkit.os=test --- quiet' 'MemAvailable:    8000000 kB'
[ "$(run_script no-toram)" = 0 ] || fail 'no-toram で失敗'
[ ! -e "$WORK/run-no-toram/env" ] || fail 'no-toram で env を書いた'
[ ! -s "$WORK/mount-no-toram.log" ] || fail 'no-toram で mount した'
ok 'toram 無しは何もしない'

# bootkit.os が無い: 何もしない。
env_for 'BOOT_IMAGE=x toram --- quiet' 'MemAvailable:    8000000 kB'
[ "$(run_script no-os)" = 0 ] || fail 'no-os で失敗'
[ ! -e "$WORK/run-no-os/env" ] || fail 'no-os で env を書いた'
[ ! -s "$WORK/mount-no-os.log" ] || fail 'no-os で mount した'
ok 'bootkit.os 無しは何もしない'

# RAM 不足: 黙って続かず failed。
env_for 'BOOT_IMAGE=x toram bootkit.os=test --- quiet' 'MemAvailable:      10000 kB'
[ "$(run_script poor)" = 1 ] || fail 'RAM 不足で止まらない'
grep -Fq 'RAM が足りない' "$WORK/run-poor/failed" || fail '理由が違う'
[ ! -e "$WORK/run-poor/env" ] || fail 'RAM 不足で env を書いた'
ok 'RAM 不足は失敗する'

# 不正な os 値: 失敗する。
env_for 'BOOT_IMAGE=x toram bootkit.os=../x --- quiet' 'MemAvailable:    8000000 kB'
[ "$(run_script bados)" = 1 ] || fail '不正な os で止まらない'
ok '不正な os 値は失敗する'

# 連鎖に無い層: 失敗する。
printf 'nope.squashfs\n' >"$MEDIA/casper/bootkit-chains/broken.list"
env_for 'BOOT_IMAGE=x toram bootkit.os=broken --- quiet' 'MemAvailable:    8000000 kB'
[ "$(run_script broken)" = 1 ] || fail '欠落層で止まらない'
grep -Fq '層が媒体に無い' "$WORK/run-broken/failed" || fail '理由が違う'
ok '欠落層は失敗する'

printf 'ALL OK\n'
