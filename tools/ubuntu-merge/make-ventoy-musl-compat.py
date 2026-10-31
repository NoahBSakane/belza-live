#!/usr/bin/env python3
"""Ventoy 1.1.18 aarch64 formatter の、使い捨て Alpine VM 専用の互換 ELF。

__fxstat64(version, fd, stat) を Linux AArch64 fstat syscall に渡す。
一般の glibc 互換ライブラリではない。検証済みの正常な fd に対して使う。
"""
import argparse
import struct
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('output', type=Path)
args = parser.parse_args()
output = args.output.resolve()
if not output.is_relative_to(Path.cwd().resolve()):
    parser.error('生成先は作業ツリー内に置いてください')
p=bytearray(4096)
strings=b'\0__fxstat64\0'
p[0x200:0x200+len(strings)]=strings
# Elf64_Sym, global STT_FUNC
p[0x240:0x258]=bytes(24)
p[0x258:0x270]=struct.pack('<IBBHQQ',1,0x12,0,1,0x300,24)
# sysv hash nbucket=1,nchain=2,bucket=1,chain=0,0
p[0x280:0x294]=struct.pack('<IIIII',1,2,1,0,0)
# mov w0,w1; mov x1,x2; mov x8,#80; svc 0; ret
p[0x300:0x314]=struct.pack('<IIIII',0x2a0103e0,0xaa0203e1,0xd2800a08,0xd4000001,0xd65f03c0)
dyn=[(5,0x200),(10,len(strings)),(6,0x240),(11,24),(4,0x280),(0,0)]
for i,(a,b) in enumerate(dyn): p[0x180+i*16:0x190+i*16]=struct.pack('<QQ',a,b)
p[:64]=struct.pack('<16sHHIQQQIHHHHHH',b'\x7fELF\x02\x01\x01'+bytes(9),3,183,1,0,64,0,0,64,56,2,64,0,0)
p[64:120]=struct.pack('<IIQQQQQQ',1,7,0,0,0,len(p),len(p),4096)
p[120:176]=struct.pack('<IIQQQQQQ',2,6,0x180,0x180,0x180,len(dyn)*16,len(dyn)*16,8)
output.write_bytes(p)
