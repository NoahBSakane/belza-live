#!/usr/bin/env python3
"""統合層の割り当てを決める。各 OS の平坦化ビューを突き合わせて
共有集合(C3/Cdl/Cds/Cls/固有)に分け、新層への配置と
ディレクトリのメタデータ競合解消(leaf への明示追加)を出力する。

使い方: plan.py INVDIR OUTDIR
  INVDIR の <tag>.jsonl を読み、OUTDIR に
    layers.json … 新層ごとの配置 {layer: {path: {..., src: {os: tag}}}}
    chains.json … OS ごとの層ファイル名の列
    report.txt … 数字の報告
  を書く。同一性判定に時刻は使わない。src はファイル実体の抽出元。
"""
import json
import os
import sys

LAYERS = {
    "ubuntu": ["d-minimal", "d-standard", "d-live"],
    "lubuntu": ["l-minimal", "l-standard", "l-live"],
    "server": ["s-minimal", "s-server", "s-installer", "s-generic"],
}
PRIORITY = ["ubuntu", "lubuntu", "server"]

NEW_LAYERS = ["common", "common.dl", "common.dl.ubuntu",
              "common.dl.lubuntu", "common.server"]
LEAF_OF = {"ubuntu": "common.dl.ubuntu", "lubuntu": "common.dl.lubuntu",
           "server": "common.server"}
CHAINS = {
    "ubuntu": ["common", "common.dl", "common.dl.ubuntu"],
    "lubuntu": ["common", "common.dl", "common.dl.lubuntu"],
    "server": ["common", "common.server"],
}


def load(invdir, tag):
    recs = {}
    with open(os.path.join(invdir, tag + ".jsonl"),
              encoding="utf-8") as f:
        for line in f:
            r = json.loads(line)
            recs[r["p"]] = (tag, r)
    return recs


def key_of(r):
    if r["t"] == "f":
        c = ("f", r.get("sha256"))
    elif r["t"] == "l":
        c = ("l", r.get("target") or r.get("linkto"))
    elif r["t"] in ("c", "b"):
        d = r.get("dev") or [0, 0]
        c = (r["t"], tuple(d))
    elif r["t"] == "d":
        c = ("d",)
    elif r["t"] in ("i", "s"):
        c = (r["t"], r.get("sub"))
    else:
        c = (r["t"], "?")
    return (c, r.get("mode"), r.get("uid"), r.get("gid"),
            tuple(sorted((r.get("x") or {}).items())))


def build_flat(inv, tags):
    # tags を下から重ねた勝者ビューと勝者タグ。非 dir の上層は
    # 下層サブツリーを隠す。戻り値 (view, wtag, shadowed)。
    view = {}
    wtag = {}
    for tag in tags:
        for p, (tg, r) in inv[tag].items():
            view[p] = r
            wtag[p] = tag
    nondirs = {p for p, r in view.items() if r["t"] != "d"}
    drop = []
    for q in view:
        parts = q.split("/")
        for i in range(1, len(parts)):
            if "/".join(parts[:i]) in nondirs:
                drop.append(q)
                break
    for q in drop:
        del view[q]
        del wtag[q]
    return view, wtag, len(drop)


