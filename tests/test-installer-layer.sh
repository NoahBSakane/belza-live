#!/bin/sh
# Real POSIX sh/tar copies; only Linux-only mount/attributes/devices are mocked.
set -eu
HERE=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
script=${BOOTKIT_LAYER_SCRIPT:-$HERE/config/includes.installer/usr/lib/live-installer.d/00bootkit-layer}
WORK=$(mktemp -d "$HERE/test-installer-layer.XXXXXX")
trap 'rm -rf "$WORK"' 0
trap 'exit 1' HUP INT TERM
mkdir -p "$WORK/bin" "$WORK/source" "$WORK/target" "$WORK/live" "$WORK/tmp"
cat > "$WORK/bin/mount" <<'STUB'
#!/bin/sh
[ "${MOUNT_FAIL:-0}" = 0 ] || exit 1
[ "$1 $2 $3 $4" = '-t squashfs -o loop,ro' ] || exit 1
printf 'mount\n' >> "$CALLS"
(cd "$SOURCE" && tar cf - .) | (cd "$6" && tar xf -)
STUB
cat > "$WORK/bin/umount" <<'STUB'
#!/bin/sh
# Detect cleanup attempting to unmount its own current working directory.
case "$PWD/" in "$1/"*) exit 1 ;; esac
printf 'umount\n' >> "$CALLS"
STUB
cat > "$WORK/bin/find" <<'STUB'
#!/bin/sh
case " $* " in
    *' -type c '*)
        if [ "${WHITEOUT:-0}" = 1 ]; then
            exec sh -c "$7" sh "$1/fake-whiteout"
        fi
        exit 0 ;;
esac
exec "$REAL_FIND" "$@"
STUB
cat > "$WORK/bin/mknod" <<'STUB'
#!/bin/sh
[ "$2" = p ] || exit 1
exec "$REAL_MKFIFO" "$1"
STUB
cat > "$WORK/bin/ls" <<'STUB'
#!/bin/sh
case "$*" in
    *fake-whiteout) printf '%s\n' 'crw------- 1 0 0 0, 0 Oct 29 00:00 fake-whiteout'; exit 0 ;;
esac
exec "$REAL_LS" "$@"
STUB
cat > "$WORK/bin/tar" <<'STUB'
#!/bin/sh
for arg do
    case "$arg" in --*) echo 'udeb tar: long options disabled' >&2; exit 2 ;; esac
done
exec "$REAL_TAR" "$@"
STUB
for tool in stat mkfifo; do
    printf '#!/bin/sh\necho "udeb: applet disabled" >&2\nexit 127\n' > "$WORK/bin/$tool"
done
cat > "$WORK/bin/getfattr" <<'STUB'
#!/bin/sh
printf '%s\n' '# file: ./usr/bin/gui' 'security.capability=0sAAAA' 
[ "${OPAQUE:-0}" = 0 ] || printf '%s\n' 'trusted.overlay.opaque="y"'
exit 0
STUB
cat > "$WORK/bin/setfattr" <<'STUB'
#!/bin/sh
printf 'attrs\n' >> "$CALLS"
STUB
chmod +x "$WORK/bin/"*
REAL_FIND=$(command -v find)
REAL_TAR=$(command -v tar)
REAL_LS=$(command -v ls)
REAL_MKFIFO=$(command -v mkfifo)
export REAL_FIND REAL_TAR REAL_LS REAL_MKFIFO
PATH=$WORK/bin:$PATH
SOURCE=$WORK/source CALLS=$WORK/calls
BOOTKIT_CMDLINE=$WORK/cmdline BOOTKIT_MEDIUM=$WORK/live BOOTKIT_TARGET=$WORK/target
BOOTKIT_TMPDIR=$WORK/tmp BOOTKIT_SYSLOG=$WORK/syslog BOOTKIT_NO_TTY=1
export PATH SOURCE CALLS BOOTKIT_CMDLINE BOOTKIT_MEDIUM BOOTKIT_TARGET BOOTKIT_TMPDIR BOOTKIT_SYSLOG BOOTKIT_NO_TTY
fail() { echo "FAIL: $*" >&2; cat "$WORK/output" >&2; cat "$CALLS" >&2; exit 1; }
for path in boot/kernel etc/fstab etc/crypttab etc/default/locale var/cache/apt/pkg var/lib/apt/lists/pkg var/log/apt/history usr/bin/gui; do
    mkdir -p "$SOURCE/$(dirname "$path")"
    printf 'layer\n' > "$SOURCE/$path"
