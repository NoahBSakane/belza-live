#!/usr/bin/env python3
"""層 squashfs の棚卸し: 展開ツリーと pf メタデータを突き合わせて JSONL を作る。

使い方:
  inventory.py SQUASHFS TAG OUTDIR STAGEDIR
    STAGEDIR に full 展開し(呼び出し側で用意・削除)、OUTDIR に
    <TAG>.jsonl と <TAG>.pf(メタデータ部のみ)、<TAG>.stats を書く。

JSONL 1 行の形式:
  {"p": 相対パス, "t": "f|d|l|c|b|i|s",
   "mode": int, "uid": int, "gid": int, "mtime": int,
   "size": int, "sha256": hex or null, "target": str or null,
   "dev": [major, minor] or null, "nlink": int, "grp": int or null,
   "x": {xattr名: 値(hex)} }

同一性判定に使う項目は p・t・内容(sha256/target/dev)・mode・uid・
gid・x で、時刻は報告用にのみ記録する。ハードリンク(grp)は共有から
除外するための材料である。
"""
import hashlib
import json
import os
import re
import stat
import subprocess
import sys


def split_pf_line(line):
    # パス中の空白は \ でエスケープされるため、種別トークンを右から探す。
    # 戻り値 (path_escaped, kind, rest)。見つからなければ None。
    best = None
    for kind in ("D", "R", "C", "B", "S", "I", "x", "L"):
        j = 0
        while True:
            j = line.find(" " + kind + " ", j)
            if j < 0:
                break
            path, rest = line[:j], line[j + 3:]
            if kind in ("D", "R", "C", "B", "S", "I"):
                if not re.match(r"^[0-9]+ [0-9]+ ", rest):
                    j += 1
                    continue
            if kind == "x" and "=" not in rest.split(" ", 1)[0]:
                j += 1
                continue
            if best is None or j > best[0]:
                best = (j, path, kind, rest)
            j += 1
    if best is None:
        return None
    return best[1], best[2], best[3]


def unescape_pf(s):
    # \\ -> \, \<c> -> <c>、\ooo -> 8 進数文字。
    out = []
    i = 0
    while i < len(s):
        c = s[i]
        if c == "\\" and i + 1 < len(s):
            n = s[i + 1]
            if n in "01234567":
                m = re.match(r"[0-7]{1,3}", s[i + 1:])
                out.append(chr(int(m.group(0), 8)))
                i += 1 + len(m.group(0))
            else:
                out.append(n)
                i += 2
        else:
            out.append(c)
            i += 1
    return "".join(out)


def escape_pf(path, quote):
    # 疑似ファイル用のエスケープ。引用なしでは unsquashfs -pf と同じ
    # 規則(空白も \ で逃がす)。引用ありでは空白は生のままとする。
    out = []
    for c in path:
        o = ord(c)
        if c == "\\":
            out.append("\\\\")
        elif c == " " and not quote:
            out.append("\\ ")
        elif c == '"' and quote:
            out.append('\\"')
        elif o < 0x20 or o == 0x7F:
            out.append("\\%03o" % o)
        else:
            out.append(c)
    s = "".join(out)
    if quote and (" " in path or '"' in path):
        s = '"%s"' % s
    return s


def pf_metadata(sqfs):
    p = subprocess.run(["unsquashfs", "-pf", "-", sqfs],
                       capture_output=True)
    if p.returncode != 0:
        raise RuntimeError("unsquashfs -pf failed for %s: %s"
                           % (sqfs, p.stderr[:500]))
    data = p.stdout
    i = data.find(b"# START OF DATA")
    meta = data[:i] if i >= 0 else data
    rec = {}
    for raw in meta.decode("utf-8", errors="surrogateescape").split("\n"):
        if not raw or raw.startswith("#"):
            continue
        sp = split_pf_line(raw)
        if sp is None:
            print("warn: unparsed pf line: %r" % raw[:120], file=sys.stderr)
            continue
        path, kind, rest = sp[0], sp[1], sp[2]
        path = unescape_pf(path)
        if path == "/":
            continue
        parts = rest.split(" ")
        if kind in ("D", "R"):
            rec.setdefault(path, {}).update(
                {"t": "d" if kind == "D" else "f",
                 "mtime": int(parts[0]), "mode": int(parts[1], 8),
                 "uid": int(parts[2]), "gid": int(parts[3])})
        elif kind in ("C", "B"):
            rec.setdefault(path, {}).update(
                {"t": "c" if kind == "C" else "b",
                 "mtime": int(parts[0]), "mode": int(parts[1], 8),
                 "uid": int(parts[2]), "gid": int(parts[3]),
                 "dev": [int(parts[4]), int(parts[5])]})
        elif kind == "S":
            rec.setdefault(path, {}).update(
                {"t": "l", "mtime": int(parts[0]),
                 "mode": int(parts[1], 8),
                 "uid": int(parts[2]), "gid": int(parts[3]),
                 "target": unescape_pf(" ".join(parts[4:]))})
        elif kind == "I":
            rec.setdefault(path, {}).update(
                {"t": "i", "mtime": int(parts[0]),
                 "mode": int(parts[1], 8),
                 "uid": int(parts[2]), "gid": int(parts[3]),
                 "sub": " ".join(parts[4:])})
        elif kind == "L":
            rec.setdefault(path, {}).update(
                {"linkto": unescape_pf(" ".join(parts[0:]))})
        elif kind == "x":
            name, _, val = parts[0].partition("=")
            rec.setdefault(path, {}).setdefault("x", {})[name] = val
    return rec, meta


