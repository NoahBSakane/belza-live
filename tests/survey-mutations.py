#!/usr/bin/env python3
"""作業ツリー内のコピーだけを壊し、安全検査の検出力を確かめる。"""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
from concurrent.futures import ThreadPoolExecutor

root = Path(__file__).resolve().parent.parent
(root / '.agent-handoff').mkdir(exist_ok=True)
mutations = {
    'non-ascii-summary': ('survey', 'Press Enter after taking a photo',
                          'Press Enter after taking a photo 日本語',
                          'non-ASCII output:'),
    'non-ascii-error': ('survey', 'Unknown profile', 'Unknown profile 日本語',
                        'non-ASCII output:'),
    'non-ascii-list': ('survey', "printf '%s\\n' edge14-0578 g560 generic; exit 0",
                       "printf '%s\\n' edge14-0578 g560 generic 日本語; exit 0",
                       'non-ASCII output:'),
    'boot-exclusion': ('hw-common.sh', 'is_boot "$candidate" && continue', ':',
                       'smartctl -t long /dev/sde が残る'),
    'usb-exclusion': ('hw-common.sh', '[ "$(connection "$candidate")" != usb ] || continue', ':',
                      'dd if=/dev/sdc  が残る'),
    'removable-exclusion': ('hw-common.sh', '[ "$(read_value "$HW_SYSFS/block/$candidate/removable")" = 0 ] || continue', ':',
                            'dd if=/dev/sdd  が残る'),
    'short-starts-long': ('survey', 'profile=; long=0', 'profile=; long=1',
                         'smartctl -t  が残る'),
    'disk-write': ('survey', '# 機種別の検査。',
                   'dd if=/dev/zero of=/dev/sda\n# 機種別の検査。',
                   'dd の書き込み先が危険'),
}
with tempfile.TemporaryDirectory(prefix='survey-mutations.', dir=root) as work:
    def check(item):
        name, (file, old, new, expected) = item
        source = Path(work) / name
        shutil.copytree(root / 'auto/survey', source)
        path = source / file
        content = path.read_text()
        assert old in content
        path.write_text(content.replace(old, new))
        env = dict(os.environ, SURVEY_SOURCE=str(source), TMPDIR=work,
                   PYTHONDONTWRITEBYTECODE='1')
        log = root / '.agent-handoff' / f'mutation-{name}.log'
        with log.open('w') as output:
            result = subprocess.run(['sh', str(root / 'tests/test-survey.sh')],
                                    env=env, stdout=output, stderr=subprocess.STDOUT)
        output = log.read_text()
        assert result.returncode != 0 and expected in output, (name, output[-3000:])
        print(f'PASS: 壊した版 {name}: 終了 {result.returncode}: {expected}')

    with ThreadPoolExecutor(max_workers=len(mutations)) as pool:
        list(pool.map(check, mutations.items()))
