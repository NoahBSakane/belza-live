#!/usr/bin/env python3
"""xorriso 1.5.8 の追記で 8 GiB ごとに巻き戻る primary PVD サイズを補正。

partition_offset=16 の second PVD は正しい値を持つ。既知の 2^22 sector
単位の差だけを許し、他の不整合では書かずに止める。層や他の記述は変更しない。
"""
import struct
import sys
from pathlib import Path


def repair(stream, size):
    stream.seek(16 * 2048)
    primary = stream.read(2048)
    stream.seek(32 * 2048)
    secondary = stream.read(2048)
    if primary[:7] != b'\x01CD001\x01' or secondary[:7] != b'\x01CD001\x01':
        raise ValueError('partition_offset=16 の PVD が揃っていない')
    def volume(data):
        le = struct.unpack_from('<I', data, 80)[0]
        be = struct.unpack_from('>I', data, 84)[0]
        if le != be:
            raise ValueError('PVD の両 endian が不一致')
        return le
    old = volume(primary)
    expected = volume(secondary) + 16
    if old == expected:
        return False
    if expected > size // 2048 or expected <= old or (expected - old) % (1 << 22):
        raise ValueError(f'既知の巻戻りではない: primary={old}, expected={expected}')
    stream.seek(16 * 2048 + 80)
    stream.write(struct.pack('<I', expected) + struct.pack('>I', expected))
    print(f'PVD volume size: {old} -> {expected} sectors', flush=True)
    return True


if __name__ == '__main__':
    path = Path(sys.argv[1])
    with path.open('r+b') as stream:
        repair(stream, path.stat().st_size)
