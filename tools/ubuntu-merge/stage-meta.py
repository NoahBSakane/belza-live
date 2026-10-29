#!/usr/bin/env python3
"""公式 ISO の小さな casper メタデータだけを保存する。層・initrd は複製しない。"""
import shlex
import subprocess
import sys
from pathlib import Path


def stage(iso, destination):
    listing = subprocess.run([
        'xorriso', '-indev', str(iso), '-find', '/casper', '-maxdepth', '1',
        '-type', 'f', '-not', '-name', '*.squashfs', '-not', '-name', 'initrd',
        '-not', '-name', 'vmlinuz', '-exec', 'echo', '--',
    ], check=True, stdout=subprocess.PIPE, text=True)
    paths = shlex.split(listing.stdout)
    if not paths or any(not p.startswith('/casper/') or Path(p).name in ('initrd', 'vmlinuz')
                        or p.endswith('.squashfs') for p in paths):
        raise ValueError('casper メタデータの一覧が不正')
    destination.mkdir(parents=True, exist_ok=True)
    casper = destination / 'casper'
    casper.mkdir(exist_ok=True)
    casper.chmod(0o755)
    command = ['xorriso', '-indev', str(iso), '-osirrox', 'on']
    for path in paths:
        command += ['-extract_single', path, str(casper / Path(path).name)]
    command += ['-extract', '/.disk', str(destination / 'disk')]
    subprocess.run(command, check=True)



if __name__ == '__main__':
    stage(Path(sys.argv[1]), Path(sys.argv[2]))
