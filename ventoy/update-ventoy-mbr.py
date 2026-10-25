#!/usr/bin/env python3
"""Ventoy を MBR のディスクで「更新(Update)」する。Ventoy 1.1.18 の tool/VentoyWorker.sh の更新手順(MBR)を、
同じバイト操作で再現する。1 番目のパーティション(ISO などのデータ)には触れない。

使い方:
  update-ventoy-mbr.py --ventoy-dir <展開した ventoy-X.Y.Z> [--backup-dir DIR] [--apply] TARGET
  TARGET は /dev/rdiskN などのブロックデバイス、または試験用の通常ファイル。
  --apply が無いときは検査と退避の計画だけを表示し、書き込まない。

安全策: GPT・Ventoy 以外・パーティション構成が合わない・セキュアブート版でない場合は拒否する。
書き込み前に、先頭 1MiB と第 2 パーティション(32MiB)を退避し、書き込み後に全領域を読み戻して照合する。
"""
import argparse, hashlib, json, lzma, os, struct, sys, time

SECTOR = 512
VENTOY_SECTOR_NUM = 65536  # 32MiB


def die(msg):
    print("拒否:", msg, file=sys.stderr)
    sys.exit(2)


def read_at(f, off, n):
    f.seek(off)
    d = f.read(n)
    if len(d) != n:
        die(f"読み取りが短い: offset={off} 要求={n} 実際={len(d)}")
    return d


def write_at(f, off, data):
    f.seek(off)
    f.write(data)


