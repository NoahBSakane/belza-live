#!/bin/sh
# 外部コマンドをスタブにして、フレーバーの生成・切り替えと補助コマンドを検査する。
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
ssh_hook=config/hooks/live/0300-ssh-off.hook.chroot
ssh_on=config/includes.chroot/usr/local/bin/ssh-on
keys_hook=config/hooks/live/0200-icewm-keys.hook.chroot
kbd=config/includes.chroot/usr/local/bin/kbd-toggle
ime=config/includes.chroot/usr/local/bin/ime-on
keys=config/includes.chroot/etc/skel/.icewm/keys
packages=config/package-lists/icewm.list.chroot
check_icewm() {
    run_config icewm
    check_common
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
    check_common
    for file in "$keys_hook" "$kbd" "$ime" "$keys" "$packages"; do
        [ ! -e "$file" ] || fail "$1 への切り替え後に $file が残った"
    done
    [ ! -e config/includes.chroot/etc/skel ] || fail "$1 に icewm の設定が残った"
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
# SSH の起動は本物のサービスやパスワードに触れずに検査する。
cat > bin/id <<'STUB'
#!/bin/sh
[ "$*" = -u ] || exit 1
printf '%s\n' "$MOCK_UID"
STUB
cat > bin/passwd <<'STUB'
#!/bin/sh
printf 'passwd%s\n' "${*:+ $*}" >> "$MOCK_SSH_LOG"
exit "$MOCK_PASSWD_STATUS"
STUB
cat > bin/sudo <<'STUB'
#!/bin/sh
printf 'sudo %s\n' "$*" >> "$MOCK_SSH_LOG"
exec "$@"
STUB
cat > bin/systemctl <<'STUB'
#!/bin/sh
printf 'systemctl %s\n' "$*" >> "$MOCK_SSH_LOG"
if [ "$*" = 'cat ssh.socket' ]; then
    exit "$MOCK_SOCKET_STATUS"
fi
exit "$MOCK_SYSTEMCTL_STATUS"
STUB
cat > bin/ip <<'STUB'
#!/bin/sh
printf 'ip %s\n' "$*" >> "$MOCK_SSH_LOG"
printf '%s\n' 'eth0 UP 192.0.2.1/24'
STUB
chmod +x bin/id bin/passwd bin/sudo bin/systemctl bin/ip
MOCK_SSH_LOG=$WORK/ssh.log
MOCK_UID=1000 MOCK_PASSWD_STATUS=0 MOCK_SOCKET_STATUS=0 MOCK_SYSTEMCTL_STATUS=0
export MOCK_SSH_LOG MOCK_UID MOCK_PASSWD_STATUS MOCK_SOCKET_STATUS MOCK_SYSTEMCTL_STATUS
check_forky() {
    contains config/archives/forky.list.chroot 'deb http://deb.debian.org/debian forky main'
    python3 - <<'PYTHON'
from pathlib import Path
allowed = set(Path('config/forky-packages.txt').read_text().split())
assert {'clonezilla', 'drbl', 'partclone'} <= allowed
assert not allowed & {'libc6', 'libc-bin', 'libsystemd0', 'libudev1', 'systemd', 'udev', 'apt', 'dpkg'}
records = []
for block in Path('config/archives/forky.pref.chroot').read_text().strip().split('\n\n'):
    record = dict(line.split(': ', 1) for line in block.splitlines())
    assert set(record) == {'Package', 'Pin', 'Pin-Priority'}
    assert record['Pin'] == 'release n=forky'
    records.append(record)
assert len(records) == len(allowed) + 1
assert {r['Package'] for r in records} == allowed | {'*'}
for record in records:
    assert record['Pin-Priority'] == ('100' if record['Package'] == '*' else '990')
# trixie の既定 500 と比較。基盤は forky を候補にしない。
for name in ('libc6', 'systemd', 'udev', 'apt', 'dpkg'):
    priority = max(int(r['Pin-Priority']) for r in records if r['Package'] in ('*', name))
    assert priority < 500, (name, priority)
PYTHON
}
check_common() {
    check_forky
    for file in "$hook" "$ssh_hook" "$ssh_on"; do
        [ -x "$file" ] || fail "$file が実行可能でない"
        sh -n "$file"
    done
    if command -v shellcheck >/dev/null 2>&1; then
        shellcheck -s sh "$hook" "$ssh_hook" "$ssh_on"
    fi
    contains "$hook" 'apt-get purge -y modemmanager || :'
    contains "$hook" 'apt-get autoremove -y || :'
    # socket の有無と disable 失敗の許容を別々に確認する。
    for MOCK_SOCKET_STATUS in 0 1; do
        for MOCK_SYSTEMCTL_STATUS in 0 1; do
            : > "$MOCK_SSH_LOG"
            sh "$ssh_hook"
            printf '%s\n' 'systemctl disable ssh.service' 'systemctl cat ssh.socket' > expected-ssh
            if [ "$MOCK_SOCKET_STATUS" = 0 ]; then
                printf '%s\n' 'systemctl disable ssh.socket' >> expected-ssh
            fi
            cmp expected-ssh "$MOCK_SSH_LOG"
        done
    done
    MOCK_SYSTEMCTL_STATUS=0
    for MOCK_UID in 1000 0; do
        if [ "$MOCK_UID" = 0 ]; then
            passwd_command='passwd user'
        else
            passwd_command=passwd
        fi
        for MOCK_PASSWD_STATUS in 0 1; do
            : > "$MOCK_SSH_LOG"
            # 案内も同じログで比較し、passwd より先に表示することを確かめる。
            if sh "$ssh_on" >> "$MOCK_SSH_LOG"; then
                [ "$MOCK_PASSWD_STATUS" = 0 ] || fail 'passwd 失敗でも ssh-on が成功した'
            else
                [ "$MOCK_PASSWD_STATUS" != 0 ] || fail 'ssh-on の起動が失敗した'
            fi
            printf '%s\n' \
                'SSH を起動する。LAN から、user でログインできるようになる。先にパスワードを変更する' \
                "$passwd_command" > expected-ssh
            if [ "$MOCK_PASSWD_STATUS" = 0 ]; then
                printf '%s\n' 'sudo systemctl start ssh' 'systemctl start ssh' \
                    'ip -brief address' 'eth0 UP 192.0.2.1/24' >> expected-ssh
            fi
            cmp expected-ssh "$MOCK_SSH_LOG"
        done
    done
    MOCK_PASSWD_STATUS=0
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
# 全アーキテクチャ・全フレーバーで共通のアーカイブと pin を維持する。
for arch in amd64 arm64; do
    for flavor in cli lxqt icewm; do
        ARCH=$arch run_config "$flavor"
        check_forky
    done
done
printf '%s\n' 'ALL PASS: 全フレーバーの共通 hook・SSH、icewm の生成・動作、icewm → cli / lxqt の削除'
