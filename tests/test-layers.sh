#!/bin/sh
# Portable checks; actual squashfs/overlay isolation runs in the binary hook.
set -eu
HERE=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d "$HERE/test-layers.XXXXXX")
trap 'rm -rf "$WORK"' 0
trap 'exit 1' HUP INT TERM
for script in auto/build auto/layers; do bash -n "$HERE/$script"; done
for script in auto/modules auto/flavor; do sh -n "$HERE/$script"; done
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck "$HERE/auto/build" "$HERE/auto/layers" "$HERE/auto/modules" "$HERE/auto/flavor"
fi
sh "$HERE/auto/modules" generate "$WORK/live"
for image in filesystem 10-icewm 10-lxqt; do printf 'fake\n' > "$WORK/live/$image.squashfs"; done
sh "$HERE/auto/modules" check "$WORK/live"
# Each malformed manifest must fail independently.
for condition in missing-base missing-delta reversed extra-layer absent-image; do
    sh "$HERE/auto/modules" generate "$WORK/live"
    case "$condition" in
        missing-base) printf '10-icewm.squashfs\n' > "$WORK/live/icewm.module" ;;
        missing-delta) printf 'filesystem.squashfs\n' > "$WORK/live/icewm.module" ;;
        reversed) printf '10-lxqt.squashfs\nfilesystem.squashfs\n' > "$WORK/live/lxqt.module" ;;
        extra-layer) printf '10-lxqt.squashfs\n' >> "$WORK/live/icewm.module" ;;
        absent-image) rm "$WORK/live/10-lxqt.squashfs" ;;
    esac
    if sh "$HERE/auto/modules" check "$WORK/live" > "$WORK/$condition.log" 2>&1; then
        echo "FAIL: accepted $condition" >&2; exit 1
    fi
    printf 'fake\n' > "$WORK/live/10-lxqt.squashfs"
    echo "PASS: rejected $condition"
done
# Verify real stage orchestration, including failure propagation through tee.
mkdir -p "$WORK/build/auto" "$WORK/bin"
cp "$HERE/auto/build" "$WORK/build/auto/"
cat > "$WORK/bin/lb" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$STAGES"
[ "$1" != "${FAIL_STAGE:-}" ]
STUB
cat > "$WORK/build/auto/layers" <<'STUB'
#!/bin/sh
printf '%s\n' layers >> "$STAGES"
STUB
chmod +x "$WORK/bin/lb" "$WORK/build/auto/layers"
STAGES=$WORK/stages; export STAGES
(cd "$WORK/build" && PATH="$WORK/bin:$PATH" bash auto/build)
printf '%s\n' bootstrap chroot layers installer binary source > "$WORK/expected"
cmp "$STAGES" "$WORK/expected"
: > "$STAGES"
if (cd "$WORK/build" && PATH="$WORK/bin:$PATH" FAIL_STAGE=chroot bash auto/build); then
    echo 'FAIL: swallowed lb failure' >&2; exit 1
fi
printf '%s\n' bootstrap chroot > "$WORK/expected"
cmp "$STAGES" "$WORK/expected"
echo 'ALL PASS: modules, layer syntax, build stages and failure propagation'