# ---- 最小の FAT12/16 リーダー(VTOYEFI の中のファイルの有無と version の読み取り用) ----
class Fat:
    def __init__(self, img):
        self.img = img
        b = img[:512]
        self.bps = struct.unpack_from("<H", b, 11)[0]
        self.spc = b[13]
        self.rsv = struct.unpack_from("<H", b, 14)[0]
        self.nfat = b[16]
        self.root_ent = struct.unpack_from("<H", b, 17)[0]
        tot16 = struct.unpack_from("<H", b, 19)[0]
        self.fatsz = struct.unpack_from("<H", b, 22)[0]
        if self.bps != 512 or not self.spc or not self.root_ent or not self.fatsz:
            die("VTOYEFI が FAT12/16 として読めない(FAT32 は未対応)")
        self.root_off = (self.rsv + self.nfat * self.fatsz) * self.bps
        self.data_off = self.root_off + self.root_ent * 32
        total = tot16 or struct.unpack_from("<I", b, 32)[0]
        clusters = (total - (self.data_off // self.bps)) // self.spc
        self.fat16 = clusters >= 4085
        fo = self.rsv * self.bps
        self.fat = img[fo:fo + self.fatsz * self.bps]

    def nxt(self, c):
        if self.fat16:
            return struct.unpack_from("<H", self.fat, c * 2)[0]
        o = c + c // 2
        v = struct.unpack_from("<H", self.fat, o)[0]
        return (v >> 4) if c & 1 else (v & 0xFFF)

    def chain(self, c):
        out = []
        end = 0xFFF8 if self.fat16 else 0xFF8
        while 2 <= c < end and len(out) < 100000:
            out.append(c)
            c = self.nxt(c)
        return out

    def entries(self, raw):
        lfn, res = [], []
        for i in range(0, len(raw), 32):
            e = raw[i:i + 32]
            if e[0] == 0:
                break
            if e[0] == 0xE5:
                lfn = []
                continue
            if e[11] == 0x0F:
                part = e[1:11] + e[14:26] + e[28:32]
                lfn.insert(0, part.decode("utf-16-le", "ignore").split("\x00")[0].split("￿")[0])
                continue
            name = e[:8].decode("ascii", "ignore").rstrip()
            ext = e[8:11].decode("ascii", "ignore").rstrip()
            short = name + ("." + ext if ext else "")
            long = "".join(lfn) if lfn else short
            lfn = []
            if e[11] & 0x08:
                continue
            clus = struct.unpack_from("<H", e, 26)[0]
            size = struct.unpack_from("<I", e, 28)[0]
            res.append((long, short, bool(e[11] & 0x10), clus, size))
        return res

    def dir_raw(self, clus):
        if clus == 0:
            return self.img[self.root_off:self.root_off + self.root_ent * 32]
        buf = b""
        for c in self.chain(clus):
            o = self.data_off + (c - 2) * self.spc * self.bps
            buf += self.img[o:o + self.spc * self.bps]
        return buf

    def find(self, path):
        clus = 0
        parts = [p for p in path.split("/") if p]
        for i, p in enumerate(parts):
            hit = None
            for long, short, isdir, c, size in self.entries(self.dir_raw(clus)):
                if long.lower() == p.lower() or short.lower() == p.lower():
                    hit = (isdir, c, size)
                    break
            if hit is None:
                return None
            if i < len(parts) - 1:
                if not hit[0]:
                    return None
                clus = hit[1]
            else:
                return hit
        return None

    def read_file(self, path):
        h = self.find(path)
        if h is None or h[0]:
            return None
        data = b""
        for c in self.chain(h[1]):
            o = self.data_off + (c - 2) * self.spc * self.bps
            data += self.img[o:o + self.spc * self.bps]
        return data[:h[2]]


def sha(b):
    return hashlib.sha256(b).hexdigest()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ventoy-dir", required=True)
    ap.add_argument("--backup-dir")
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("target")
    a = ap.parse_args()

    vd = a.ventoy_dir
    boot = open(os.path.join(vd, "boot/boot.img"), "rb").read()
    core = lzma.open(os.path.join(vd, "boot/core.img.xz")).read()
    ven = lzma.open(os.path.join(vd, "ventoy/ventoy.disk.img.xz")).read()
    newver = open(os.path.join(vd, "ventoy/version")).read().strip()
    if len(boot) < 440 or len(core) < 1024 or len(ven) < VENTOY_SECTOR_NUM * SECTOR:
        die("Ventoy の配布物のサイズが想定と違う")
    core = core[:2047 * SECTOR]
    ven = ven[:VENTOY_SECTOR_NUM * SECTOR]

    is_dev = a.target.startswith("/dev/")
    if is_dev and not (a.target.startswith("/dev/rdisk") or a.target.startswith("/dev/disk")):
        die("デバイスは /dev/rdiskN か /dev/diskN だけ")
    if is_dev and a.target[-1].isdigit() and "s" in a.target.split("disk")[-1]:
        die("パーティション(diskNsM)ではなくディスク全体を指定する")
    f = open(a.target, "r+b" if a.apply else "rb", buffering=0)

    head = read_at(f, 0, 2048 * SECTOR)
    if head[510:512] != b"\x55\xaa":
        die("MBR の署名がない")
    if head[450] == 0xEE:
        die("GPT のディスク(この手順は MBR のみ)")
    p1_start, p1_size = struct.unpack_from("<II", head, 446 + 8)
    p2_type = head[446 + 16 + 4]
    p2_start, p2_size = struct.unpack_from("<II", head, 446 + 16 + 8)
    if p2_type != 0xEF or p2_size != VENTOY_SECTOR_NUM:
        die(f"第 2 パーティションが Ventoy の形でない(type={p2_type:#x} size={p2_size})")
    if p2_start < p1_start + p1_size or p2_start % 8:
        die("パーティションの位置が想定と違う")
    if head[446 + 32 + 4] != 0 or head[446 + 48 + 4] != 0:
        die("第 3・第 4 パーティションがある")
    p2 = read_at(f, p2_start * SECTOR, VENTOY_SECTOR_NUM * SECTOR)
    if b"VTOYEFI" not in p2[:512]:
        die("第 2 パーティションのラベルが VTOYEFI でない")
    fat = Fat(p2)
    oldver_b = fat.read_file("/ventoy/version")
    oldver = oldver_b.decode("ascii", "ignore").strip() if oldver_b else "不明"
    secure = fat.find("/EFI/BOOT/grubx64_real.efi") is not None
    print(f"対象: {a.target}  MBR  p1_start={p1_start} p1_size={p1_size}  p2_start={p2_start} p2_size={p2_size}")
    print(f"Ventoy の版: {oldver} => {newver}   セキュアブート版: {'はい' if secure else 'いいえ'}")
    if not secure:
        die("セキュアブート版ではない(本物の更新は vtoycli partresize -s を呼ぶ。この手順では再現していない)")

    bdir = a.backup_dir or os.path.join(os.getcwd(), "ventoy-backup-" + time.strftime("%Y%m%d-%H%M%S"))
    if not a.apply:
        print(f"(--apply が無いので書き込まない。退避先の予定: {bdir})")
        return
    os.makedirs(bdir, exist_ok=False)
    open(os.path.join(bdir, "first-1MiB.bin"), "wb").write(head)
    open(os.path.join(bdir, "p2-32MiB.bin"), "wb").write(p2)
    json.dump({"target": a.target, "oldver": oldver, "newver": newver, "p2_start": p2_start,
               "sha256_first_1MiB": sha(head), "sha256_p2": sha(p2)}, open(os.path.join(bdir, "meta.json"), "w"))
    print("退避:", bdir)

    uuid = head[384:400]
    rsv = head[2040 * SECTOR:2048 * SECTOR]
    # 先頭 1MiB をメモリ上で組み立て、512 バイト境界でまとめて書く(/dev/rdisk は端数の書き込みができない)
    exp = bytearray(head)
    exp[0:440] = boot[:440]                      # boot.img の先頭 440 バイト
    exp[384:400] = uuid                          # ディスク UUID は保持
    swap = head[446] == 0x00 and head[462] == 0x80
    if swap:                                     # p1 が 00、p2 が 80 のときだけ入れ替え
        exp[446], exp[462] = 0x80, 0x00
    exp[SECTOR:SECTOR + len(core)] = core        # core.img: セクタ 1 から
    exp[2040 * SECTOR:2048 * SECTOR] = rsv       # 予約領域 2040-2047 は戻す
    write_at(f, 0, bytes(exp))
    write_at(f, p2_start * SECTOR, ven)          # VTOYEFI(第 2 パーティション)
    f.flush()
    os.fsync(f.fileno())

    # 読み戻し照合
    new_head = read_at(f, 0, 2048 * SECTOR)
    ok = True
    if bytes(exp) != new_head:
        print("失敗: 先頭 1MiB の読み戻しが期待と違う", file=sys.stderr)
        ok = False
    if read_at(f, p2_start * SECTOR, VENTOY_SECTOR_NUM * SECTOR) != ven:
        print("失敗: 第 2 パーティションの読み戻しが期待と違う", file=sys.stderr)
        ok = False
    # パーティションテーブル(active フラグを除く)が変わっていないこと
    keep = bytearray(new_head[446:510]); orig = bytearray(head[446:510])
    if swap:
        keep[0], keep[16] = orig[0], orig[16]
    if keep != orig:
        print("失敗: パーティションテーブルが変わった", file=sys.stderr)
        ok = False
    print("完了: 読み戻し照合 OK" if ok else "完了したが照合に失敗")
    sys.exit(0 if ok else 3)


if __name__ == "__main__":
    main()
