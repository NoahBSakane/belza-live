#!/bin/sh
set -eu
HERE=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d "$HERE/test-calamares.XXXXXX")
trap 'rm -rf "$WORK"' 0
trap 'exit 1' HUP INT TERM
for flavor in lxqt icewm cli lxqt cli; do
    sh "$HERE/auto/flavor" "$flavor" "$WORK"
    config=$WORK/config/includes.chroot/etc/calamares/modules/unpackfs.conf
    if [ "$flavor" = lxqt ]; then
        python3 - "$config" <<'PY'
from pathlib import Path
import re
import sys
text = Path(sys.argv[1]).read_text()
assert re.findall(r'source: "([^"]+)"', text) == [
    '/run/live/medium/live/filesystem.squashfs',
    '/run/live/medium/live/10-lxqt.squashfs']
assert text.count('sourcefs: "squashfs"') == 2
assert text.count('destination: ""') == 2
for path in ('/boot', '/etc/fstab', '/etc/crypttab', '/etc/default/locale',
             '/var/cache/apt', '/var/lib/apt/lists', '/var/log'):
    assert '"' + path + '"' in text
PY
    else
        [ ! -e "$config" ] || { echo 'FAIL: Calamares config outside LXQt' >&2; exit 1; }
    fi
done
echo 'ALL PASS: LXQt-only Calamares base/delta order and exclusions'
