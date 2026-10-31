#!/bin/sh
# Server の autoinstall 用の seed (CIDATA) と標的ディスクを作る。
# 作業ツリー内にだけ書く。使い回しできるよう冪等にする。
set -eu
HERE=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
DIR="$HERE/build/evidence/offline-install/server"
mkdir -p "$DIR"

# テスト VM 専用の固定パスワード ubuntu のハッシュ (salt 固定で再現可能)。
PASS='$6$abcd1234$3VkCBTg3.kJfjQlZtE6c.gM8RuE1btCYFy9NBcRKfJzZFcwMykT.KWwtTO3QbMMS8kdR9VKXJH0kj8jsRvmR/1'

cat >"$DIR/user-data" <<EOF
#cloud-config
autoinstall:
  version: 1
  locale: en_US
  keyboard: {layout: us}
  identity: {hostname: ubuntu-server, username: ubuntu, password: '$PASS'}
  ssh: {install-server: false, allow-pw: true}
  storage: {layout: {name: direct}}
  network: {network: {version: 2}}
  apt: {preserve_sources_list: false}
  updates: security
  packages: []
  snaps: []
  refresh-installer: {update: no}
  shutdown: poweroff
EOF
printf 'instance-id: offline-server-01\nlocal-hostname: ubuntu-server\n' >"$DIR/meta-data"

xorriso -as mkisofs -o "$DIR/seed.iso" -V CIDATA -J -r \
  -graft-points "user-data=$DIR/user-data" "meta-data=$DIR/meta-data" \
  >"$DIR/seed-mkisofs.log" 2>&1
xorriso -indev "$DIR/seed.iso" -pvd_info -- 2>&1 | grep -i -E "volume id|label" | head -3

# 第2版: legacy 項目 (cp:///media/filesystem) 用に live ルートを束縛する。
# 統合 ISO の /casper に install-sources.yaml が無いための代替。
cp "$DIR/user-data" "$DIR/user-data.bind"
cp "$DIR/meta-data" "$DIR/meta-data.bind"
cat >>"$DIR/user-data.bind" <<'EOF'
  # 設置の供給源にする (legacy 項目の /media/filesystem の代替)。
EOF
python3 -I - "$DIR/user-data.bind" <<'EOF'
import sys
path = sys.argv[1]
text = open(path).read()
anchor = "autoinstall:\n"
bootcmd = ("bootcmd:\n"
           "  - mkdir -p /media/filesystem\n"
           "  - mount --bind / /media/filesystem\n")
assert anchor in text and "bootcmd:" not in text
open(path, "w").write(text.replace(anchor, bootcmd + anchor))
EOF
xorriso -as mkisofs -o "$DIR/seed-bind.iso" -V CIDATA -J -r \
  -graft-points "user-data=$DIR/user-data.bind" "meta-data=$DIR/meta-data.bind" \
  >"$DIR/seed-bind-mkisofs.log" 2>&1

if [ ! -f "$DIR/server-target.qcow2" ]; then
  qemu-img create -f qcow2 "$DIR/server-target.qcow2" 20G
fi
ls -lh "$DIR"
