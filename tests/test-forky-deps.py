#!/usr/bin/env python3
"""依存検査を小さな索引で試す。実ネットワーク・APT は使わない。"""
import contextlib
import importlib.util
import io
import lzma
from pathlib import Path
import tempfile
import sys

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('deps', HERE / 'check-forky-deps.py')
deps = importlib.util.module_from_spec(spec)
spec.loader.exec_module(deps)

for left, right in [('2.41', '2.38'), ('1:1', '99'), ('1.0', '1.0~rc1'),
                    ('1.0-1+b2', '1.0-1+b1'), ('1.10', '1.9')]:
    assert deps.version_compare(left, right) > 0, (left, right)
    assert deps.version_compare(right, left) < 0, (right, left)
assert deps.version_compare('1.01', '1.1-0') == 0
assert not deps.satisfies(None, '>=', '1')


def record(name, version, depends='', provides=''):
    return (f'Package: {name}\nVersion: {version}\nDepends: {depends}\n'
            f'Provides: {provides}\n\n')


with tempfile.TemporaryDirectory(prefix='test-forky-deps.', dir=HERE) as work:
    cache = Path(work)
    trixie = (record('libc6', '2.41') + record('libexisting', '2') +
              record('provider', '1', provides='virtual (= 2)'))
    forky = (record('clonezilla', '5', 'drbl, partclone') +
             record('drbl', '5', 'missing | virtual (>= 2)') +
             record('partclone', '0.3.49', 'libnew, libexisting (>= 2)') +
             record('libnew', '1', 'libc6 (>= 2.38)'))
    allowed = deps.ROOTS | {'libnew'}
    for arch in ('amd64', 'arm64'):
        def write(suite, data):
            with lzma.open(cache / f'{suite}-main-{arch}-Packages.xz', 'wt') as stream:
                stream.write(data)

        def check():
            with contextlib.redirect_stdout(io.StringIO()):
                deps.check(cache, allowed, arch)

        write('trixie', trixie)
        write('forky', forky)
        check()
        # ライブラリの依存を壊すと、libc6 を forky に広げず失敗する。
        write('forky', forky.replace('libc6 (>= 2.38)', 'libc6 (>= 99)') + record('libc6', '99'))
        try:
            check()
        except ValueError as error:
            assert 'libc6' in str(error)
        else:
            raise AssertionError('新しい libc6 の要求を検出しませんでした')
        # 再帰先で版付き Provides を無版にすると失敗する。
        write('forky', forky)
        write('trixie', trixie.replace('virtual (= 2)', 'virtual'))
        try:
            check()
        except ValueError as error:
            assert 'virtual' in str(error)
        else:
            raise AssertionError('版付き Provides の欠落を検出しませんでした')
print('ALL PASS: Debian 版比較・再帰依存・追加ライブラリ導出・基盤更新拒否・代替/Provides')
