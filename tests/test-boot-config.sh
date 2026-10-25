#!/bin/sh
# lb と initramfs hook の外部処理だけをスタブにする。実デバイスには触れない。
set -eu
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
SOURCE=${BOOT_CONFIG_SOURCE:-$HERE}
WORK=$(mktemp -d "$HERE/test-boot-config.XXXXXX")
trap 'rm -rf "$WORK"' 0
trap 'exit 1' HUP INT TERM
cp -R "$SOURCE/auto" "$SOURCE/config" "$WORK/"
mkdir -p "$WORK/bin"
cat > "$WORK/bin/lb" <<'STUB'
#!/bin/sh
printf '%s\n' "$@"
STUB
chmod +x "$WORK/bin/lb"
PATH=$WORK/bin:$PATH
export PATH
cd "$WORK"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
contains() { grep -Fqx -- "$2" "$1" || fail "$1: $2 がない"; }
arg() {
    actual=$(awk -v key="$1" '$0 == key { getline; print; exit }' lb.log)
    [ "$actual" = "$2" ] || fail "$1: $actual (期待: $2)"
}
safe=config/includes.chroot/etc/initramfs-tools/scripts/init-top/bootkit-safe
hook=config/includes.chroot/etc/initramfs-tools/hooks/bootkit-safe
# テンプレートの各項目を区切って調べ、他の項目の文字列では代用できなくする。
entry() {
    awk -v title="$2" '
        /^label / || /^menuentry / { active = 0 }
        index($0, title) { active = 1 }
        active { print }
    ' "$1" > entry.log
    contains entry.log "$3"
}
check_templates() {
    sys=config/bootloaders/syslinux_common
    grub=config/bootloaders/grub-pc
    contains config/bootloaders/isolinux/isolinux.cfg 'include menu.cfg'
    contains config/bootloaders/syslinux/syslinux.cfg 'include menu.cfg'
    contains "$sys/menu.cfg" 'include live.cfg'
    contains "$sys/menu.cfg" 'include stdmenu.cfg'
    contains "$sys/menu.cfg" '@OPTIONAL_INSTALLER_INCLUDE@'
    contains "$sys/utilities.cfg" '@OPTIONAL_MEMTEST_INCLUDE@'
    contains "$sys/memtest.cfg" 'label memtest'
    grep -q 'menu label .*Memtest86+' "$sys/memtest.cfg" || fail 'BIOS の Memtest86+ がない'
    contains "$sys/live.cfg.in" 'label live-@FLAVOUR@'
    contains "$sys/live.cfg.in" 'label live-@FLAVOUR@-failsafe'
    [ "$(grep -c 'menu default' "$sys/live.cfg.in")" = 1 ] || fail '既定項目が変わった'
    tab=$(printf '\t')
    entry "$sys/live.cfg.in" 'Live system, copy to RAM' "${tab}append @APPEND_LIVE@ toram"
    entry "$sys/live.cfg.in" 'Live system, safe mode' "${tab}append @APPEND_LIVE@ bootkit.safe=1"
    contains "$grub/grub.cfg" 'source /boot/grub/config.cfg'
    contains "$grub/grub.cfg" '@LINUX_LIVE@'
    contains "$grub/grub.cfg" "${tab}if @ENABLE_MEMTEST@; then"
    contains "$grub/grub.cfg" "source${tab}/boot/grub/install_start.cfg"
    contains "$grub/grub.cfg" "submenu 'Utilities...' --hotkey=u {"
    entry "$grub/grub.cfg" 'menuentry "Live system, copy to RAM"' "${tab}linux @KERNEL_LIVE@ @APPEND_LIVE@ toram"
    entry "$grub/grub.cfg" 'menuentry "Live system, safe mode"' "${tab}linux @KERNEL_LIVE@ @APPEND_LIVE@ bootkit.safe=1"
    [ "$(grep -c "${tab}initrd @INITRD_LIVE@" "$grub/grub.cfg")" = 2 ] || fail '追加項目の initrd がない'
    contains "$grub/memtest.cfg" "${tab}${tab}linux @MEMTEST_DIR@/memtest.efi"
    contains "$grub/memtest.cfg" "${tab}${tab}linux @MEMTEST_DIR@/memtest.bin"
    [ "$(grep -c 'menuentry "Memtest86+"' "$grub/memtest.cfg")" = 3 ] || fail 'GRUB の Memtest86+ がない'
    for file in config.cfg theme.cfg live-theme/theme.txt install_text.cfg install_gui.cfg install_start_text.cfg install_start_gui.cfg; do
        [ -s "$grub/$file" ] || fail "標準テンプレート $file がない"
    done
}
check_safe() {
    [ -x "$safe" ] && [ -x "$hook" ] || fail '安全モードが実行可能でない'
    sh -n "$safe"
    sh -n "$hook"
    rules=$WORK/rules
    BOOTKIT_CMDLINE=$WORK/cmdline BOOTKIT_RULES_DIR=$rules
    export BOOTKIT_CMDLINE BOOTKIT_RULES_DIR
    # 無指定・紛らわしい指定・prereqs 問い合わせでは何も作らない。
    for line in 'boot=live' 'bootkit.safe=10' 'xbootkit.safe=1' 'bootkit.safe=1x' 'bootkit.safe=0'; do
        printf '%s\n' "$line" > "$BOOTKIT_CMDLINE"
        sh "$safe"
        [ ! -e "$rules" ] || fail "$line でルールが作られた"
    done
    printf '%s\n' 'boot=live bootkit.safe=1 quiet' > "$BOOTKIT_CMDLINE"
    [ -z "$(sh "$safe" prereqs)" ] || fail '安全モード自体に前提がある'
    [ ! -e "$rules" ] || fail 'prereqs でルールが作られた'
    sh "$safe"
    for name in 64-md-raid-assembly.rules 63-md-raid-arrays.rules 69-lvm.rules; do
        [ -f "$rules/$name" ] && [ ! -s "$rules/$name" ] || fail "$name が空のマスクでない"
    done
    # shellcheck disable=SC2016
    contains "$rules/99-bootkit-safe.rules" 'SUBSYSTEM=="block", ACTION=="add|change", KERNEL!="loop*|ram*|sr*|zram*", RUN+="/sbin/blockdev --setro $devnode"'
    [ "$(find "$rules" -type f | wc -l | tr -d ' ')" = 4 ] || fail '予期しないルールがある'
    rm -r "$rules"
    # 先頭・末尾・唯一の引数でも一致する。
    for line in 'bootkit.safe=1' 'bootkit.safe=1 quiet' 'quiet bootkit.safe=1'; do
        printf '%s\n' "$line" > "$BOOTKIT_CMDLINE"
        sh "$safe"
        [ -f "$rules/99-bootkit-safe.rules" ] || fail "$line が認識されない"
        rm -r "$rules"
    done
}
check_hook() {
    DESTDIR=$WORK/initrd
    CONFDIR=$WORK/initramfs-conf
    BOOTKIT_HOOK_FUNCTIONS=$WORK/hook-functions
    export DESTDIR CONFDIR BOOTKIT_HOOK_FUNCTIONS
    mkdir -p "$DESTDIR/scripts/init-top"
    cp "$safe" "$DESTDIR/scripts/init-top/bootkit-safe"
    # trixie udev の prereqs と同じ書式。他の依存も保持することを確認する。
    cat > "$DESTDIR/scripts/init-top/udev" <<'UDEV'
#!/bin/sh
PREREQS="existing"
case "${1:-}" in
    prereqs) echo "$PREREQS"; exit 0 ;;
