#!/bin/sh
# Run from the copied bundle in a persistent Ubuntu Live session.
set -eu
[ "$(id -u)" = 0 ] || { echo 'sudo sh ubuntu-modoki-setup.sh で実行してください' >&2; exit 1; }
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
marker=/var/lib/bootkit/ubuntu-pack-v1
if [ -f "$marker" ]; then
    echo '追加パック(Lubuntu-modoki / Ubuntu Server-modoki)は導入済みです'
    exit 0
fi
# Prevent accidentally installing into a nonpersistent Live overlay.
[ "$(findmnt -rn -o FSTYPE /)" = overlay ] || {
    echo 'Live の overlay ルートでのみ実行してください' >&2; exit 1;
}
# Ventoy の persistence は ext4 の単独のマウントとして見えず、`persistent` もコマンドラインに出ない。
# 代わりに、casper-rw ラベルのデバイスが存在し、ルート(overlay)の容量がそのデバイスの容量に近い
# (RAM 上の tmpfs ではない)ことで、persistence 上のルートだと判定する。
persist_dev=$(blkid -L casper-rw 2>/dev/null || true)
if [ -z "$persist_dev" ]; then
    echo '書き込み可能な casper-rw persistence が見つかりません' >&2
    exit 1
fi
root_opts=$(findmnt -rn -o OPTIONS /)
case ",$root_opts," in *,rw,*) ;; *) echo '書き込み可能な casper-rw persistence が見つかりません' >&2; exit 1 ;; esac
root_size=$(df -B1 --output=size / | tail -n 1 | tr -d ' ')
dev_size=$(blockdev --getsize64 "$persist_dev")
# ext4 の使用可能容量はデバイスの 85〜100% になる。RAM 上のルートとは通常一致しない。
if [ "$root_size" -lt $((dev_size * 85 / 100)) ] || [ "$root_size" -gt "$dev_size" ]; then
    echo '書き込み可能な casper-rw persistence が見つかりません' >&2
    exit 1
fi
user=${SUDO_USER:-}
if [ -z "$user" ] || [ "$user" = root ]; then
    echo 'Live ユーザーの端末から sudo sh で実行してください' >&2
    exit 1
fi
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
if [ -e "$backup" ] || [ -L "$backup" ]; then
    echo '以前の policy 退避が残っています' >&2
    exit 1
fi
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
