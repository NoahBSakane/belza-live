#!/usr/bin/env python3
"""公式 initrd に bootkit-ramsel の premount 一式を入れて再構成する。

使い方: python3 -I rebuild-initrd.py <公式ISO> <タグ> <出力initrd>
環境変数 BOOTKIT_RAMSEL_SRC に ventoy/ramsel を指定する。
標準ライブラリだけを使う。

手順: 公式 ISO から casper/initrd を取り出し、連結 cpio メンバに割り、
主部 (scripts/casper を含む cpio。zstd ならほどく) の TRAILER 手前に
30bootkit-ramsel と置換 ORDER を足し、zstd -19 で圧縮し直して連結する。
標準 ORDER が casper 26.04.2 の想定 4 行と違う場合は止める。
"""
import os
import subprocess
import sys


# casper 26.04.2 の標準 ORDER の中身に固定。公式 initrd の実物と照合する。
# 変わっていたら組み立てを止める (T1 の本番 ISO でも同じ検査をする)。
STOCK_ORDER = (b'/scripts/casper-premount/10driver_updates "$@"\n'
               b'[ -e /conf/param.conf ] && . /conf/param.conf\n'
               b'/scripts/casper-premount/20iso_scan "$@"\n'
               b'[ -e /conf/param.conf ] && . /conf/param.conf\n')


def log(msg):
    print(msg, flush=True)


def run(*cmd):
    proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if proc.returncode != 0:
        tail = proc.stderr.decode('utf-8', 'replace')[-500:]
        raise RuntimeError('%s: %s' % (' '.join(cmd), tail))
    return proc.stdout


def pad4(length):
    """newc は頭 (110) + 名前、内容をそれぞれ 4 バイト境界へ整える。"""
    return (4 - length % 4) % 4


def entries(blob):
    """newc cpio を走査し、{名前: 内容} と TRAILER 項目の頭を返す。"""
    off = 0
    found = {}
    while off + 110 <= len(blob):
        head = blob[off:off + 110]
        if head[:6] != b'070701':
            raise RuntimeError('cpio 解析に失敗')
        namesize = int(head[94:102], 16)
        filesize = int(head[54:62], 16)
        name = blob[off + 110:off + 110 + namesize].split(b'\0')[0].decode()
        dataoff = off + 110 + namesize + pad4(110 + namesize)
        if name == 'TRAILER!!!':
            return found, off
        found[name] = blob[dataoff:dataoff + filesize]
        off = dataoff + filesize + pad4(filesize)
    raise RuntimeError('TRAILER が無い')


def entry(name, body, mode):
    name_b = name + b'\0'
    fields = [0, mode, 0, 0, 1, 0, len(body), 0, 0, 0, 0, len(name_b), 0]
    head = b'070701' + b''.join(b'%08x' % v for v in fields)
    head += name_b + b'\0' * pad4(110 + len(name_b))
    return head + body + b'\0' * pad4(len(body))


def split_members(data):
    """7zz の Physical Size を頼りに連結メンバへ割る。"""
    members = []
    rest = data
    while True:
        with open('/tmp/ramsel-member.bin', 'wb') as stream:
            stream.write(rest)
        env = dict(os.environ, LC_ALL='C')
        proc = subprocess.run(['7zz', 'l', '/tmp/ramsel-member.bin'],
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                              env=env)
        text = proc.stdout.decode('utf-8', 'replace')
        phys = None
        trailing = 'There are data after the end' in text
        for line in text.splitlines():
            if line.startswith('Physical Size = '):
                phys = int(line.split('=')[1].strip())
        if phys is None or not trailing:
            members.append(rest)
            break
        members.append(rest[:phys])
        rest = rest[phys:]
    os.unlink('/tmp/ramsel-member.bin')
    return members


def main():
    iso, tag, out = sys.argv[1], sys.argv[2], sys.argv[3]
    ramsel = os.environ['BOOTKIT_RAMSEL_SRC']
    data = run('bsdtar', '-xOf', iso, 'casper/initrd')
    members = split_members(data)
    log('%s: initrd member %d 個' % (tag, len(members)))

    main_index = None
    main_cpio = None
    for i, member in enumerate(members):
        blob = member
        if blob[:4] == b'\x28\xb5\x2f\xfd':
            with open('/tmp/ramsel-main.zst', 'wb') as stream:
                stream.write(blob)
            proc = subprocess.run(['zstd', '-d', '-c', '/tmp/ramsel-main.zst'],
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            os.unlink('/tmp/ramsel-main.zst')
            if proc.returncode != 0:
                continue
            blob = proc.stdout
        if blob[:6] == b'070701' and b'scripts/casper' in blob[:2000000]:
            main_index = i
            main_cpio = blob
            break
    if main_cpio is None:
        raise RuntimeError('%s: 主部が見つからない' % tag)

    files, trailer_off = entries(main_cpio)
    if files.get('scripts/casper-premount/ORDER') != STOCK_ORDER:
        raise RuntimeError('%s: 標準 ORDER が変わっている。置換 ORDER を見直す' % tag)
    log('%s: 標準 ORDER は想定どおり' % tag)

    with open(os.path.join(ramsel, '30bootkit-ramsel'), 'rb') as stream:
        script = stream.read()
    with open(os.path.join(ramsel, 'ORDER'), 'rb') as stream:
        order = stream.read()

    new_entries = (entry(b'scripts/casper-premount/30bootkit-ramsel', script, 0o100755) +
                   entry(b'scripts/casper-premount/ORDER', order, 0o100644))
    new_main = main_cpio[:trailer_off] + new_entries
    new_main += entry(b'TRAILER!!!', b'', 0)
    new_main += b'\0' * ((512 - len(new_main) % 512) % 512)
    # 差し替え後の自己検査 (TRAILER まで届き、2 ファイルが読める)。
    check, _ = entries(new_main)
    assert 'scripts/casper-premount/30bootkit-ramsel' in check
    assert check.get('scripts/casper-premount/ORDER') == order
    log('%s: 差し替え後の自己検査が成功' % tag)

    with open('/tmp/ramsel-new.cpio', 'wb') as stream:
        stream.write(new_main)
    run('7zz', 'l', '/tmp/ramsel-new.cpio')
    proc = subprocess.run(['zstd', '-19', '-c', '/tmp/ramsel-new.cpio'],
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    os.unlink('/tmp/ramsel-new.cpio')
    if proc.returncode != 0:
        raise RuntimeError('zstd 再圧縮に失敗')
    members[main_index] = proc.stdout
    with open(out, 'wb') as stream:
        for member in members:
            stream.write(member)
    log('%s: initrd 再構成が完了 (%d バイト)' % (tag, sum(len(m) for m in members)))


if __name__ == '__main__':
    main()
