#!/bin/sh
set -eu
HERE=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
RELEASE_ASSETS=${RELEASE_ASSETS:-$HERE/scripts/release-assets.sh}
T=$(mktemp -d "$HERE/.release-assets-test.XXXXXX")
trap 'find "$T" -depth -delete' EXIT HUP INT TERM
fail() { echo "FAIL: $*" >&2; exit 1; }
mkdir -p "$T/input/large" "$T/input/boundary"
python3 - "$T/input" <<'PY'
import pathlib
import sys
root = pathlib.Path(sys.argv[1])
# Distinct blocks ensure that reversed concatenation cannot pass.
with (root / 'large/bootkit-linux-amd64.iso').open('wb') as out:
    for block in range(5):
        out.write(bytes([block + 1]) * 1048576)
(root / 'boundary/bootkit-linux-arm64.iso').write_bytes(b'b' * 1048576)
PY
for dir in "$T/input"/*; do
    (cd "$dir" && sha256sum ./*.iso > SHA256SUMS)
done
RELEASE_MAX_BYTES=1048576 RELEASE_PART_BYTES=1048576 \
    sh "$RELEASE_ASSETS" "$T/input" "$T/output" \
    0123456789abcdef0123456789abcdef01234567 \
    https://github.com/example/bootkit-linux/actions/runs/123 "$T/notes.md"
set -- "$T/output/bootkit-linux-amd64.iso".part*
[ "$#" -eq 5 ] || fail 'Expected five parts for the 5 MiB ISO'
for part in "$@"; do
    [ "$(wc -c < "$part")" -le 1048576 ] || fail 'Part exceeds limit'
done
cat "$@" > "$T/reassembled.iso"
cmp "$T/input/large/bootkit-linux-amd64.iso" "$T/reassembled.iso" || fail 'Reassembly differs'
expected=$(sha256sum "$T/reassembled.iso")
grep -Fx "${expected%% *}  bootkit-linux-amd64.iso" "$T/output/SHA256SUMS" || fail 'Full ISO digest differs'
[ ! -e "$T/output/bootkit-linux-amd64.iso" ] || fail 'Oversized ISO attached'
cmp "$T/input/boundary/bootkit-linux-arm64.iso" "$T/output/bootkit-linux-arm64.iso"
[ ! -e "$T/output/bootkit-linux-arm64.iso.part00" ] || fail 'Boundary ISO was split'
[ "$(wc -l < "$T/output/SHA256SUMS")" -eq 2 ] || fail 'Expected two ISO digests'
[ "$(wc -l < "$T/output/SHA256SUMS.parts")" -eq 5 ] || fail 'Expected five part digests'
[ "$(find "$T/output" -type f | wc -l)" -eq 8 ] || fail 'Unexpected attachments'
(cd "$T/output" && sha256sum -c SHA256SUMS.parts)
grep -F '0123456789abcdef0123456789abcdef01234567' "$T/notes.md" >/dev/null
grep -F 'https://github.com/example/bootkit-linux/actions/runs/123' "$T/notes.md" >/dev/null
grep -F 'cat <名前>.iso.part* > <名前>.iso' "$T/notes.md" >/dev/null
for flavor in cli lxqt icewm; do
    grep -F -- "- $flavor:" "$T/notes.md" >/dev/null
done

# A below-limit ISO stays whole; both required architectures remain present.
printf 'small ISO\n' > "$T/input/large/bootkit-linux-amd64.iso"
(cd "$T/input/large" && sha256sum ./*.iso > SHA256SUMS)
RELEASE_MAX_BYTES=1048576 RELEASE_PART_BYTES=1048576 \
    sh "$RELEASE_ASSETS" "$T/input" "$T/small-output" commit url "$T/small-notes.md"
cmp "$T/input/large/bootkit-linux-amd64.iso" "$T/small-output/bootkit-linux-amd64.iso"
[ ! -s "$T/small-output/SHA256SUMS.parts" ] || fail 'Small ISO split unexpectedly'
mv "$T/input/boundary" "$T/saved-arm"
if sh "$RELEASE_ASSETS" "$T/input" "$T/missing-arch-output" commit url "$T/missing-arch.md" >/dev/null 2>&1; then
    fail 'Single architecture accepted'
fi
mv "$T/saved-arm" "$T/input/boundary"
mkdir "$T/input/obsolete"
printf 'old ISO\n' > "$T/input/obsolete/bootkit-linux-amd64-cli.iso"
if sh "$RELEASE_ASSETS" "$T/input" "$T/obsolete-output" commit url "$T/obsolete.md" >/dev/null 2>&1; then
    fail 'Obsolete flavor ISO accepted'
fi
rm -r "$T/input/obsolete"

# A fresh output directory is mandatory; stale parts must never be reused.
if sh "$RELEASE_ASSETS" "$T/input" "$T/output" commit url "$T/reused.md" 2>/dev/null; then
    fail 'Existing output directory accepted'
fi
mkdir "$T/empty"
if sh "$RELEASE_ASSETS" "$T/empty" "$T/empty-output" commit url "$T/empty.md" 2>/dev/null; then
    fail 'Missing ISO accepted'
fi
printf 'corrupt' >> "$T/input/boundary/bootkit-linux-arm64.iso"
if sh "$RELEASE_ASSETS" "$T/input" "$T/corrupt-output" commit url "$T/corrupt.md" >/dev/null 2>&1; then
    fail 'Corrupt input accepted'
fi
echo 'ALL PASS: split, reassembly, digests, size boundary, notes, and failure cases'
