#!/bin/sh
# 統合 ISO 用設定の保持・冪等性と、USB 起動のコマンドを検査する。
set -eu
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
WORK=$(mktemp -d "$HERE/test-ventoy-merge.XXXXXX")
trap 'rm -rf "$WORK"' 0
python3 -I - "$HERE" "$WORK" <<'PY'
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
from types import SimpleNamespace
root, work = map(Path, sys.argv[1:])
old = {"control": [{"VTOY_DEFAULT_MENU_MODE": "0"}],
       "injection": [{"image": "/other.iso", "archive": "/other.tar.gz"}],
       "conf_replace": [{"iso": "/other.iso", "org": "/a", "new": "/b"}],
       "menu_alias": [{"image": "/other.iso", "alias": "preserve"}]}
(work / 'old.json').write_text(json.dumps(old))
command = [sys.executable, '-I', str(root / 'ventoy/merge-ventoy-json.py')]
subprocess.run(command + [str(work / 'old.json'), str(work / 'new.json'),
                         '--profile', 'ubuntu-merge'], check=True)
new = json.loads((work / 'new.json').read_text())
for key in ('control', 'injection', 'conf_replace'):
    assert new[key] == old[key], key
assert new['menu_alias'][0] == old['menu_alias'][0]
assert new['menu_alias'][1]['image'] == '/ISO/live/ubuntu-merge-26.04.1-amd64.iso'
subprocess.run(command + [str(work / 'new.json'), str(work / 'again.json'),
                         '--profile', 'ubuntu-merge'], check=True)
assert (work / 'new.json').read_bytes() == (work / 'again.json').read_bytes()
spec = importlib.util.spec_from_file_location('verify', root / 'ventoy/ramsel/verify-qemu.py')
v = importlib.util.module_from_spec(spec)
spec.loader.exec_module(v)
a = SimpleNamespace(machine='q35', smp=4, mem=4096, mode='ventoy-uefi',
                    ventoy_disk=work / 'disk.raw', ventoy_overlay=work / 'overlay.qcow2', transport='pipe', iso=work / 'iso.iso')
c = v.build_command(a, work / 'monitor', work / 'serial', work / 'code', work / 'vars')
assert any('id=usb0' in x and 'format=qcow2' in x and 'overlay.qcow2' in x for x in c)
assert 'usb-storage,id=ventoyusb,drive=usb0,bootindex=1' in c
assert not any('ide-cd' in x or 'id=cd0' in x for x in c)
assert c[c.index('-net') + 1] == 'none'
assert c[c.index('-m') + 1] == '4096'
a.mode = 'ventoy-bios'
bios = v.build_command(a, work / 'monitor', work / 'serial', None, None)
assert '-kernel' not in bios and not any('pflash' in x for x in bios)
assert 'usb-storage,id=ventoyusb,drive=usb0,bootindex=1' in bios
print('ok: 統合 ISO 設定の保持・冪等性 / 元ディスクを保持する仮想 USB / 通信なし')
PY
python3 -I "$HERE/tools/ubuntu-merge/make-ventoy-musl-compat.py" "$WORK/compat.so"
python3 -I - "$WORK/compat.so" <<'PY'
from pathlib import Path
import struct
import sys
raw = Path(sys.argv[1]).read_bytes()
assert raw[:4] == b'\x7fELF' and len(raw) == 4096
assert struct.unpack_from('<H', raw, 18)[0] == 183
assert b'__fxstat64\0' in raw
assert struct.unpack_from('<IIIII', raw, 0x300) == (
    0x2a0103e0, 0xaa0203e1, 0xd2800a08, 0xd4000001, 0xd65f03c0)
print('ok: Alpine 検証 VM 用 AArch64 互換 ELF の再生成')
PY