esac
UDEV
    cat > "$BOOTKIT_HOOK_FUNCTIONS" <<'FUNCS'
copy_exec() { printf '%s\n' "$*" > "$DESTDIR/copy-exec.log"; }
FUNCS
    [ -z "$(sh "$hook" prereqs)" ] || fail 'hook 自体に前提がある'
    [ ! -e "$DESTDIR/copy-exec.log" ] || fail 'hook prereqs に副作用がある'
    sh "$hook"
    contains "$DESTDIR/copy-exec.log" '/sbin/blockdev /sbin'
    sh "$hook"
    sh -n "$DESTDIR/scripts/init-top/udev"
    cmp "$DESTDIR/scripts/init-top/udev" "$CONFDIR/scripts/init-top/udev"
    [ "$(sh "$DESTDIR/scripts/init-top/udev" prereqs)" = 'existing bootkit-safe' ] || fail 'udev の依存順が不正'
    # initramfs-tools と同じ依存辺で tsort し、実際の順序も調べる。
    { printf '%s\n' 'bootkit-safe bootkit-safe' 'udev udev';
      for dep in $(sh "$CONFDIR/scripts/init-top/udev" prereqs); do
          printf '%s udev\n' "$dep"
      done; } | tsort > order.log
    awk '/^bootkit-safe$/ { safe=NR } /^udev$/ { udev=NR } END { exit !(safe && udev && safe < udev) }' order.log || fail '安全モードが udev より前でない'
    printf '%s\n' '#!/bin/sh' 'CHANGED_FORMAT=yes' > "$DESTDIR/scripts/init-top/udev"
    if sh "$hook"; then fail '未知の udev 書式でビルドを続行した'; fi
    rm -r "$DESTDIR" "$CONFDIR"
}
for arch in amd64 arm64; do
    for flavor in icewm cli lxqt; do
        ARCH=$arch FLAVOR=$flavor sh auto/config > lb.log
        arg --architectures "$arch"
        case "$arch" in
            amd64) arg --bootloaders syslinux,grub-efi; arg --memtest memtest86+ ;;
            arm64) arg --bootloaders grub-efi; arg --memtest none ;;
        esac
        check_templates
        check_safe
        check_hook
        printf 'PASS: %s / %s\n' "$arch" "$flavor"
    done
done
printf '%s\n' 'ALL PASS: 起動テンプレート・安全モード・initramfs の依存順・lb 引数'
