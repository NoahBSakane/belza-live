#!/usr/bin/env python3
"""Inspect captured survey bytes, summary bounds, and non-comment source lines.

Python's byte check is also usable with BSD grep (which has no grep -P).
The byte range is equivalent to LC_ALL=C grep -P '[^\\x00-\\x7F]'.
"""
from pathlib import Path
import argparse
import os
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--source', action='store_true')
parser.add_argument('paths', nargs='+', type=Path)
args = parser.parse_args()
# Use the requested grep expression when PCRE is available; never interpret a
# missing grep -P implementation as a successful ASCII check.
env = dict(os.environ, LC_ALL='C')
probe = subprocess.run(['grep', '-P', r'[^\x00-\x7F]'], input=b'',
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                       env=env)
pcre = probe.returncode == 1
for path in args.paths:
    data = path.read_bytes()
    if args.source:
        data = b'\n'.join(line for line in data.splitlines()
                          if not line.lstrip().startswith(b'#'))
    if pcre:
        result = subprocess.run(['grep', '-nP', r'[^\x00-\x7F]'], input=data,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                env=env)
        if result.returncode not in (0, 1):
            raise SystemExit(f'FAIL: ASCII grep failed: {path}')
        non_ascii = result.returncode == 0
    else:
        non_ascii = not data.isascii()
    if non_ascii:
        kind = 'source' if args.source else 'output'
        raise SystemExit(f'FAIL: non-ASCII {kind}: {path}')
    if not args.source and path.name == 'summary.txt':
        lines = data.splitlines()
        if len(lines) > 40 or any(len(line.expandtabs(8)) > 80 for line in lines):
            raise SystemExit(f'FAIL: summary exceeds 80 columns / 40 lines: {path}')
