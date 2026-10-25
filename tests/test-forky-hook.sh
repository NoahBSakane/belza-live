#!/bin/sh
# 生成 hook を偽 APT で実行する。ホストの /etc と dpkg には触れない。
set -eu
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
WORK=$(mktemp -d "$HERE/test-forky-hook.XXXXXX")
trap 'rm -rf "$WORK"' 0
trap 'exit 1' HUP INT TERM
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
cp -R "$HERE/auto" "$HERE/config" "$WORK/"
mkdir -p "$WORK/bin"
printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/lb"
chmod +x "$WORK/bin/lb"
PATH=$WORK/bin:$PATH
export PATH
cd "$WORK"
sh auto/config
sed -e "s|/etc/apt|$WORK/apt|g" -e "s|/var/lib/apt/lists|$WORK/lists|g" \
    config/hooks/live/0400-forky-clonezilla.hook.chroot > hook.sh
cat > bin/apt-get <<'STUB'
#!/bin/sh
set -eu
printf '%s\n' "$*" >> "$MOCK_ROOT/log"
case "$1" in
    update)
        if [ -e "$MOCK_ROOT/apt/sources.list.d/forky.list" ]; then
            grep -Fqx 'deb http://deb.debian.org/debian forky main' "$MOCK_ROOT/apt/sources.list.d/forky.list"
            cp "$MOCK_ROOT/apt/preferences.d/forky.pref" "$MOCK_ROOT/pins"
            touch "$MOCK_ROOT/lists/deb.debian.org_debian_dists_forky_main_binary-amd64_Packages"
            touch "$MOCK_ROOT/lists/partial/deb.debian.org_debian_dists_forky_InRelease"
            [ "$MOCK_CASE" != update-fail ] || exit 7
        else
            [ "$MOCK_CASE" != cleanup-fail ] || exit 8
        fi
        ;;
    install)
        [ "$MOCK_CASE" != install-fail ] || exit 9
        touch "$MOCK_ROOT/installed"
        ;;
    clean) touch "$MOCK_ROOT/cleaned" ;;
    *) exit 10 ;;
esac
STUB
cat > bin/dpkg-query <<'STUB'
#!/bin/sh
set -eu
case "$*" in
    *'${binary:Package}'*)
        version=1
        if [ "$MOCK_CASE" = base-changed ] && [ -e "$MOCK_ROOT/installed" ]; then version=2; fi
        printf 'libc6 %s\n' "$version"
        ;;
    *)
        if [ "$MOCK_CASE" = unchanged ]; then printf 1; else printf 2; fi
        ;;
esac
STUB
cat > bin/apt-cache <<'STUB'
#!/bin/sh
set -eu
[ "$MOCK_CASE" != policy-fail ] || exit 11
# 更新されないケースでも forky の候補は存在する。
printf '%s\n' "$2:" '  Installed: 2' '  Candidate: 2' '  Version table:' \
    '     2 990' '        990 http://deb.debian.org/debian forky/main amd64 Packages' \
    ' *** 1 500' '        500 http://deb.debian.org/debian trixie/main amd64 Packages' \
    '        100 /var/lib/dpkg/status'
STUB
chmod +x bin/apt-get bin/dpkg-query bin/apt-cache
MOCK_ROOT=$WORK
export MOCK_ROOT
for MOCK_CASE in success unchanged base-changed update-fail install-fail policy-fail cleanup-fail; do
    export MOCK_CASE
    rm -f installed cleaned log pins
    mkdir -p lists/partial
    if sh hook.sh > output.log 2>&1; then
        [ "$MOCK_CASE" = success ] || fail "$MOCK_CASE が成功した"
    else
        [ "$MOCK_CASE" != success ] || { cat output.log; fail '正常更新が失敗した'; }
    fi
    [ ! -e apt/sources.list.d/forky.list ] || fail "$MOCK_CASE: source が残った"
    [ ! -e apt/preferences.d/forky.pref ] || fail "$MOCK_CASE: pin が残った"
    [ -z "$(find lists -type f -print)" ] || fail "$MOCK_CASE: forky 索引が残った"
    [ -e cleaned ] || fail "$MOCK_CASE: clean が実行されなかった"
    tail -n 2 log > actual-cleanup
    printf '%s\n' 'update -o APT::Get::List-Cleanup=true' clean > expected-cleanup
    cmp expected-cleanup actual-cleanup
    python3 - "$HERE/config/forky-packages.txt" pins <<'PYTHON'
from pathlib import Path
import sys
allowed = {p for p in Path(sys.argv[1]).read_text().splitlines() if p and not p.startswith('#')}
records = [dict(line.split(': ', 1) for line in block.splitlines())
           for block in Path(sys.argv[2]).read_text().strip().split('\n\n')]
assert len(records) == len(allowed) + 1
assert {r['Package'] for r in records} == allowed | {'*'}
for r in records:
    assert r['Pin'] == 'release n=forky'
    assert r['Pin-Priority'] == ('100' if r['Package'] == '*' else '990')
PYTHON
    if [ "$MOCK_CASE" = unchanged ]; then grep -q 'forky version was not installed' output.log; fi
    if [ "$MOCK_CASE" = base-changed ]; then grep -q 'Protected package versions changed' output.log; fi
    printf 'PASS: %s (取得元・pin・索引を除去、clean 実行)\n' "$MOCK_CASE"
done
