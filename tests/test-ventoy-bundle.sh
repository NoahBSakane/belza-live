#!/bin/sh
# Offline checks only, unless --check-packages --download is explicitly selected.
set -eu
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
BUNDLE=${VENTOY_BUNDLE:-$HERE/ventoy}
case "${1:-}" in
    --check-packages) shift; exec python3 -I "$BUNDLE/check-package-index.py" "$@" ;;
    ''|--checks|--mutation-check) ;;
    *) echo '使い方: test-ventoy-bundle.sh [--mutation-check | --check-packages [--download | --indexes DIR]]' >&2; exit 2 ;;
esac
WORK=$(mktemp -d "$HERE/ventoy/.test-bundle.XXXXXX")
trap 'rm -r -- "$WORK"' 0
trap 'exit 1' HUP INT TERM
export BUNDLE WORK
find "$BUNDLE" -name '*.sh' -type f ! -path '*/.test-bundle.*/*' -print | while IFS= read -r script; do
    sh -n "$script"
    if command -v shellcheck >/dev/null 2>&1; then shellcheck -s sh "$script"; fi
done
sh -n "$0"
if command -v shellcheck >/dev/null 2>&1; then shellcheck -s sh "$0"; fi
python3 -I - <<'PY'
import importlib.util
import json
import lzma
import os
from pathlib import Path
import re
import subprocess
import sys

bundle = Path(os.environ['BUNDLE'])
work = Path(os.environ['WORK'])
def require(condition, message):
    if not condition:
        raise AssertionError(message)

grub = (bundle / 'ubuntu/grub.cfg').read_text()
require(len(grub.encode()) <= 2 * 1024 * 1024, 'conf_replace の 2 MiB 制限を超えた')
require(re.search(r'^set default=0$', grub, re.M), 'Server が既定でない')
require(re.search(r'^set timeout=30$', grub, re.M), 'timeout が違う')
entries = re.findall(r'menuentry "([^"]+)" \{([^}]+)\}', grub)
require([title for title, _ in entries] == [
    'Server only (text mode)', 'Lubuntu (LXQt, needs the pack)', 'Ubuntu (GNOME)',
    'Ubuntu (safe graphics)', 'Ubuntu (copy to RAM)',
    'Boot from next volume', 'UEFI Firmware Settings'], 'GRUB 項目/順序が違う')
for index, (_, body) in enumerate(entries[:5]):
    require('initrd /casper/initrd' in body, 'initrd がない')
    require(('systemd.unit=multi-user.target' in body) == (index == 0), '文字画面指定が別項目にある')
    require(('bootkit.session=server' in body) == (index == 0), 'server 指定が違う')
    require(('bootkit.session=lubuntu' in body) == (index == 1), 'lubuntu 指定が違う')
require('linux /casper/vmlinuz --- quiet splash' in entries[2][1], '通常 Ubuntu が変わった')
require('nomodeset --- quiet splash' in entries[3][1], 'safe graphics が変わった')
require('toram --- quiet splash' in entries[4][1], 'toram がない')
require(re.search(r'if \[ "\$grub_platform" = "efi" \]; then\s+menuentry "Boot from next volume"', grub), 'UEFI 条件がない')
for fragment in ['loadfont unicode', 'set menu_color_normal=white/black',
                 'set menu_color_highlight=black/light-gray', 'set gfxpayload=keep', 'exit 1', 'fwsetup']:
    require(fragment in grub, f'GRUB の機能が欠落: {fragment}')

has_yaml = importlib.util.find_spec('yaml') is not None
if has_yaml:
    import yaml
