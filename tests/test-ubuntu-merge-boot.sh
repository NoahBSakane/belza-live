#!/bin/sh
# ISO を作り直さず、cpio/GRUB の接続と >8GiB PVD の回帰を検証する。
set -eu
HERE=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
python3 -I - "$HERE" <<'PY'
import gzip
import importlib.util
import io
from pathlib import Path
import struct
import sys
root = Path(sys.argv[1])
def module(name, path):
    spec = importlib.util.spec_from_file_location(name, root / path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod
cpio = module('cpio', 'ventoy/ramsel/make-cpio.py')
reader = module('reader', 'ventoy/ramsel/rebuild-initrd.py')
blob = cpio.archive(root / 'ventoy/ramsel')
assert blob == cpio.archive(root / 'ventoy/ramsel')
files, _ = reader.entries(gzip.decompress(blob))
for name in ('ORDER', '30bootkit-ramsel'):
    assert files['scripts/casper-premount/' + name] == (root / 'ventoy/ramsel' / name).read_bytes()
assert len(files) == 4
cfg = module('grub', 'tools/ubuntu-merge/grub.py').config()
assert cfg.isascii()
assert cfg.count('    linux ') == 9
for line in cfg.splitlines():
    if line.lstrip().startswith('linux '):
        words = line.split()
        assert words.index('$bootkit_extra') > words.index('---')
        if 'splash' in words:
            assert words.index('$bootkit_extra') > words.index('splash')
assert cfg.count(' /casper/bootkit-ramsel.cpio.gz') == 3
for osname in ('ubuntu', 'lubuntu', 'server'):
    assert cfg.count('bootkit.os=' + osname + ' ') == 3
    assert cfg.count('initrd /casper/initrd.' + osname) == 3
for block in cfg.split('menuentry ')[1:10]:
    assert (' toram ' in block) == (' /casper/bootkit-ramsel.cpio.gz' in block)
fix = module('fix', 'tools/ubuntu-merge/fix-pvd.py')
def image(primary, secondary):
    data = bytearray(34 * 2048)
    for block, count in ((16, primary), (32, secondary)):
        start = block * 2048
        data[start:start + 7] = b'\x01CD001\x01'
        data[start + 80:start + 88] = struct.pack('<I', count) + struct.pack('>I', count)
    return io.BytesIO(data)
correct = 4710055
stream = image(correct - (1 << 22), correct - 16)
assert fix.repair(stream, correct * 2048)
stream.seek(16 * 2048 + 80)
assert struct.unpack('<I', stream.read(4))[0] == correct
assert not fix.repair(stream, correct * 2048)
for wrong in (correct - 1, correct + 1):
    stream = image(wrong, correct - 16)
    before = stream.getvalue()
    try:
        fix.repair(stream, correct * 2048)
        raise AssertionError('不明な不整合を許した')
    except ValueError:
        assert stream.getvalue() == before
driver = module('qemu_driver', 'ventoy/ramsel/verify-qemu.py')
assert driver.clean_terminal('\x1b]3008;start=test\x1b\\2090\r\n') == '2090\n'
class Monitor:
    def __init__(self):
        self.commands = []
    def send(self, command, note, transcript):
        self.commands.append(command)
assert driver.clean_terminal('\r\x1b[KID_DONE\r\n') == '\nID_DONE\n'
monitor = Monitor()
driver.time.sleep = lambda _: None
driver.keyboard(monitor, '@', [])
assert monitor.commands == ['sendkey shift-2', 'sendkey ret']
print('PASS: merge boot archive, 9 GRUB entries, PVD repair, GRUB keyboard and fail-closed controls')
PY