done
ln "$SOURCE/usr/bin/gui" "$SOURCE/usr/bin/gui-link"
ln "$SOURCE/usr/bin/gui" "$SOURCE/etc/gui-hardlink"
chmod 750 "$SOURCE/etc"
chmod 710 "$SOURCE/etc/default"
ln -s gui "$SOURCE/usr/bin/gui-symlink"
chmod 755 "$SOURCE/usr/bin/gui"
for flavor in icewm lxqt; do printf 'image\n' > "$WORK/live/10-$flavor.squashfs"; done
run() {
    : > "$CALLS"
    printf '%s\n' "$1" > "$WORK/cmdline"
    sh "$script" > "$WORK/output" 2>&1 || fail 'hook stopped installer'
    [ -z "$(ls -A "$WORK/tmp")" ] || fail 'workspace/mount not cleaned'
}
for cmdline in 'boot=live' 'bootkit.flavor=cli' 'bootkit.flavor=unknown' 'xbootkit.flavor=icewm'; do
    run "$cmdline"
    [ ! -s "$CALLS" ] || fail "unexpected layer for $cmdline"
done
for flavor in icewm lxqt; do
    for path in etc/fstab etc/crypttab etc/default/locale; do
        mkdir -p "$WORK/target/$(dirname "$path")"
        printf 'installer\n' > "$WORK/target/$path"
    done
    run "auto=true bootkit.flavor=$flavor priority=critical"
    [ -f "$WORK/target/usr/bin/gui" ] || fail 'selected layer not copied'
    [ -x "$WORK/target/usr/bin/gui" ] || fail 'mode lost'
    # shellcheck disable=SC3013
    [ "$WORK/target/usr/bin/gui" -ef "$WORK/target/usr/bin/gui-link" ] || fail 'hardlink lost'
    # shellcheck disable=SC3013
    [ "$WORK/target/usr/bin/gui" -ef "$WORK/target/etc/gui-hardlink" ] || fail 'cross-directory hardlink lost'
    python3 - "$WORK/target" <<'PYTHON'
import os
import stat
import sys
assert stat.S_IMODE(os.stat(sys.argv[1] + '/etc').st_mode) == 0o750
assert stat.S_IMODE(os.stat(sys.argv[1] + '/etc/default').st_mode) == 0o710
PYTHON
    [ -L "$WORK/target/usr/bin/gui-symlink" ] || fail 'symlink lost'
    for path in etc/fstab etc/crypttab etc/default/locale; do
        [ "$(cat "$WORK/target/$path")" = installer ] || fail "excluded $path overwritten"
    done
    for path in boot/kernel var/cache/apt/pkg var/lib/apt/lists/pkg var/log/apt/history; do
        [ ! -e "$WORK/target/$path" ] || fail "excluded $path copied"
    done
    [ "$(cat "$CALLS")" = "$(printf 'mount\nattrs\numount')" ] || fail 'mount/attrs/cleanup missing'
    grep -q "flavor=$flavor bytes=6 seconds=.*layer applied" "$WORK/syslog" || fail 'metrics missing'
    rm -rf "$WORK/target/usr"
done
mv "$WORK/live/10-icewm.squashfs" "$WORK/live/saved"
run 'bootkit.flavor=icewm'
grep -q 'layer missing; keeping CLI' "$WORK/output" || fail 'missing layer warning absent'
[ ! -s "$CALLS" ] || fail 'missing layer mounted'
mv "$WORK/live/saved" "$WORK/live/10-icewm.squashfs"
MOUNT_FAIL=1; export MOUNT_FAIL
run 'bootkit.flavor=icewm'
grep -q 'mount failed; keeping CLI' "$WORK/output" || fail 'mount failure warning absent'
unset MOUNT_FAIL
for condition in WHITEOUT OPAQUE; do
    export "$condition=1"
    run 'bootkit.flavor=icewm'
    [ ! -e "$WORK/target/usr/bin/gui" ] || fail "$condition layer copied"
    grep -Eq 'whiteout.*keeping CLI' "$WORK/output" || fail "$condition warning absent"
    [ "$(cat "$CALLS")" = "$(printf 'mount\numount')" ] || fail "$condition cleanup absent"
    unset "$condition"
done
sh -n "$script"
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck "$script" "$HERE/auto/assert-additive" "$HERE/tests/test-installer-layer.sh"
fi
echo 'ALL PASS: installer flavors, exclusions, links, fallback, whiteout/opaque, cleanup'
