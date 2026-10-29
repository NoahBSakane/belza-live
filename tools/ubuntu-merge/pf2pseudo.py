#!/usr/bin/env python3
"""unsquashfs -pf メタデータ部から mksquashfs -pf 疑似ファイルを生成する。

使い方: pf2pseudo.py [--exclude-file EXCL] IN.pfmeta OUT.pseudo
  IN.pfmeta は `unsquashfs -pf -` の出力全体(バイナリ部つき可)。
  展開時に除くパス(デバイスとそのハードリンク)を EXCL に書く。

規則(根拠は docs/ubuntu-merge.md の方式メモ):
- D/R/S 行 -> M 行(時刻・モード・所有者で上書き。S は展開物があるため)
- C/B 行 -> そのまま(デバイスは展開せず疑似で作る)
- x 行 -> そのまま
- L 行(ハードリンク): 参照先が C/B(デバイス)の場合は mksquashfs の
  L 行(疑似へのリンク)として残し、展開除外に加える。通常 inode への
  L はホスト展開のハードリンクを活かすため M 行に変換する。
  メタデータは参照先の主エントリから取る。
- I 行(fifo/socket): 展開物があれば M、なければ I のまま残す。
- 先頭 '/' の根エントリは除外する(root は -force-uid/-force-gid で付与)。
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__))))
from inventory import escape_pf, split_pf_line, unescape_pf  # noqa: E402


def parse_args(argv):
    excl = None
    rest = []
    it = iter(argv)
    for a in it:
        if a == "--exclude-file":
            excl = next(it)
        else:
            rest.append(a)
    return excl, rest


def main(argv):
    excl_path, rest = parse_args(argv)
    if len(rest) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    src, dst = rest
    with open(src, "rb") as f:
        data = f.read()
    mark = b"# START OF DATA"
    i = data.find(mark)
    meta = data[:i] if i >= 0 else data
    text = meta.decode("utf-8", errors="surrogateescape")
    primary = {}  # path -> (kind, time, mode, uid, gid)
    order = []
    for line in text.split("\n"):
        if not line or line.startswith("#"):
            continue
        sp = split_pf_line(line)
        if sp is None:
            print("warn: unparsed: %r" % line[:120], file=sys.stderr)
            continue
        path, kind, restline = sp[0], sp[1], sp[2]
        path = unescape_pf(path)
        if path == "/":
            continue
        fields = restline.split(" ")
        if kind in ("D", "R", "C", "B", "S", "I"):
            primary.setdefault(path, (kind,) + tuple(fields[:4]))
        order.append((path, kind, fields))
    out = []
    excl = []
    for path, kind, fields in order:
        if kind in ("D", "R"):
            out.append("%s M %s %s %s %s" % (escape_pf(path, True),
                                             fields[0], fields[1],
                                             fields[2], fields[3]))
        elif kind in ("C", "B"):
            out.append("%s %s %s" % (escape_pf(path, True), kind,
                                    " ".join(fields[:6])))
            excl.append(escape_pf(path, False))
        elif kind == "S":
            out.append("%s M %s %s %s %s" % (escape_pf(path, True),
                                            fields[0], fields[1],
                                            fields[2], fields[3]))
        elif kind == "x":
            out.append("%s x %s" % (escape_pf(path, True),
                                    " ".join(fields)))
        elif kind == "L":
            target = unescape_pf(" ".join(fields))
            tk = primary.get(target, ("?",))[0]
            if tk in ("C", "B"):
                out.append("%s L %s" % (escape_pf(path, True),
                                       escape_pf(target, False)))
                excl.append(escape_pf(path, False))
            else:
                tinfo = primary.get(target)
                if tinfo is None or len(tinfo) < 5:
                    print("warn: no primary for %r" % path[:120],
                          file=sys.stderr)
                    continue
                out.append("%s M %s %s %s %s" % (escape_pf(path, True),
                                                tinfo[1], tinfo[2],
                                                tinfo[3], tinfo[4]))
        elif kind == "I":
            out.append("%s I %s" % (escape_pf(path, True), " ".join(fields)))
            print("warn: fifo/socket kept as-is: %r" % path[:120],
                  file=sys.stderr)
        else:
            print("warn: unknown kind: %r" % path[:120], file=sys.stderr)
    with open(dst, "w", encoding="utf-8",
              errors="surrogateescape") as f:
        f.write("\n".join(out) + "\n")
    if excl_path is not None:
        with open(excl_path, "w", encoding="utf-8",
                  errors="surrogateescape") as f:
            f.write("\n".join(excl) + ("\n" if excl else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
