#!/bin/bash
# 実際の QEMU は起動せず、dry-run の引数・入力検査・配列を確認する。
set -eu
HERE="$(cd "$(dirname "$0")/.." && pwd)"
export QEMU_BOOT_SCRIPT="${QEMU_BOOT_SCRIPT:-$HERE/tests/qemu-boot.py}"
exec python3 -I - <<'PY'
import os
from pathlib import Path
import runpy
import shlex
import subprocess
import sys
import tempfile

script = Path(os.environ['QEMU_BOOT_SCRIPT'])
count = 0


def check(condition, label):
    global count
    if not condition:
        raise AssertionError(label)
    count += 1
    print('ok  ', label)


with tempfile.TemporaryDirectory(prefix='qb-args-') as temp:
    root = Path(temp)
    firmware = root / 'share/qemu'
    firmware.mkdir(parents=True)
    for name in ('x86_64-code', 'i386-vars', 'aarch64-code', 'arm-vars'):
        (firmware / f'edk2-{name}.fd').write_bytes(b'fixture')
    bindir = root / 'bin'
    bindir.mkdir()
    brew = bindir / 'brew'
    brew.write_text('#!/bin/sh\nprintf "%s\\n" "$QB_TEST_BREW_PREFIX"\n')
    brew.chmod(0o755)
    marker = root / 'qemu-was-started'
    for name in ('x86_64', 'aarch64'):
        binary = bindir / f'qemu-system-{name}'
        binary.write_text('#!/bin/sh\ntouch "$QB_TEST_QEMU_MARKER"\nexit 99\n')
        binary.chmod(0o755)
    env = dict(os.environ, PATH=f'{bindir}:{os.environ["PATH"]}',
               QB_TEST_BREW_PREFIX=str(root), QB_TEST_QEMU_MARKER=str(marker))
    iso = root / 'dummy with space,comma.iso'
    iso.write_bytes(b'fixture')
    prefix = root / ('long-prefix-' * 12) / 'run'
    base = [sys.executable, '-I', str(script), '--iso', str(iso),
            '--prefix', str(prefix), '--dry-run']

    def invoke(*extra):
        return subprocess.run(base + list(extra), text=True, capture_output=True, env=env)

    def command(*extra):
        result = invoke(*extra)
        check(result.returncode == 0, f'dry-run 成功: {extra}')
        return shlex.split(result.stdout)

    def values(cmd, option):
        return [cmd[i + 1] for i, arg in enumerate(cmd[:-1]) if arg == option]

    bios = command()
    check(bios[0] == 'qemu-system-x86_64', 'amd64 の実行ファイル')
    check(values(bios, '-machine') == ['pc'], 'amd64 machine pc')
    check(values(bios, '-accel') == ['tcg,thread=multi'], 'TCG のマルチスレッド')
    check(values(bios, '-cpu') == ['Westmere,-aes'], 'amd64 CPU')
    check(values(bios, '-m') == ['2048'] and values(bios, '-smp') == ['2'], '既定リソース')
    drives = values(bios, '-drive')
    check(len(drives) == 1 and 'if=ide' in drives[0] and 'readonly=on' in drives[0]
          and str(iso).replace(',', ',,') in drives[0], 'ISO の空白・カンマと読み取り専用 IDE')
    check('-bios' not in bios and not any('pflash' in d for d in drives), 'SeaBIOS は既定')
    monitor = values(bios, '-monitor')[0].split(',')[0].removeprefix('unix:')
    check(monitor.startswith('/tmp/qb-') and len(monitor.encode()) < 104
          and str(prefix) not in monitor, '長い prefix でも短いソケット')
    check(values(bios, '-display') == ['none'] and values(bios, '-net') == ['none'], '画面・ネット設定')

    uefi = command('--firmware', 'uefi', '--mem', '512', '--smp', '1')
    drives = values(uefi, '-drive')
    check(any('edk2-x86_64-code.fd' in d and 'readonly=on' in d and 'if=pflash' in d
              for d in drives), 'amd64 UEFI コードは読み取り専用 pflash')
    check(any('if=pflash' in d and 'vars.fd' in d and 'readonly=on' not in d
              and str(firmware) not in d for d in drives), '可変領域は原本と別のパス')
    check(values(uefi, '-m') == ['512'] and values(uefi, '-smp') == ['1'], 'リソース指定')

    arm = command('--arch', 'arm64', '--firmware', 'uefi', '--kbd', 'jp')
    check(arm[0] == 'qemu-system-aarch64' and values(arm, '-machine') == ['virt']
          and values(arm, '-cpu') == ['max'], 'arm64 machine と CPU')
    check('-bios' not in arm and any('edk2-aarch64-code.fd' in d and 'if=pflash' in d
                                    and 'readonly=on' in d for d in values(arm, '-drive')),
          'arm64 UEFI も pflash')
    check(set(('virtio-gpu-pci', 'qemu-xhci', 'usb-kbd', 'usb-mouse',
               'virtio-scsi-pci', 'scsi-cd,drive=cdrom')) <= set(values(arm, '-device')),
          'arm64 画面・USB・SCSI CD')
    check(any('if=none,id=cdrom' in d and 'readonly=on' in d
              for d in values(arm, '-drive')), 'arm64 CD のドライブ接続')
    (firmware / 'edk2-i386-vars.fd').unlink()
    no_vars = command('--firmware', 'uefi')
    check(sum('if=pflash' in d for d in values(no_vars, '-drive')) == 1,
          '任意の vars テンプレートが無い場合')
    for extra in (('--arch', 'arm64'), ('--mem', '0'), ('--smp', '-1'),
                  ('--timeout', 'nan'), ('--timeout', '-1'), ('--iso', str(root / 'missing'))):
        check(invoke(*extra).returncode != 0, f'不正入力を拒否: {extra}')
    check(not marker.exists() and not prefix.parent.exists(), 'dry-run は QEMU・出力を作らない')

module = runpy.run_path(str(script))
keys = module['text_keys']
check(keys('|=^_@[]:', 'jp') == ['shift-yen', 'shift-minus', 'equal', 'shift-ro',
                                'bracket_left', 'bracket_right', 'backslash', 'apostrophe'],
      'JIS 配列の記号')
check(keys('|=^', 'us') == ['shift-backslash', 'equal', 'shift-6'], 'US 配列の記号')
check(keys('Az 09', 'us') == ['shift-a', 'z', 'spc', '0', '9'], '英数字・大文字・空白')
try:
    keys('日本語', 'jp')
except ValueError:
    check(True, '直接入力できない文字を拒否')
else:
    check(False, '直接入力できない文字を拒否')
print(f'ALL PASS ({count})')
PY
