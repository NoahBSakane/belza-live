#!/bin/sh
set -eu
HERE=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
PYTHONDONTWRITEBYTECODE=1 python3 - "$HERE" <<'PY'
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import os
import shutil
import subprocess
import sys
import tempfile
root = Path(sys.argv[1])
def check(kind):
    with tempfile.TemporaryDirectory(prefix='layer-mutation.', dir=root) as tmp:
        target = Path(tmp)
        for directory in ('auto', 'config'):
            shutil.copytree(root / directory, target / directory, symlinks=True)
        if kind == 'grub':
            path = target / 'config/bootloaders/grub-pc/config.cfg'
            path.write_text(path.read_text().replace('set default=0', 'set default=1'))
        else:
            path = target / 'config/bootloaders/syslinux_common/live.cfg.in'
            text = path.read_text().replace('\tmenu default\n', '')
            text = text.replace('label live-@FLAVOUR@-cli\n', 'label live-@FLAVOUR@-cli\n\tmenu default\n')
            path.write_text(text)
        result = subprocess.run(['sh', str(root / 'tests/test-boot-config.sh')],
                                env=dict(os.environ, BOOT_CONFIG_SOURCE=str(target)),
                                capture_output=True, text=True)
        assert result.returncode != 0 and 'AssertionError' in result.stderr, (kind, result.stdout, result.stderr)
        return 'PASS: rejected wrong ' + kind + ' default'
print('\n'.join(ThreadPoolExecutor(max_workers=2).map(check, ('syslinux', 'grub'))))
PY