def main(argv):
    invdir, outdir = argv
    os.makedirs(outdir, exist_ok=True)
    inv = {t: load(invdir, t) for tags in LAYERS.values() for t in tags}
    flat = {}
    winner_tag = {}
    for osname, tags in LAYERS.items():
        view, wtag, shadowed = build_flat(inv, tags)
        flat[osname] = view
        winner_tag[osname] = wtag
        print("%s flattened: %d paths" % (osname, len(view)))
        print("%s shadowed-out: %d" % (osname, shadowed))
    paths = set()
    for view in flat.values():
        paths |= set(view)
    assign = {}   # (os, path) -> 新層
    counts = {}
    dup_bytes = {"Cds": 0, "Cls": 0}
    shared_hl = 0
    dev_peer_target = set()  # (os, path): デバイスへのリンク先。peer と同居させる。
    for o in LAYERS:
        for p, r in flat[o].items():
            if r.get("linkto"):
                t = flat[o].get(r["linkto"], {})
                if t.get("t") in ("c", "b"):
                    dev_peer_target.add((o, p))
                    dev_peer_target.add((o, r["linkto"]))
    for p in paths:
        pres = {o: (p in flat[o]) for o in LAYERS}
        keys = {o: key_of(flat[o][p]) for o in LAYERS if pres[o]}
        kset = set(keys.values())
        nlink_any = any((flat[o][p].get("grp") is not None
                         or flat[o][p].get("linkto") is not None
                         or (o, p) in dev_peer_target)
                        for o in keys)
        in_all = all(pres.values()) and len(kset) == 1
        ul = (pres["ubuntu"] and pres["lubuntu"] and not pres["server"]
              and keys["ubuntu"] == keys["lubuntu"])
        us = (pres["ubuntu"] and pres["server"] and not pres["lubuntu"]
              and keys["ubuntu"] == keys["server"])
        ls = (pres["lubuntu"] and pres["server"] and not pres["ubuntu"]
              and keys["lubuntu"] == keys["server"])
        if in_all and not nlink_any:
            for o in keys:
                assign[(o, p)] = "common"
            counts["C3"] = counts.get("C3", 0) + 1
        elif ul and not nlink_any:
            for o in ("ubuntu", "lubuntu"):
                assign[(o, p)] = "common.dl"
            counts["Cdl"] = counts.get("Cdl", 0) + 1
        else:
            if us or ls:
                o0 = "ubuntu" if us else "lubuntu"
                if flat[o0][p].get("size"):
                    dup_bytes["Cds" if us else "Cls"] += flat[o0][p]["size"]
                k = "dup-" + ("Cds" if us else "Cls")
                counts[k] = counts.get(k, 0) + 1
            if nlink_any and (in_all or ul):
                shared_hl += 1
            for o in keys:
                assign[(o, p)] = LEAF_OF[o]
                counts["leaf-" + o] = counts.get("leaf-" + o, 0) + 1
    print("classes:", json.dumps(counts, sort_keys=True))
    print("dup uncompressed bytes:", json.dumps(dup_bytes, sort_keys=True),
          "hardlink-excluded:", shared_hl)
    members = {layer: {} for layer in NEW_LAYERS}
    for (o, p), layer in assign.items():
        members[layer][(o, p)] = flat[o][p]
    for layer in NEW_LAYERS:
        users = [o for o in PRIORITY
                 if any(k[0] == o for k in members[layer])]
        need_dirs = set()
        for (o, p) in members[layer]:
            parts = p.split("/")[:-1]
            for i in range(1, len(parts) + 1):
                need_dirs.add("/".join(parts[:i]))
        for d in sorted(need_dirs):
            for o in users:
                if (o, d) not in members[layer] and d in flat[o]:
                    members[layer][(o, d)] = flat[o][d]
    stored = {}   # (layer, path) -> {os: winner-record}
    topmost = {}  # (os, path) -> layer
    for o in PRIORITY:
        for layer in reversed(CHAINS[o]):
            for (oo, p), r in members[layer].items():
                if oo != o:
                    continue
                stored.setdefault((layer, p), {})[o] = flat[o][p]
                topmost.setdefault((o, p), layer)
    final = {}  # (layer, path) -> record
    extra_leaf = {o: {} for o in PRIORITY}
    for (layer, p), cand in stored.items():
        users = [o for o in PRIORITY if (o, p) in members[layer]]
        req = [o for o in users if topmost.get((o, p)) == layer]
        if not req:
            first = next(o for o in PRIORITY if o in cand)
            final[(layer, p)] = cand[first]
            continue
        first = next(o for o in PRIORITY if o in req)
        final[(layer, p)] = cand[first]
        for o in req:
            if o == first:
                continue
            if key_of(cand[o]) == key_of(cand[first]):
                continue
            extra_leaf[o][p] = cand[o]
    for o, dmap in extra_leaf.items():
        leaf = CHAINS[o][-1]
        for p, r in dmap.items():
            final[(leaf, p)] = r
            parts = p.split("/")[:-1]
            for i in range(1, len(parts) + 1):
                a = "/".join(parts[:i])
                if (leaf, a) not in final and a in flat[o]:
                    final[(leaf, a)] = flat[o][a]
    print("explicit leaf additions:",
          {o: len(v) for o, v in extra_leaf.items()})
    layers_out = {}
    for layer in NEW_LAYERS:
        items = {}
        for (ly, p), r in final.items():
            if ly != layer:
                continue
            src = {}
            for o in PRIORITY:
                if (o, p) in members[layer]:
                    src[o] = winner_tag[o][p]
            items[p] = {"os": sorted(src), "src": src,
                        "t": r["t"], "mode": r["mode"], "uid": r["uid"],
                        "gid": r["gid"], "mtime": r["mtime"],
                        "size": r.get("size"), "sha256": r.get("sha256"),
                        "target": r.get("target"), "dev": r.get("dev"),
                        "sub": r.get("sub"), "linkto": r.get("linkto"),
                        "x": r.get("x", {})}
        layers_out[layer] = items
        print("%s: %d paths" % (layer, len(items)))
    with open(os.path.join(outdir, "layers.json"), "w") as f:
        json.dump(layers_out, f, indent=1, ensure_ascii=True)
    with open(os.path.join(outdir, "chains.json"), "w") as f:
        json.dump(CHAINS, f, indent=1)
    with open(os.path.join(outdir, "ochains.json"), "w") as f:
        json.dump(LAYERS, f, indent=1)
    with open(os.path.join(outdir, "report.txt"), "w") as f:
        f.write("classes: %s\n" % json.dumps(counts, sort_keys=True))
        f.write("dup_bytes: %s\n" % json.dumps(dup_bytes, sort_keys=True))
        f.write("hardlink_excluded: %d\n" % shared_hl)
        f.write("explicit_leaf: %s\n"
                % json.dumps({o: len(v) for o, v in extra_leaf.items()},
                             sort_keys=True))
        for layer in NEW_LAYERS:
            f.write("%s: %d\n" % (layer, len(layers_out[layer])))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
