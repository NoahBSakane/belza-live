#!/bin/sh
# 統合層ツール群の軽量試験。実 ISO は使わず、小さな合成 squashfs で
# 往復・分割・検証の対照試験を行う。
set -eu
HERE=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
TOOLS=$HERE/tools/ubuntu-merge
WORK=$(mktemp -d "$HERE/test-results.XXXXXX")
trap 'rm -rf "$WORK"' 0
trap 'exit 1' HUP INT TERM
cd "$WORK"
export LC_ALL=C

# 1. 合成ツリーを作る(通常ファイル・空 dir・symlink・空白名)。
mkdir -p src/etc src/usr/share/fonts
echo hello > src/etc/motd
printf 'A%.0s' $(seq 1 100) > src/etc/big.bin
ln -s ../etc/motd src/usr/link1
ln -s /nonexistent src/usr/dangle
touch src/usr/share/fonts/a
mkdir -p "src/sp ace"
echo "sp ace" > "src/sp ace/f ile.txt"
mksquashfs src o1.squashfs -comp xz -b 131072 -no-progress > /dev/null

# 2. 棚卸し→疑似→再構成→再棚卸しでビューが一致すること。
mkdir -p st1
unsquashfs -no-xattrs -no-wildcards -f -d st1 o1.squashfs > /dev/null
python3 -I "$TOOLS/inventory.py" o1.squashfs L1 inv st1
mkdir -p st2
unsquashfs -no-xattrs -no-wildcards -f -d st2 o1.squashfs > /dev/null
python3 -I "$TOOLS/inventory.py" o1.squashfs L1b inv st2
cmp inv/L1.jsonl inv/L1b.jsonl
cat > check_pf.py <<'PYEOF'
import subprocess, sys
def pfmeta(sqfs):
    p = subprocess.run(["unsquashfs", "-pf", "-", sqfs], capture_output=True)
    data = p.stdout
    i = data.find(b"# START OF DATA")
    meta = data[:i] if i >= 0 else data
    lines = []
    for ln in meta.split(b"\n"):
        if ln.startswith(b"#"):
            continue
        parts = ln.split(b" ")
        if len(parts) < 2:
            continue
        if parts[0] == b"/":
            continue
        if parts[1] in (b"D", b"R"):
            lines.append(b" ".join([parts[0], b"M"] + parts[2:6]))
        else:
            lines.append(ln)
    return sorted(lines)
a, b = pfmeta(sys.argv[1]), pfmeta(sys.argv[2])
if a != b:
    print("PF-DIFF orig=%d new=%d" % (len(a), len(b)))
    for ln in sorted(set(a) - set(b))[:10]:
        print("ONLY-ORIG", ln[:160])
    for ln in sorted(set(b) - set(a))[:10]:
        print("ONLY-NEW", ln[:160])
    sys.exit(1)
print("PF-MATCH %d" % len(a))
PYEOF

# 3. pf2pseudo 往復: 除外なし・全量展開→再構成で pf が一致すること。
unsquashfs -pf - o1.squashfs > o1.pfmeta 2>/dev/null
python3 -I "$TOOLS/pf2pseudo.py" --exclude-file excl.txt o1.pfmeta o1.pseudo
test ! -s excl.txt
mksquashfs st2 o2.squashfs -comp xz -b 131072 \
    -force-uid 0 -force-gid 0 -pseudo-override -pf o1.pseudo \
    -xattrs-exclude '^com\.apple\.' -e '.DS_Store' -no-progress > /dev/null
python3 -I "$WORK/check_pf.py" o1.squashfs o2.squashfs

# 4. 検証器の対照試験: 同一なら成功、改変したら失敗すること。
mkdir -p newdir
cp o1.squashfs newdir/L1.squashfs
printf '{"t": ["L1"]}\n' > chains.json
python3 -I "$TOOLS/verify.py" inv chains.json newdir chains.json vw1
if python3 -I "$TOOLS/verify.py" inv chains.json newdir chains.json vw1 2>/dev/null; then
    : # 2 回目も成功(冪等)
