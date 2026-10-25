#!/bin/sh
# Ubuntu 26.04 の Contents/パッケージ一覧は未確認。
# セッションの正確なファイル名は固定せず、インストール済みファイルを検出する。
set -eu
session=ubuntu
set -f
# Kernel arguments are words, not lines.
# shellcheck disable=SC2013
for word in $(cat /proc/cmdline); do
    case "$word" in bootkit.session=lubuntu) session=lubuntu ;; esac
done
set +f
find_session() {
    desktop=$1
    for file in /usr/share/xsessions/*.desktop /usr/share/wayland-sessions/*.desktop; do
        [ -f "$file" ] || continue
        case "$desktop:$(basename "$file")" in
            lubuntu:lubuntu.desktop|ubuntu:ubuntu.desktop) printf '%s\n' "$file"; return ;;
        esac
    done
    case "$desktop" in lubuntu) command_name='lxqt-session' ;; *) command_name='gnome-session' ;; esac
    for file in /usr/share/xsessions/*.desktop /usr/share/wayland-sessions/*.desktop; do
        [ -f "$file" ] || continue
        if grep -Eq "^Exec=.*${command_name}([ ;]|$)" "$file"; then printf '%s\n' "$file"; return; fi
    done
    echo "セッションが見つかりません: $desktop" >&2
    return 1
}
chosen=$(find_session "$session")
lxqt=$(find_session lubuntu)
user=$(cat /etc/bootkit-live-user)
getent passwd "$user" >/dev/null
# GDM remains the automatic DM; SDDM is the console's manual LXQt entry point.
# SDDM's config path/keys are conventional; 26.04 package contents are 未確認.
mkdir -p /etc/sddm.conf.d
printf '%s\n' '[Autologin]' "User=$user" "Session=$(basename "$lxqt")" 'Relogin=false' > /etc/sddm.conf.d/99-bootkit.conf
# GDM reads the selected user's saved session via AccountsService.
# These keys' effective behavior with Ubuntu 26.04 GDM is 未確認.
mkdir -p /var/lib/AccountsService/users
account=/var/lib/AccountsService/users/$user
[ -f "$account" ] || printf '%s\n' '[User]' > "$account"
awk -v session="$(basename "$chosen" .desktop)" '
    /^\[User\]$/ { section=1; seen=1; print; print "XSession=" session; print "Session=" session; next }
    /^\[/ { section=0 }
    section && /^(XSession|Session)=/ { next }
    { print }
    END { if (!seen) { print "[User]"; print "XSession=" session; print "Session=" session } }
' "$account" > "$account.bootkit-new"
chmod 600 "$account.bootkit-new"
mv "$account.bootkit-new" "$account"
printf 'bootkit: %s (%s)\n' "$session" "$chosen"
