#!/bin/sh
set -eu
HERE=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
python3 - "$HERE" <<'PY'
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import os
import subprocess
import sys
import tempfile
root = Path(sys.argv[1])
source = (root / 'config/includes.installer/usr/lib/live-installer.d/00bootkit-layer').read_text()
def check(kind):
    with tempfile.TemporaryDirectory(prefix='installer-mutation.', dir=root) as tmp:
        script = Path(tmp) / 'hook'
        if kind == 'exclusion':
            script.write_text(source.replace('-path ./etc/fstab -o ', ''))
            expected = 'excluded etc/fstab overwritten'
        else:
            script.write_text(source.replace('flavor=${arg#bootkit.flavor=}', 'flavor=cli'))
            expected = 'selected layer not copied'
        result = subprocess.run(['sh', str(root / 'tests/test-installer-layer.sh')],
            env=dict(os.environ, BOOTKIT_LAYER_SCRIPT=str(script)), capture_output=True, text=True)
        assert result.returncode != 0 and expected in result.stderr, (kind, result.stdout, result.stderr)
        return 'PASS: rejected broken ' + kind
print('\n'.join(ThreadPoolExecutor(max_workers=2).map(check, ('exclusion', 'cmdline'))))
PY
