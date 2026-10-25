# auto/config が set -e と限定リストの引数を先頭に付ける hook 本体。
# shellcheck shell=sh
set -e
[ "$#" -gt 0 ] || { echo 'forky package list is empty' >&2; exit 1; }
source_file=/etc/apt/sources.list.d/forky.list
pin_file=/etc/apt/preferences.d/forky.pref
cleanup() {
    status=$?
    trap - 0 HUP INT TERM
    # 一つ失敗しても残りの後始末を試し、失敗を成功に変えない。
    if rm -f "$source_file" "$pin_file"; then :; else status=1; fi
    if rm -f /var/lib/apt/lists/*_dists_forky_* /var/lib/apt/lists/partial/*_dists_forky_*; then :; else status=1; fi
    if apt-get update -o APT::Get::List-Cleanup=true; then :; else status=1; fi
    if apt-get clean; then :; else status=1; fi
    exit "$status"
}
trap cleanup 0
trap 'exit 1' HUP INT TERM
# 基盤の導入前後を比較する。-t の対象リリース指定による波及も検出する。
protected='libc6 libc-bin libsystemd0 libudev1 systemd udev apt dpkg'
# shellcheck disable=SC2086
before=$(dpkg-query -W -f='${binary:Package} ${Version}\n' $protected)
mkdir -p /etc/apt/sources.list.d /etc/apt/preferences.d
printf '%s\n' 'deb http://deb.debian.org/debian forky main' > "$source_file"
{
    printf '%s\n' 'Package: *' 'Pin: release n=forky' 'Pin-Priority: 100' ''
    for package do
        printf 'Package: %s\nPin: release n=forky\nPin-Priority: 990\n\n' "$package"
    done
} > "$pin_file"
apt-get update
apt-get install -y -t forky "$@"
for package do
    installed=$(dpkg-query -W -f='${Version}' "$package")
    policy=$(apt-cache policy "$package")
    # policy の版見出しと、その版の取得元を対応付ける。
    if ! printf '%s\n' "$policy" | awk -v installed="$installed" '
        $1 == "***" { version = $2; next }
        NF == 2 && $2 ~ /^[0-9]+$/ { version = $1; next }
        version == installed && /[[:space:]]forky\// { found = 1 }
        END { exit !found }
    '; then
        echo "forky version was not installed: $package ($installed)" >&2
        exit 1
    fi
done
# shellcheck disable=SC2086
after=$(dpkg-query -W -f='${binary:Package} ${Version}\n' $protected)
if [ "$before" != "$after" ]; then
    printf 'Protected package versions changed:\nbefore:\n%s\nafter:\n%s\n' "$before" "$after" >&2
    exit 1
fi