def hash_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main(argv):
    if len(argv) != 4:
        print(__doc__, file=sys.stderr)
        return 2
    sqfs, tag, outdir, stagedir = argv
    os.makedirs(outdir, exist_ok=True)
    pf, meta = pf_metadata(sqfs)
    with open(os.path.join(outdir, tag + ".pf"), "wb") as f:
        f.write(meta)
    recs = {}
    inodes = {}
    for dirpath, dirnames, filenames in os.walk(stagedir,
                                                followlinks=False):
        for name in dirnames + filenames:
            full = os.path.join(dirpath, name)
            rel = os.path.relpath(full, stagedir)
            try:
                st = os.lstat(full)
            except FileNotFoundError:
                continue
            r = {"p": rel}
            if stat.S_ISDIR(st.st_mode):
                r["t"] = "d"
            elif stat.S_ISLNK(st.st_mode):
                r["t"] = "l"
                try:
                    r["target"] = os.readlink(full)
                except OSError:
                    r["target"] = None
            elif stat.S_ISREG(st.st_mode):
                r["t"] = "f"
                r["size"] = st.st_size
                key = (st.st_dev, st.st_ino)
                if key not in inodes:
                    inodes[key] = hash_file(full)
                r["ino"] = "%d:%d" % key
                r["sha256"] = inodes[key]
                r["nlink"] = st.st_nlink
            elif stat.S_ISCHR(st.st_mode):
                r["t"] = "c"
            elif stat.S_ISBLK(st.st_mode):
                r["t"] = "b"
            elif stat.S_ISFIFO(st.st_mode):
                r["t"] = "i"
            elif stat.S_ISSOCK(st.st_mode):
                r["t"] = "s"
            else:
                r["t"] = "?"
            r["nlink"] = st.st_nlink
            recs[rel] = r
    groups = {}
    for rel, r in recs.items():
        if r["t"] == "f" and r.get("nlink", 1) > 1:
            groups.setdefault(r["ino"], []).append(rel)
    gid_of = {}
    for i, members in enumerate(groups.values()):
        for m in members:
            gid_of[m] = i
    for rel, m in pf.items():
        if rel not in recs and m.get("t") in ("c", "b", "i", "s"):
            recs[rel] = {"p": rel, "t": m["t"], "nlink": 1}
    for rel, m in pf.items():
        if rel not in recs and "linkto" in m:
            recs[rel] = {"p": rel, "t": "l", "nlink": 2}
    for rel, m in pf.items():
        if "linkto" not in m:
            continue
        tgt = pf.get(m["linkto"], {})
        for k in ("mode", "uid", "gid", "mtime"):
            if k in tgt:
                m[k] = tgt[k]
            elif k in m:
                pass
    n_odd = 0
    missing = []
    with open(os.path.join(outdir, tag + ".jsonl"), "w",
              encoding="utf-8") as f:
        for rel in sorted(recs):
            r = recs[rel]
            m = pf.get(rel, {})
            if r["t"] == "f" and r.get("nlink", 1) > 1:
                r["grp"] = gid_of.get(rel)
            if any(ord(c) > 127 or c in ('"', "'", "\\", "\n", " ")
                   for c in rel):
                n_odd += 1
            entry = {
                "p": rel,
                "t": m.get("t", r["t"]),
                "mode": m.get("mode"),
                "uid": m.get("uid"),
                "gid": m.get("gid"),
                "mtime": m.get("mtime"),
                "size": r.get("size"),
                "sha256": r.get("sha256"),
                "target": m.get("target", r.get("target")),
                "dev": m.get("dev"),
                "nlink": r.get("nlink", 1),
                "grp": r.get("grp"),
                "x": m.get("x", {}),
            }
            if "linkto" in m:
                entry["linkto"] = m["linkto"]
            if "sub" in m:
                entry["sub"] = m["sub"]
            f.write(json.dumps(entry, ensure_ascii=True) + "\n")
            if entry["mode"] is None:
                missing.append(rel)
    missing = sorted(missing)
    stats = {"paths": len(recs), "pf_entries": len(pf),
             "odd_names": n_odd,
             "hardlink_groups": len(groups),
             "hardlinked_paths": sum(len(v) for v in groups.values()),
             "missing_meta": missing}
    if missing:
        print("FATAL: missing metadata for: %s" % missing[:10],
              file=sys.stderr)
        return 1
    with open(os.path.join(outdir, tag + ".stats"), "w") as f:
        json.dump(stats, f, indent=1)
    print("%s: %s" % (tag, json.dumps(stats)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