else
    echo "FAIL: verify should pass on identical layers" >&2; exit 1
fi
# 改変層(1 バイト追加)は不一致になること。
mkdir -p mod && cp -r st2 mod/src && echo x >> mod/src/etc/motd
mksquashfs mod/src mod.squashfs -comp xz -b 131072 -no-progress > /dev/null
mkdir -p newdir2 && cp mod.squashfs newdir2/L1.squashfs
if python3 -I "$TOOLS/verify.py" inv chains.json newdir2 chains.json vw2 2>/dev/null; then
    echo "FAIL: verify should fail on tampered layer" >&2; exit 1
fi

# 5. plan の単体試験: 共有判定と shadow 除外。
mkdir -p pinv
for t in d-minimal d-standard d-live l-minimal l-standard l-live s-minimal s-server s-installer s-generic; do : > pinv/$t.jsonl; done
python3 -I - <<'PYEOF' > pinv/d-minimal.jsonl
import json
def r(p, t="f", sha="a", mode=644, uid=0, gid=0, mtime=1000, target=None):
    return {"p": p, "t": t, "mode": mode, "uid": uid, "gid": gid,
            "mtime": mtime, "size": 1, "sha256": sha, "target": target,
            "dev": None, "nlink": 1, "grp": None, "x": {}}
recs = [r("sh/common.txt", sha="c0ffee"),
        r("only-u.txt", sha="u1"),
        r("sh/sub/deep.txt", sha="deep"),
        r("etc/motd", sha="v1")]
print("\n".join(json.dumps(x) for x in recs))
PYEOF
python3 -I - <<'PYEOF' > pinv/d-standard.jsonl
import json
def r(p, t="f", sha="a", mode=644, uid=0, gid=0, mtime=2000, target=None):
    return {"p": p, "t": t, "mode": mode, "uid": uid, "gid": gid,
            "mtime": mtime, "size": 1, "sha256": sha, "target": target,
            "dev": None, "nlink": 1, "grp": None, "x": {}}
recs = [r("sh", t="l", target="elsewhere"),
        r("etc/motd", sha="v2")]
print("\n".join(json.dumps(x) for x in recs))
PYEOF
python3 -I - <<'PYEOF' > pinv/l-minimal.jsonl
import json
def r(p, t="f", sha="a", mode=644, uid=0, gid=0, mtime=1000, target=None):
    return {"p": p, "t": t, "mode": mode, "uid": uid, "gid": gid,
            "mtime": mtime, "size": 1, "sha256": sha, "target": target,
            "dev": None, "nlink": 1, "grp": None, "x": {}}
recs = [r("sh/common.txt", sha="c0ffee"),
        r("sh/only-l.txt", sha="l1")]
print("\n".join(json.dumps(x) for x in recs))
PYEOF
python3 -I "$TOOLS/plan.py" pinv pplan
# sh は ubuntu の上層で symlink が勝つため下層サブツリーは隠れる。
# common.txt は lubuntu だけに残り、C3 にならない。
python3 -I - <<'PYEOF'
import json
layers = json.load(open("pplan/layers.json"))
assert "sh/common.txt" not in layers["common"], "shadowed file leaked to common"
assert "sh/common.txt" not in layers["common.dl.ubuntu"], "ubuntu must not have shadowed file"
assert "sh/common.txt" in layers["common.dl.lubuntu"], "lubuntu copy missing"
assert "only-u.txt" in layers["common.dl.ubuntu"]
assert "sh/only-l.txt" in layers["common.dl.lubuntu"]
assert "sh/sub/deep.txt" not in layers["common.dl.ubuntu"], "shadowed deep file leaked"
assert "etc/motd" in layers["common.dl.ubuntu"]
print("plan unit OK")
PYEOF
echo "PASS: ubuntu-merge synthetic roundtrip"
