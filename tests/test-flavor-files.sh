#!/bin/sh
# lb のみをスタブにして、フレーバーの生成・切り替えを検査する。
set -eu
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-$HERE}/test-flavor-files.XXXXXX")
trap 'rm -rf "$WORK"' 0
trap 'exit 1' HUP INT TERM
cp -R "$HERE/auto" "$HERE/config" "$WORK/"
if [ -n "${CONFIG_SOURCE:-}" ]; then
    cp "$CONFIG_SOURCE" "$WORK/auto/config"
fi
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
run_config() { FLAVOR=$1 sh auto/config > lb.log; }
hook=config/hooks/live/0100-no-modemmanager.hook.chroot
keys_hook=config/hooks/live/0200-icewm-keys.hook.chroot
kbd=config/includes.chroot/usr/local/bin/kbd-toggle
ime=config/includes.chroot/usr/local/bin/ime-on
keys=config/includes.chroot/etc/skel/.icewm/keys
packages=config/package-lists/icewm.list.chroot
check_icewm() {
    run_config icewm
    for file in "$hook" "$keys_hook" "$kbd" "$ime"; do
        [ -x "$file" ] || fail "$file が実行可能でない"
        sh -n "$file"
    done
    sh -n config/includes.chroot/etc/skel/.xinitrc
    sh -n config/includes.chroot/etc/skel/.bash_profile
    if command -v shellcheck >/dev/null 2>&1; then
        shellcheck -s sh "$hook" "$keys_hook" "$kbd" "$ime" config/includes.chroot/etc/skel/.xinitrc
        # .bashrc は Live ユーザーのホームに作られるため、ここでは追跡できない。
        shellcheck -s sh -e SC1091 config/includes.chroot/etc/skel/.bash_profile
    fi
    [ ! -e "$keys" ] || fail 'hook の実行前に keys が生成された'
    check_keys_hook
    for package in network-manager x11-xkb-utils kbd fcitx5 fcitx5-mozc \
        fcitx5-frontend-gtk3 fcitx5-frontend-qt5 im-config fonts-noto-cjk; do
        contains "$packages" "$package"
    done
    contains "$hook" 'apt-get purge -y modemmanager || :'
    contains "$hook" 'apt-get autoremove -y || :'
    contains config/includes.chroot/etc/skel/.config/autostart/org.fcitx.Fcitx5.desktop 'Hidden=true'
    contains config/includes.chroot/etc/skel/.xinitrc \
        'export GTK_IM_MODULE=fcitx QT_IM_MODULE=fcitx XMODIFIERS=@im=fcitx'
    if grep -q 'fcitx5' config/includes.chroot/etc/skel/.xinitrc; then
        fail 'X の開始時に Fcitx5 を起動している'
    fi
    contains lb.log 'boot=live components quiet locales=en_US.UTF-8 keyboard-layouts=jp timezone=Asia/Tokyo'
}
check_clean() {
    run_config "$1"
    for file in "$hook" "$keys_hook" "$kbd" "$ime" "$keys" "$packages"; do
        [ ! -e "$file" ] || fail "$1 への切り替え後に $file が残った"
    done
    [ ! -e config/includes.chroot/etc/skel ] || fail "$1 に icewm の設定が残った"
    [ ! -e config/includes.chroot/usr/local/bin ] || fail "$1 に icewm のコマンドが残った"
    [ -x config/includes.chroot/etc/initramfs-tools/scripts/init-top/bootkit-safe ] || fail "$1 に共通の安全モードがない"
    case "$1" in
        cli) [ ! -e config/package-lists/lxqt.list.chroot ] || fail 'cli に LXQt が残った' ;;
        lxqt)
            printf '%s\n' live-task-lxqt calamares calamares-settings-debian > expected-lxqt
            cmp expected-lxqt config/package-lists/lxqt.list.chroot
            ;;
    esac
}
check_keys_hook() {
    # hook 自体は固定のパスを使い、試験用コピーだけを書き換える。
    sed -e "s|/usr/share/icewm/keys|$WORK/default-keys|g" \
        -e "s|/etc/skel/.icewm|$WORK/skel/.icewm|g" \
        "$keys_hook" > test-keys-hook.sh
    cat > default-keys <<'DEFAULTS'
# 既定の全行を保持する。
key "Alt+Tab" switch-window
key "Alt+F4" close-window
key "Ctrl+Alt+T" x-terminal-emulator
DEFAULTS
    printf '%s\n' 'key "Ctrl+Alt+K" /usr/local/bin/kbd-toggle' \
        'key "Ctrl+Alt+J" /usr/local/bin/ime-on' > extra-keys
    cat default-keys extra-keys > expected-keys
    sh test-keys-hook.sh
    cmp expected-keys skel/.icewm/keys
    sh test-keys-hook.sh
    cmp expected-keys skel/.icewm/keys
    # 既定ファイルにも追加行がある場合に、重複しないことを確かめる。
    cat extra-keys >> default-keys
    sh test-keys-hook.sh
    cmp expected-keys skel/.icewm/keys
    rm default-keys
    sh test-keys-hook.sh 2> keys-warning.log
    cmp extra-keys skel/.icewm/keys
    [ -s keys-warning.log ] || fail '既定の keys がないときの警告がない'
    sh test-keys-hook.sh 2> keys-warning.log
    cmp extra-keys skel/.icewm/keys
}
sh -n auto/config
check_icewm
# 外部コマンドも偽物にし、切り替え・起動と失敗許容を実行して確認する。
cat > bin/setxkbmap <<'STUB'
#!/bin/sh
if [ "$1" = -query ]; then
    printf 'layout: %s\n' "$(cat "$MOCK_LAYOUT")"
