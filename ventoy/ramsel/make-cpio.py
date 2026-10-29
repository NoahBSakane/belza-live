#!/usr/bin/env python3
"""公式 initrd の後へ連結する再現可能な gzip/newc を作る。"""
import gzip
import sys
from pathlib import Path


def entry(name, body, mode):
    name = name.encode() + b'\0'
    fields = [0, mode, 0, 0, 1, 0, len(body), 0, 0, 0, 0, len(name), 0]
    header = b'070701' + b''.join(f'{v:08x}'.encode() for v in fields) + name
    return header + b'\0' * (-len(header) % 4) + body + b'\0' * (-len(body) % 4)


def archive(source):
    data = b''
    for directory in ('scripts', 'scripts/casper-premount'):
        data += entry(directory, b'', 0o40755)
    for name, mode in (('30bootkit-ramsel', 0o100755), ('ORDER', 0o100644)):
        data += entry('scripts/casper-premount/' + name, (source / name).read_bytes(), mode)
    data += entry('TRAILER!!!', b'', 0)
    return gzip.compress(data + b'\0' * (-len(data) % 512), mtime=0)


if __name__ == '__main__':
    Path(sys.argv[1]).write_bytes(archive(Path(__file__).resolve().parent))
