#!/bin/sh
# 共通の道具・GUI 限定パッケージ・自動起動抑制を、コピーとスタブで検査する。
set -eu
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-$HERE}/test-diag-packages.XXXXXX")
trap 'rm -rf "$WORK"' 0
trap 'exit 1' HUP INT TERM
SOURCE=${DIAG_SOURCE_ROOT:-$HERE}
cp -R "$SOURCE/auto" "$SOURCE/config" "$WORK/"
mkdir -p "$WORK/bin"
printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/lb"
chmod +x "$WORK/bin/lb"
PATH=$WORK/bin:$PATH
export PATH
python3 - "$WORK" "$HERE/tests/test-diag-packages.sh" "${1:-}" <<'PYTHON'
from collections import Counter
from pathlib import Path
import os
import shutil
import subprocess
import sys

root, script, mode = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
required = '''f2fs-tools jfsutils wget lsof strace jq git smbclient vim
sg3-utils screen net-tools traceroute whois mtr-tiny rfkill wireless-tools
 iotop sysstat ipmitool kexec-tools openvpn wireguard-tools minicom picocom
sleuthkit ewf-tools 7zip xorriso squashfs-tools lftp borgbackup gnupg zerofree
vim-tiny'''.split()

def require(ok, message):
    if not ok:
        sys.exit('FAIL: ' + message)

def packages(path, arch):
    active = [True]
    names = []
    for line in path.read_text().splitlines():
        fields = line.split()
        if fields[:2] == ['#if', 'ARCHITECTURES']:
            active.append(active[-1] and arch in fields[2:])
        elif fields == ['#endif']:
            active.pop()
        elif active[-1]:
            names.extend(line.split('#', 1)[0].split())
    return names

for arch in ('amd64', 'arm64'):
    names = packages(root / 'config/package-lists/diag.list.chroot', arch)
    require(set(required) <= set(names), '共通パッケージが欠落')
    require(all(n == 1 for n in Counter(names).values()), '共通パッケージが重複')
print(f'PASS: 追加{len(required) - 1}パッケージ・vim-tiny の保持・各アーキテクチャの重複なし')

units = ['openvpn.service', 'sysstat.service', 'sysstat-collect.timer',
         'sysstat-summary.timer', 'sysstat-rotate.timer']
hook_name = 'config/hooks/live/0500-optional-services-off.hook.chroot'
# システムの systemctl を呼ばず、対象と失敗時の終了を実行して確かめる。
(root / 'bin/systemctl').write_text('''#!/bin/sh
printf '%s\\n' "$*" >> "$MOCK_SERVICE_LOG"
exit "${MOCK_SERVICE_STATUS:-0}"
''')
(root / 'bin/systemctl').chmod(0o755)
log = root / 'services.log'
env = dict(os.environ, MOCK_SERVICE_LOG=str(log))
for arch in ('amd64', 'arm64'):
    # GUI → CLI の切り替え後にも混入しないことを確認する。
    for flavor in ('lxqt', 'icewm', 'cli'):
        subprocess.run(['sh', 'auto/config'], cwd=root,
                       env=dict(env, ARCH=arch, FLAVOR=flavor), check=True)
        names = [name for path in (root / 'config/package-lists').glob('*.list.chroot')
                 for name in packages(path, arch)]
        require(names.count('gparted') == (0 if flavor == 'cli' else 1),
                'gparted のフレーバー分離が不正')
        hook = root / hook_name
        require(os.access(hook, os.X_OK), '共通サービス hook が実行不能')
        subprocess.run(['sh', '-n', str(hook)], check=True)
        log.write_text('')
        subprocess.run(['sh', str(hook)], env=env, check=True)
        require(log.read_text().splitlines() == ['disable ' + u for u in units],
                'サービス無効化の対象が不正')
# 無効化が失敗したのに成功としてビルドを続行することを防ぐ。
result = subprocess.run(['sh', str(root / hook_name)],
                        env=dict(env, MOCK_SERVICE_STATUS='1'))
require(result.returncode != 0, 'サービス無効化の失敗を見逃した')
if shutil.which('shellcheck'):
    subprocess.run(['shellcheck', '-s', 'sh', str(root / hook_name), script], check=True)
print('PASS: 全6構成の gparted 分離・共通 hook・無効化失敗時の終了')

if mode == '--mutation-check':
    mutations = {
        'missing': ('config/package-lists/diag.list.chroot', 'f2fs-tools\n', '',
                    '共通パッケージが欠落'),
        'duplicate': ('config/package-lists/diag.list.chroot', 'wget\n', 'wget\nwget\n',
                      '共通パッケージが重複'),
        'cli-gparted': ('auto/config', 'cli) ;;',
                        'cli) echo gparted > config/package-lists/cli.list.chroot ;;',
                        'gparted のフレーバー分離が不正'),
        'gui-missing': ('auto/config', 'calamares-settings-debian gparted >',
                        'calamares-settings-debian >', 'gparted のフレーバー分離が不正'),
        'hook-unit': (hook_name, 'openvpn.service', 'openvpn-typo.service',
                      'サービス無効化の対象が不正'),
        'hook-failure': (hook_name, 'systemctl disable "$unit"',
                         'systemctl disable "$unit" || :', 'サービス無効化の失敗を見逃した'),
    }
    for name, (file, old, new, expected) in mutations.items():
        mutant = root / name
        mutant.mkdir()
        for directory in ('auto', 'config'):
            shutil.copytree(root / directory, mutant / directory, symlinks=True)
        path = mutant / file
        text = path.read_text()
        require(old in text, '変異条件が元ファイルにない: ' + name)
        path.write_text(text.replace(old, new))
        result = subprocess.run(['sh', script], capture_output=True, text=True,
                                env=dict(os.environ, DIAG_SOURCE_ROOT=str(mutant)))
        require(result.returncode == 1 and expected in result.stderr,
                '壊した版が所定の理由で失敗しない: ' + name + result.stderr)
        print('PASS: 壊した版を検出 (' + name + ': ' + expected + ')')
print('ALL PASS: 診断パッケージ・GUI 分離・サービス自動起動抑制')
PYTHON
