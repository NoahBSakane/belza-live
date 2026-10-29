#!/usr/bin/env python3
"""新層の連鎖を重ねたビューと本物の全層ビューの同一性を検証する。

使い方: verify.py ORIGINV ORIGCHAINS NEWDIR NEWCHAINS WORKDIR
  ORIGINV: 本物層の <tag>.jsonl がある場所
  ORIGCHAINS: 本物の連鎖定義(OS -> [tag...])の JSON
  NEWDIR: 新層の <layer>.squashfs がある場所(ISO から取り出した物でも可)
  NEWCHAINS: 新層の連鎖定義(OS -> [layer...])の JSON
  WORKDIR: 作業場所(新層の展開・棚卸しに使う)

比較項目: パス集合・種別・モード・所有者・xattr・リンク先・通常ファ
イルの SHA-256・デバイス番号。時刻は数えるだけで合否に使わない。
差があれば一覧(先頭 50 件)を出して exit 1。
"""
import json
import os
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__))))
from plan import LAYERS, build_flat, key_of  # noqa: E402


def load_jsonl(path, tag):
    recs = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            r = json.loads(line)
            recs[r["p"]] = (tag, r)
    return recs


def main(argv):
    originv, origchains, newdir, newchains, workdir = argv
    with open(origchains, encoding="utf-8") as f:
        ochains = json.load(f)
    with open(newchains, encoding="utf-8") as f:
        chains = json.load(f)
    inv = {}
    for tags in ochains.values():
        for t in tags:
            if t not in inv:
                inv[t] = load_jsonl(os.path.join(originv, t + ".jsonl"), t)
    orig_flat = {}
    for osname, tags in ochains.items():
        view, _, _ = build_flat(inv, tags)
        orig_flat[osname] = view
    newinv = dict(inv)
    newtags = set()
    for osname, chain in chains.items():
        for layer in chain:
            newtags.add(layer)
    def rm_force(p):
        def fix(func, path, info):
            try:
                if func in (os.rmdir, os.remove, os.unlink):
                    os.chmod(os.path.dirname(path) or ".", 0o755)
                os.chmod(path, 0o755)
            except OSError:
                pass
            try:
                func(path)
            except OSError:
                pass
        if os.path.isdir(p) and not os.path.islink(p):
            for dp, dns, fns in os.walk(p, followlinks=False):
                for n in dns + fns:
                    try:
                        os.chmod(os.path.join(dp, n), 0o755)
                    except OSError:
                        pass
            try:
                os.chmod(p, 0o755)
            except OSError:
                pass
            shutil.rmtree(p, onerror=fix)
        else:
            os.remove(p)
    if os.path.exists(workdir):
        for name in os.listdir(workdir):
            if name.startswith("verify-"):
                rm_force(os.path.join(workdir, name))
    else:
        os.makedirs(workdir)
    stagedir = os.path.join(workdir, "verify-stage")
    sys.path.insert(0, os.path.join(
        os.path.dirname(os.path.abspath(__file__))))
    from pf2pseudo import main as pfmain
    from inventory import pf_metadata
    for layer in sorted(newtags):
        sqfs = os.path.join(newdir, layer + ".squashfs")
        dest = os.path.join(workdir, "verify-inv")
        os.makedirs(dest, exist_ok=True)
        stage = os.path.join(stagedir, layer)
        if os.path.exists(stage):
            shutil.rmtree(stage)
        os.makedirs(stage)
        excl = os.path.join(workdir, "verify-%s.excl" % layer)
        pf, meta = pf_metadata(sqfs)
        pfonly = os.path.join(workdir, "verify-%s.pf" % layer)
        with open(pfonly, "wb") as f:
            f.write(meta)
        pseudo0 = os.path.join(workdir, "verify-%s.pseudo0" % layer)
        pfmain(["--exclude-file", excl, pfonly, pseudo0])
        ex = [l.strip() for l in open(excl, encoding="utf-8")
              if l.strip()] if os.path.exists(excl) else []
        cmd = ["unsquashfs", "-no-xattrs", "-f", "-d", stage]
        if ex:
            cmd += ["-exclude-file", excl]
        cmd += [sqfs]
        subprocess.run(cmd, check=True)
        from inventory import main as invmain
        rc = invmain([sqfs, layer, dest, stage])
        if rc != 0:
            print("FATAL: inventory of %s failed" % layer)
            return 2
        shutil.rmtree(stage, ignore_errors=True)
        for tmp in (pfonly, pseudo0, excl):
            if os.path.exists(tmp):
                os.remove(tmp)
        newinv[layer] = load_jsonl(os.path.join(dest, layer + ".jsonl"),
                                    layer)
    failed = 0
    for osname in chains:
        if osname not in orig_flat:
            print("no orig view for %s" % osname)
            failed += 1
            continue
        oview = orig_flat[osname]
        nview, _, _ = build_flat(newinv, chains[osname])
        only_o = sorted(set(oview) - set(nview))
        only_n = sorted(set(nview) - set(oview))
        diffs = []
        timediffs = 0
        for p in sorted(set(oview) & set(nview)):
            a, b = oview[p], nview[p]
            if key_of(a) != key_of(b):
                diffs.append((p, a, b))
            elif a.get("mtime") != b.get("mtime"):
                timediffs += 1
        print("== %s: orig=%d new=%d only-orig=%d only-new=%d "
              "content-diffs=%d time-diffs=%d"
              % (osname, len(oview), len(nview),
                 len(only_o), len(only_n), len(diffs), timediffs))
        for p in only_o[:25]:
            print("  ONLY-ORIG %s" % p)
        for p in only_n[:25]:
            print("  ONLY-NEW %s" % p)
        for p, a, b in diffs[:25]:
            print("  DIFF %s" % p)
            print("    orig: %s" % json.dumps(a, sort_keys=True)[:300])
            print("    new : %s" % json.dumps(b, sort_keys=True)[:300])
        if only_o or only_n or diffs:
            failed += 1
    if failed:
        print("VERIFY FAILED: %d os differ" % failed)
        return 1
    print("VERIFY OK: %d os identical" % len(chains))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