expected_packages = {
    'ubuntu-plus-server': ['ubuntu-server', 'openssh-server'],
    'lubuntu-plus-server': ['lubuntu-desktop', 'ubuntu-server', 'openssh-server'],
    'server-only': ['ubuntu-server', 'openssh-server', 'linux-generic'],
}
for name, packages in expected_packages.items():
    text = (bundle / f'script/{name}.yaml').read_text()
    require(text.startswith('#cloud-config\n'), 'cloud-config 宣言がない')
    require(re.search(r'^autoinstall:$', text, re.M), '行頭の autoinstall がない')
    require(re.search(r'^  version: 1$', text, re.M), 'version がない')
    require(re.search(r'^  interactive-sections: \[storage, identity\]$', text, re.M), 'storage 対話指定がない')
    require(not re.search(r'^  (storage|identity):', text, re.M), '固定の消去/ユーザー設定がある')
    if has_yaml:
        config = yaml.safe_load(text)['autoinstall']
        require(config['version'] == 1, 'version が違う')
        require(config['source'] == {'id': 'ubuntu-desktop-minimal'}, 'source が違う')
        require(config['interactive-sections'] == ['storage', 'identity'], '対話指定が違う')
        require(config['packages'] == packages, 'packages が違う')
        require(config['ssh'] == {'install-server': False}, 'SSH が有効')
        require(config['locale'] == 'en_US.UTF-8' and config['keyboard'] == {'layout': 'jp'}
                and config['timezone'] == 'Asia/Tokyo', '地域設定が違う')
        for command in config['late-commands']:
            subprocess.run(['sh', '-n', '-c', command], check=True)
    require('systemctl disable ssh.service ssh.socket' in text, 'SSH の無効化がない')
    # Also parse block command syntax in the no-PyYAML fallback.
    lines = text.splitlines()
    for index, line in enumerate(lines):
        if line != '    - |':
            continue
        block = []
        for following in lines[index + 1:]:
            if following and not following.startswith('      '):
                break
            block.append(following[6:])
        subprocess.run(['sh', '-n', '-c', '\n'.join(block)], check=True)
print('PASS: GRUB / YAML' + ('' if has_yaml else ' (PyYAML なし: 宣言・対話指定の静的検査)'))

iso = '/ISO/live/ubuntu-26.04.1-desktop-amd64.iso'
merge = bundle / 'merge-ventoy-json.py'
def run_merge(source, output, *args, success=True):
    result = subprocess.run([sys.executable, '-I', str(merge), str(source), str(output), *args],
                            text=True, capture_output=True)
    require((result.returncode == 0) == success, f'merge の終了値: {result.stderr}')
    return result
source, out, second = [work / name for name in ('existing.json', 'out.json', 'second.json')]
control = [{'VTOY_DEFAULT_SEARCH_ROOT': '/ISO'}]
source.write_text(json.dumps({'control': control, 'theme': {'file': '/my/theme.txt'}}))
run_merge(source, out)
data = json.loads(out.read_text())
require(data['control'] == control and data['theme'] == {'file': '/my/theme.txt'}, '既存設定が変わった')
for key in ('persistence', 'conf_replace', 'auto_install', 'menu_alias'):
    require(len(data[key]) == 1, f'{key} が一意でない')
require(data['persistence'][0] == {'image': iso, 'backend': '/ISO/persistence/ubuntu-26.04.1-amd64.dat'}, 'backend が違う')
require(data['conf_replace'][0] == {'iso': iso, 'org': '/boot/grub/grub.cfg', 'new': '/ventoy/ubuntu/grub.cfg'}, 'conf_replace が違う')
require(data['auto_install'][0] == {'image': iso, 'autosel': 0, 'timeout': 15,
        'template': [f'/ventoy/script/{name}.yaml' for name in expected_packages]}, 'template が違う')
require(data['menu_alias'][0] == {'image': iso, 'alias': 'Ubuntu 26.04.1 LTS (Server / Lubuntu / Ubuntu)'}, 'alias が違う')
run_merge(out, second)
require(out.read_bytes() == second.read_bytes(), 'merge が非冪等')
require(run_merge(source, work / 'unused', '--dry-run').stdout == out.read_text(), 'dry-run が違う')
require(not (work / 'unused').exists(), 'dry-run が書き込んだ')
original = source.read_bytes()
run_merge(source, source, success=False)
require(source.read_bytes() == original, '拒否時に書き込んだ')
link = work / 'alias.json'
link.symlink_to(source)
run_merge(source, link, success=False)
run_merge(source, source, '--in-place')
require(source.read_bytes() == out.read_bytes(), 'in-place 結果が違う')
for key in ('persistence', 'conf_replace', 'auto_install', 'menu_alias'):
    match_key = 'iso' if key == 'conf_replace' else 'image'
    data[key] = [{match_key: '/other.iso', 'keep': True}, {match_key: iso, 'stale': True}, {match_key: iso}]
