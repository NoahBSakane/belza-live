#!/usr/bin/env python3
"""layers.json に従って新層 squashfs を再構成する。

使い方: repack.py LAYERSJSON ORIGDIR STAGEBASE OUTDIR
  ORIGDIR の <tag>.squashfs から必要分だけ部分展開し、
  STAGEBASE/repack_<layer> を経て OUTDIR/<layer>.squashfs を作る。
  ついでに <layer>.pseudo と <layer>.excl も OUTDIR に残す。

方式(根拠は docs/ubuntu-merge.md の方式メモ):
- case-sensitive な staging が前提。
- 実体は unsquashfs 部分展開(親ディレクトリは自動生成。
  デバイスとそのハードリンク・ソケットは含めない)。
- 不足する空ディレクトリは mkdir -p で足す。
- メタデータは M 行、xattr は x 行、デバイスは C/B 行、
  デバイスへのハードリンクは L 行、ソケットは I 行で付与する。
- mksquashfs -comp xz -b 131072 -force-uid 0 -force-gid 0
  -pseudo-override で所有者を再現する。
"""
import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__))))
from inventory import escape_pf  # noqa: E402

COMP = "xz"
BS = "131072"
EXCLUDES = ["^.DS_Store", "^.fseventsd", "^.Spotlight-V100", "^.Trashes",
            "^com\\.apple\\."]


def run(cmd):
    p = subprocess.run(cmd, capture_output=True, text=True)
    if p.returncode != 0:
        raise RuntimeError("failed: %s\n%s" % (" ".join(cmd), p.stderr[-2000:]))
    return p


def main(argv):
    layers_json, origdir, stagebase, outdir = argv
    with open(layers_json, encoding="utf-8") as f:
        layers = json.load(f)
    os.makedirs(outdir, exist_ok=True)
    for layer in sorted(layers):
        items = layers[layer]
        stage = os.path.join(stagebase, "repack_" + layer)
        run(["rm", "-rf", stage])
        os.makedirs(stage)
        by_tag = {}
        pseudo_m = []
        pseudo_x = []
        pseudo_c = []
        bare_dirs = []
        socks = []
        for p in sorted(items):
            r = items[p]
            t = r["t"]
            if t == "d":
                bare_dirs.append(p)
                continue
            if t in ("c", "b"):
                dev = r["dev"] or [0, 0]
                pseudo_c.append((p, 0, "%s %s %d %o %d %d %d %d"
                                 % (escape_pf(p, True), t.upper(),
                                    r["mtime"], r["mode"], r["uid"], r["gid"],
                                    dev[0], dev[1])))
                continue
            if t == "s":
                socks.append("%s I %d %o %d %d s"
                             % (escape_pf(p, True), r["mtime"], r["mode"],
                                r["uid"], r["gid"]))
                continue
            if t == "l" and r.get("linkto"):
                tgt = items.get(r["linkto"], {})
                if tgt.get("t") in ("c", "b"):
                    pseudo_c.append((p, 1, "%s L %s"
                                     % (escape_pf(p, True),
                                        escape_pf(r["linkto"], False))))
                    continue
            src = r["src"]
            tag = min(src.values(),
                      key=lambda tg: (0 if tg.startswith("d-") else
                                      1 if tg.startswith("l-") else 2, tg))
            by_tag.setdefault(tag, []).append(p)
            # M 行は raw パス順(親が子より先)で出す。子より後だと
            # mksquashfs が自動生成の親と「違う定義」とみなし無視する。
            pseudo_m.append((p, "%s M %d %o %d %d"
                             % (escape_pf(p, True), r["mtime"], r["mode"],
                                r["uid"], r["gid"])))
            for xn, xv in sorted((r.get("x") or {}).items()):
                pseudo_x.append("%s x %s=%s" % (escape_pf(p, True), xn, xv))
        for p in bare_dirs:
            r = items[p]
            pseudo_m.append((p, "%s M %d %o %d %d"
                             % (escape_pf(p, True), r["mtime"], r["mode"],
                                r["uid"], r["gid"])))
            for xn, xv in sorted((r.get("x") or {}).items()):
                pseudo_x.append("%s x %s=%s" % (escape_pf(p, True), xn, xv))
            full = os.path.join(stage, p)
            os.makedirs(full, exist_ok=True)
        for tag in sorted(by_tag):
            lst = os.path.join(stagebase, "repack_%s.%s.list" % (layer, tag))
            with open(lst, "w", encoding="utf-8",
                      errors="surrogateescape") as f:
                for p in by_tag[tag]:
                    # -no-wildcards では素のパスを書く(エスケープ不要)。
                    if "\n" in p:
                        raise RuntimeError("newline in path: %r" % p[:80])
                    f.write(p + "\n")
            sqfs = os.path.join(origdir, tag + ".squashfs")
            run(["unsquashfs", "-no-xattrs", "-no-wildcards", "-f", "-d",
                 stage, "-extract-file", lst, sqfs])
        pseudo_path = os.path.join(outdir, layer + ".pseudo")
        with open(pseudo_path, "w", encoding="utf-8",
                  errors="surrogateescape") as f:
            for _, ln in sorted(pseudo_m):
                f.write(ln + "\n")
            for ln in pseudo_x:
                f.write(ln + "\n")
            for _, _, ln in sorted(pseudo_c):
                f.write(ln + "\n")
            for ln in socks:
                f.write(ln + "\n")
        out = os.path.join(outdir, layer + ".squashfs")
        if os.path.exists(out):
            os.remove(out)
        cmd = ["mksquashfs", stage, out, "-comp", COMP, "-b", BS,
               "-force-uid", "0", "-force-gid", "0", "-pseudo-override",
               "-pf", pseudo_path, "-no-progress"]
        for pat in ["^.DS_Store", "^.fseventsd", "^.Spotlight-V100",
                    "^.Trashes"]:
            cmd += ["-e", pat]
        cmd += ["-xattrs-exclude", "^com\\.apple\\."]
        p = run(cmd)
        print("built %s (%d paths)" % (layer, len(items)))
        run(["rm", "-rf", stage])
        for tag in by_tag:
            lst = os.path.join(stagebase, "repack_%s.%s.list" % (layer, tag))
            if os.path.exists(lst):
                os.remove(lst)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
