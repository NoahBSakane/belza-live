#!/bin/sh
# Run from the copied bundle in a persistent Ubuntu Live session.
set -eu
[ "$(id -u)" = 0 ] || { echo 'sudo sh ubuntu-pack-setup.sh で実行してください' >&2; exit 1; }
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
marker=/var/lib/bootkit/ubuntu-pack-v1
if [ -f "$marker" ]; then
    echo '追加パックは導入済みです'
    exit 0
fi
# Prevent accidentally installing into a nonpersistent Live overlay.
[ "$(findmnt -rn -o FSTYPE /)" = overlay ] || {
    echo 'Live の overlay ルートでのみ実行してください' >&2; exit 1;
}
findmnt -rn -t ext4 -o LABEL,OPTIONS | awk '
    $1 == "casper-rw" && $2 ~ /(^|,)rw(,|$)/ { found=1 }
    END { exit !found }
' || { echo '書き込み可能な casper-rw persistence が見つかりません' >&2; exit 1; }
user=${SUDO_USER:-}
[ -n "$user" ] && [ "$user" != root ] || {
    echo 'Live ユーザーの端末から sudo sh で実行してください' >&2; exit 1;
}
getent passwd "$user" >/dev/null
getent hosts archive.ubuntu.com >/dev/null || { echo 'ネットワーク/DNS を確認してください' >&2; exit 1; }
[ -n "$(ip route show default)$(ip -6 route show default)" ] || {
    echo 'ネットワークの既定経路がありません' >&2; exit 1;
}
printf '%s\n' '1/4: APT 索引を更新します (失敗時は中止)' \
    '容量の概算: LXQt 約 1.9GB + Server 約 240MB。APT キャッシュ等は別途必要。4GiB は余裕が小さい構成です。'
apt-get update --error-on=any
# Block package postinst from starting SSH or switching the current desktop.
# Preserve any pre-existing policy; a rejected service start is intentionally 101.
policy=/usr/sbin/policy-rc.d
backup=/usr/sbin/policy-rc.d.bootkit-backup
[ ! -e "$backup" ] && [ ! -L "$backup" ] || { echo '以前の policy 退避が残っています' >&2; exit 1; }
had_policy=false
if [ -e "$policy" ] || [ -L "$policy" ]; then mv "$policy" "$backup"; had_policy=true; fi
restore_policy() {
    rm -f "$policy"
    if $had_policy; then mv "$backup" "$policy"; fi
}
trap restore_policy 0
trap 'exit 1' HUP INT TERM
printf '#!/bin/sh\nexit 101\n' > "$policy"
chmod 755 "$policy"
echo '2/4: LXQt・Server 機能をインストールします'
DEBIAN_FRONTEND=noninteractive apt-get install -y lubuntu-desktop ubuntu-server openssh-server
systemctl disable --now ssh.service ssh.socket
echo '3/4: 起動時のセッション選択を導入します'
printf '%s\n' 'gdm3 shared/default-x-display-manager select gdm3' | debconf-set-selections
DEBIAN_FRONTEND=noninteractive dpkg-reconfigure gdm3
# Use a single DM for automatic startup; session selection changes each boot.
systemctl disable sddm.service
systemctl enable --force gdm3.service
install -m 755 "$HERE/bootkit-session.sh" /usr/local/sbin/bootkit-session
install -m 644 "$HERE/bootkit-session.service" /etc/systemd/system/bootkit-session.service
install -m 644 "$HERE/bootkit-motd.sh" /etc/profile.d/bootkit-motd.sh
printf '%s\n' "$user" > /etc/bootkit-live-user
systemctl daemon-reload
systemctl enable bootkit-session.service
/usr/local/sbin/bootkit-session
mkdir -p /var/lib/bootkit
touch "$marker"
echo '4/4: 完了。SSH は無効です。次回の起動メニューで GUI を選べます。'