source.write_text(json.dumps(data))
run_merge(source, second)
replaced = json.loads(second.read_text())
for key in ('persistence', 'conf_replace', 'auto_install', 'menu_alias'):
    require(len(replaced[key]) == 2 and replaced[key][0]['keep'], f'{key} の他項目が消えた/重複が残った')
    require(replaced[key][1] == json.loads(out.read_text())[key][0], f'{key} が置き換わらない')
print('PASS: JSON 保持・冪等・置換・同一パス拒否')

# Run the session selector against a fake root, without changing the real host.
root = work / 'root'
for directory in ['usr/share/xsessions', 'usr/share/wayland-sessions', 'etc',
                  'var/lib/AccountsService/users', 'proc', 'bin']:
    (root / directory).mkdir(parents=True, exist_ok=True)
(root / 'etc/bootkit-live-user').write_text('test-live-user\n')
(root / 'usr/share/xsessions/lubuntu.desktop').write_text('[Desktop Entry]\nExec=lxqt-session\n')
(root / 'usr/share/wayland-sessions/ubuntu.desktop').write_text('[Desktop Entry]\nExec=gnome-session --session=ubuntu\n')
(root / 'bin/getent').write_text('#!/bin/sh\nexit 0\n')
(root / 'bin/getent').chmod(0o755)
selector = (bundle / 'ubuntu/bootkit-session.sh').read_text()
# The script text is edited by string replacement, so point it at a symlink whose path has no spaces.
import tempfile
root_link_dir = Path(tempfile.mkdtemp(prefix='bootkit-root.',
                                           dir=os.environ.get('BOOTKIT_TEST_LINK_TMPDIR', '/tmp')))
root_link = root_link_dir / 'r'
root_link.symlink_to(root)
for prefix in ['/etc/', '/var/lib/', '/proc/', '/usr/share/']:
    selector = selector.replace(prefix, str(root_link) + prefix)
runner = work / 'session.sh'
runner.write_text(selector)
env = dict(os.environ, PATH=str(root / 'bin') + os.pathsep + os.environ['PATH'])
account = root / 'var/lib/AccountsService/users/test-live-user'
account.write_text('[User]\nLanguage=en_US.UTF-8\nXSession=stale\n[Other]\nSession=preserve\n')
for argument, expected in [('bootkit.session=lubuntu', 'lubuntu'),
                           ('bootkit.session=server', 'ubuntu'),
                           ('bootkit.session=lubuntux', 'ubuntu'), ('', 'ubuntu')]:
    (root / 'proc/cmdline').write_text('quiet ' + argument + '\n')
    subprocess.run(['sh', str(runner)], env=env, check=True, capture_output=True)
    require('XSession=' + expected + '\n' in account.read_text(), 'セッション選択が違う')
    require('Language=en_US.UTF-8' in account.read_text() and '[Other]\nSession=preserve' in account.read_text(), '既存アカウント設定が消えた')
    require('Session=lubuntu.desktop' in (root / 'etc/sddm.conf.d/99-bootkit.conf').read_text(), '手動 SDDM が LXQt でない')
(root / 'usr/share/wayland-sessions/ubuntu.desktop').unlink()
result = subprocess.run(['sh', str(runner)], env=env, capture_output=True)
require(result.returncode != 0, 'セッション欠落を見逃した')
root_link.unlink()
root_link_dir.rmdir()
print('PASS: セッション切替・既存設定保持・欠落時エラー (偽 root)')