else
    printf '%s\n' "$2" > "$MOCK_LAYOUT"
fi
STUB
cat > bin/loadkeys <<'STUB'
#!/bin/sh
printf '%s\n' "$1" > "$MOCK_KEYMAP"
printf 'Loading keymap\n'
STUB
cat > bin/fcitx5 <<'STUB'
#!/bin/sh
[ "$1" = -d ] && [ "$GTK_IM_MODULE" = fcitx ] &&
    [ "$QT_IM_MODULE" = fcitx ] && [ "$XMODIFIERS" = '@im=fcitx' ]
STUB
cat > bin/apt-get <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$MOCK_APT_LOG"
exit 1
STUB
chmod +x bin/setxkbmap bin/loadkeys bin/fcitx5 bin/apt-get
MOCK_LAYOUT=$WORK/layout MOCK_KEYMAP=$WORK/keymap MOCK_APT_LOG=$WORK/apt.log
XDG_STATE_HOME=$WORK/state
export MOCK_LAYOUT MOCK_KEYMAP MOCK_APT_LOG XDG_STATE_HOME
printf '%s\n' jp > "$MOCK_LAYOUT"
[ "$(DISPLAY=:99 sh "$kbd")" = us ] || fail 'X: jp → us'
contains "$MOCK_LAYOUT" us
[ "$(DISPLAY=:99 sh "$kbd")" = jp ] || fail 'X: us → jp'
contains "$MOCK_LAYOUT" jp
mkdir -p "$XDG_STATE_HOME"
printf '%s\n' jp > "$XDG_STATE_HOME/kbd-toggle-console"
[ "$(DISPLAY='' sh "$kbd")" = us ] || fail 'console: jp → us'
contains "$MOCK_KEYMAP" us
[ "$(DISPLAY='' sh "$kbd")" = jp ] || fail 'console: us → jp'
contains "$MOCK_KEYMAP" jp106
[ "$(sh "$ime")" = 'このあとに起動するアプリで日本語入力が使える' ] || fail 'ime-on の起動'
sh "$hook"
printf '%s\n' 'purge -y modemmanager' 'autoremove -y' > expected-apt
cmp expected-apt "$MOCK_APT_LOG"
check_clean cli
check_icewm
check_clean lxqt
printf '%s\n' 'ALL PASS: icewm の生成・動作、icewm → cli / lxqt の削除'
