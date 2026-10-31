#!/usr/bin/env python3
"""検証専用 MBR/exFAT raw イメージ内の ISO を、展開せずにハッシュ照合する。"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import struct


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('disk', type=Path)
    parser.add_argument('--image', default='/ISO/live/ubuntu-merge-26.04.1-amd64.iso')
    parser.add_argument('--sha256', required=True)
    args = parser.parse_args()
    disk = args.disk.resolve()
    if not disk.is_file() or not disk.is_relative_to(Path.cwd().resolve()):
        parser.error('作業ツリー内の通常ファイルだけを読みます')
    with disk.open('rb') as stream:
        mbr = stream.read(512)
        assert mbr[510:] == b'\x55\xaa', 'MBR signature'
        start = struct.unpack_from('<I', mbr, 454)[0] * 512
        stream.seek(start)
        boot = stream.read(512)
        assert boot[3:11] == b'EXFAT   ', 'exFAT signature'
        sector = 1 << boot[108]
        cluster = sector << boot[109]
        fat = start + struct.unpack_from('<I', boot, 80)[0] * sector
        heap = start + struct.unpack_from('<I', boot, 88)[0] * sector
        count = struct.unpack_from('<I', boot, 92)[0]
        root = struct.unpack_from('<I', boot, 96)[0]

        def read_cluster(number):
            assert 2 <= number < count + 2, 'cluster bounds'
            stream.seek(heap + (number - 2) * cluster)
            value = stream.read(cluster)
            assert len(value) == cluster, 'short cluster'
            return value

        def chain(first, length=None, contiguous=False):
            seen = set()
            remaining = math.ceil(length / cluster) if length is not None else None
            while first < 0xfffffff8 and remaining != 0:
                assert first not in seen, 'cluster cycle'
                seen.add(first)
                yield read_cluster(first)
                if remaining is not None:
                    remaining -= 1
                if contiguous:
                    first += 1
                else:
                    stream.seek(fat + first * 4)
                    first = struct.unpack('<I', stream.read(4))[0]
            assert remaining in (None, 0), 'short chain'

        def entries(raw):
            slots = [raw[i:i + 32] for i in range(0, len(raw), 32)]
            i = 0
            while i < len(slots) and slots[i][0]:
                item = slots[i]
                if item[0] != 0x85:
                    i += 1
                    continue
                size = item[1]
                secondary = slots[i + 1:i + 1 + size]
                assert len(secondary) == size and secondary[0][0] == 0xc0
                allocation = secondary[0]
                name = b''.join(x[2:] for x in secondary[1:] if x[0] == 0xc1)
                name = name[:allocation[3] * 2].decode('utf-16-le')
                yield name, struct.unpack_from('<H', item, 4)[0], allocation
                i += 1 + size

        directory = b''.join(chain(root))
        parts = [part for part in args.image.split('/') if part]
        assert parts
        for index, part in enumerate(parts):
            hit = next((entry for entry in entries(directory) if entry[0].casefold() == part.casefold()), None)
            assert hit is not None, f'missing {part}'
            name, attributes, allocation = hit
            first = struct.unpack_from('<I', allocation, 20)[0]
            length = struct.unpack_from('<Q', allocation, 24)[0]
            contiguous = bool(allocation[1] & 2)
            if index < len(parts) - 1:
                assert attributes & 0x10, 'not directory'
                directory = b''.join(chain(first, length, contiguous))
            else:
                assert not attributes & 0x10, 'not file'
        digest = hashlib.sha256()
        remaining = length
        for block in chain(first, length, contiguous):
            digest.update(block[:remaining])
            remaining = max(0, remaining - len(block))
        result = {'image': args.image, 'size': length, 'sha256': digest.hexdigest(),
                  'cluster_bytes': cluster, 'matches': digest.hexdigest() == args.sha256}
        print(json.dumps(result, indent=2))
        assert result['matches'], 'SHA-256 mismatch'


if __name__ == '__main__':
    main()