result = subprocess.run(['sh', str(bundle / 'make-persistence.sh'), '/Volumes/BOOTKIT-NOT-A-REAL-DISK/no.dat'], capture_output=True)
require(result.returncode == 1 and b'/Volumes/' in result.stderr, '外付けパスを拒否しない')
# Check executable lines, including quoted commands embedded in heredocs.
for script in bundle.rglob('*.sh'):
    if any(part.startswith('.test-bundle.') for part in script.parts):
        continue
    for line in script.read_text().splitlines():
        if line.lstrip().startswith('#'):
            continue
        require(not re.search(r'\bmount\s|\bdd\b.*\bof\s*=\s*/dev/', line), f'危険なコマンド: {script}: {line}')
        if re.search(r'\b(?:mkfs(?:\.\w+)?|mke2fs)\b', line):
            require(script.name == 'make-persistence.sh', f'別スクリプトで format: {script}')
            if line.strip().startswith(('mkfs', 'mke2fs')):
                require(line.strip() == 'mkfs.ext4 -F -L casper-rw "$output"', f'危険な format の呼び出し: {line}')
    if script.name == 'make-persistence.sh':
        text = script.read_text()
        require('mkfs.ext4 -F -L casper-rw "$output"' in text, 'ext4 の出力先が違う')
        require('"$formatter" -t ext4 -F -L casper-rw -b 1024 "$output"' in text, 'mke2fs の出力先が違う')
        require('(set -C; : > "$output")' in text and '[ ! -L "$output" ]' in text, '通常ファイル限定がない')
print('PASS: 外付け拒否・危険コマンド検査')

# Stub formatters: verify argument boundaries and exclusive output creation,
# without making an ext4 filesystem or touching a real device.
bin_dir = work / 'format-bin'
bin_dir.mkdir()
for name, script in {
    'uname': '#!/bin/sh\necho Linux\n',
    'truncate': '#!/bin/sh\n[ "$1" = -s ] && [ "$2" = 32M ] && [ -f "$3" ]\n',
    'mkfs.ext4': '#!/bin/sh\n[ "$1" = -F ] && [ "$2" = -L ] && [ "$3" = casper-rw ] && [ -f "$4" ] || exit 1\nprintf "%s" "$4" > "$FORMAT_LOG"\n',
}.items():
    path = bin_dir / name
    path.write_text(script)
    path.chmod(0o755)
format_log = work / 'format.log'
env = dict(os.environ, PATH=str(bin_dir) + os.pathsep + os.environ['PATH'], FORMAT_LOG=str(format_log))
image = work / 'test image.dat'
command = ['sh', str(bundle / 'make-persistence.sh'), str(image), '32']
subprocess.run(command, env=env, check=True, capture_output=True)
require(format_log.read_text() == str(image), '通常ファイル以外に format した')
require(subprocess.run(command, env=env, capture_output=True).returncode != 0, '既存ファイルを上書きした')
image.unlink()
image.symlink_to(work / 'nonexistent-target')
require(subprocess.run(command, env=env, capture_output=True).returncode != 0, 'symlink を上書きした')
require(not (work / 'nonexistent-target').exists(), 'symlink の先に書いた')
(bin_dir / 'mkfs.ext4').write_text('#!/bin/sh\nexit 1\n')
image.unlink()
require(subprocess.run(command, env=env, capture_output=True).returncode != 0 and not image.exists(), '失敗した生成物が残った')
print('PASS: persistence の引数・既存/symlink 拒否・失敗時後始末 (偽 formatter)')

# The pack installer decides that the root is on Ventoy persistence without a separate ext4 mount:
# a casper-rw labelled device exists and the overlay root's size is close to that device's size.
pack_bin = work / 'pack-bin'
pack_bin.mkdir()
for name, script in {
    'id': '#!/bin/sh\n[ "$1" = -u ] && echo 0\n',
    'findmnt': '#!/bin/sh\ncase "$*" in *FSTYPE*) echo overlay ;; *OPTIONS*) echo rw,relatime ;; esac\n',
    'blkid': '#!/bin/sh\n[ "$1" = -L ] && [ "$2" = casper-rw ] && [ -n "${BLKID_DEV:-}" ] && echo "$BLKID_DEV"\n',
    'blockdev': '#!/bin/sh\n[ "$1" = --getsize64 ] && echo "$DEV_SIZE"\n',
    'df': '#!/bin/sh\nprintf "Size\\n%s\\n" "$DF_SIZE"\n',
}.items():
    path = pack_bin / name
    path.write_text(script)
    path.chmod(0o755)

def pack_run(df_size, blkid_dev='/dev/dm-1'):
    pack_env = dict(os.environ, PATH=str(pack_bin) + os.pathsep + os.environ['PATH'],
                    DEV_SIZE='4294967296', DF_SIZE=str(df_size), BLKID_DEV=blkid_dev)
    pack_env.pop('SUDO_USER', None)
    return subprocess.run(['sh', str(bundle / 'ubuntu/ubuntu-pack-setup.sh')], env=pack_env, capture_output=True, text=True)

refusal = '書き込み可能な casper-rw persistence が見つかりません'
passed = pack_run(4_000_000_000)
require(refusal not in passed.stderr and 'Live ユーザー' in passed.stderr, 'persistence 上のルートを拒否した')
require(refusal in pack_run(2_000_000_000).stderr, 'RAM 上のルートを persistence と誤認した')
require(refusal in pack_run(5_000_000_000).stderr, 'デバイスより大きいルートを許可した')
require(refusal in pack_run(4_000_000_000, blkid_dev='').stderr, 'casper-rw が無いのに許可した')
print('PASS: 追加パックの persistence 判定 (ラベル+容量。偽コマンド)')

# Validate the optional index checker against known complete/incomplete indexes.
checker = bundle / 'check-package-index.py'
result = subprocess.run([sys.executable, '-I', str(checker)], capture_output=True)
require(result.returncode == 77, '索引なしで 77 を返さない')
index_dir = work / 'indexes'
index_dir.mkdir()
names = {package for packages in expected_packages.values() for package in packages}
server = (bundle / 'script/server-only.yaml').read_text()
names.update(re.search(r'for package in (.+); do', server).group(1).split())
(index_dir / 'main.xz').write_bytes(lzma.compress(''.join('Package: ' + name + '\n\n' for name in sorted(names)).encode()))
(index_dir / 'universe.xz').write_bytes(lzma.compress(b''))
result = subprocess.run([sys.executable, '-I', str(checker), '--indexes', str(index_dir)], capture_output=True)
require(result.returncode == 0, '完全な偽索引を拒否した')
(index_dir / 'main.xz').write_bytes(lzma.compress(b'Package: ubuntu-server\n'))
result = subprocess.run([sys.executable, '-I', str(checker), '--indexes', str(index_dir)], capture_output=True)
require(result.returncode == 1 and b'openssh-server' in result.stderr, '不完全な索引を見逃した')
print('PASS: 索引なし 77・偽索引の完全/欠落の区別 (通信なし)')
PY
if [ "${1:-}" = --mutation-check ]; then
    # Each mutant is an isolated copy; the worktree source is never rewritten.
    for mutation in default interactive idempotence; do
        destination=$WORK/$mutation
        mkdir -p "$destination"
        cp -R "$BUNDLE/ubuntu" "$BUNDLE/script" "$destination/"
        cp "$BUNDLE/merge-ventoy-json.py" "$BUNDLE/check-package-index.py" "$BUNDLE/make-persistence.sh" "$destination/"
        python3 -I - "$destination" "$mutation" <<'PY'
from pathlib import Path
import sys
root, mutation = Path(sys.argv[1]), sys.argv[2]
if mutation == 'default':
    file = root / 'ubuntu/grub.cfg'
    old, new = 'set default=0', 'set default=2'
elif mutation == 'interactive':
    file = root / 'script/server-only.yaml'
    old, new = '  interactive-sections: [storage, identity]\n', ''
else:
    file = root / 'merge-ventoy-json.py'
    old, new = 'data[key] = [item for item in old if item.get(match_key) != ISO] + [entry]', 'data[key] = old + [entry]'
text = file.read_text()
assert old in text
file.write_text(text.replace(old, new))
PY
        if VENTOY_BUNDLE=$destination sh "$0" --checks > "$WORK/$mutation.log" 2>&1; then
            echo "FAIL: 壊した版を検出できません: $mutation" >&2; exit 1
        fi
        # Confirm it failed at the intended assertion, not a missing prerequisite.
        case "$mutation" in
            default) expected='Server が既定でない' ;;
            interactive) expected='storage 対話指定がない' ;;
            idempotence) expected='merge が非冪等' ;;
        esac
        grep -F "$expected" "$WORK/$mutation.log" >/dev/null
        printf 'PASS: 壊した版を検出 (%s: %s)\n' "$mutation" "$expected"
    done
fi
printf '%s\n' 'ALL PASS: Ventoy bundle (実機の起動は未検証)'
