#!/bin/sh
# Portable control tests; auto/layers check repeats them with real Linux nodes.
set -eu
HERE=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d "$HERE/test-additive.XXXXXX")
trap 'rm -rf "$WORK"' 0
trap 'exit 1' HUP INT TERM
mkdir -p "$WORK/bin" "$WORK/layer"
cat > "$WORK/bin/find" <<'STUB'
#!/bin/sh
# Execute the real scanner's -exec body, replacing only the device source.
[ "$2 $3 $4 $5 $6" = '-type c -exec sh -c' ] || exit 2
sh -c "$7" sh "$1/device"
STUB
cat > "$WORK/bin/stat" <<'STUB'
#!/bin/sh
case "$SCAN_MODE" in whiteout) echo '0:0';; stat-fail) exit 1;; *) echo '1:3';; esac
STUB
cat > "$WORK/bin/getfattr" <<'STUB'
#!/bin/sh
case "$SCAN_MODE" in
    opaque) printf '%s\n' '# file: directory' 'trusted.overlay.opaque="y"' ;;
    user-whiteout) printf '%s\n' '# file: deleted' 'user.overlay.whiteout="y"' ;;
    attr-fail) exit 1 ;;
esac
exit 0
STUB
chmod +x "$WORK/bin/"*
for mode in clean whiteout opaque user-whiteout stat-fail attr-fail; do
    status=0
    PATH="$WORK/bin:$PATH" TMPDIR=$WORK SCAN_MODE=$mode sh "$HERE/auto/assert-additive" "$WORK/layer" > "$WORK/output" 2>&1 || status=$?
    if [ "$mode" = clean ]; then
        [ "$status" = 0 ] || { cat "$WORK/output"; exit 1; }
    else
        [ "$status" != 0 ] || { echo "FAIL: accepted $mode" >&2; exit 1; }
    fi
    echo "PASS: additive scan $mode (status $status)"
done
# Opaque marks are stripped where the base lacks the path, rejected where it has it.
mkdir -p "$WORK/ostub" "$WORK/lower/kept/sub" "$WORK/upper/kept/sub" "$WORK/upper/fresh"
cat > "$WORK/ostub/getfattr" <<'STUB'
#!/bin/sh
case "$4" in */upper/kept/sub|*/upper/fresh) exit 0 ;; esac
exit 1
STUB
cat > "$WORK/ostub/setfattr" <<'STUB'
#!/bin/sh
echo "$4" >> "$STRIP_LOG"
STUB
chmod +x "$WORK/ostub/"*
STRIP_LOG=$WORK/strip.log PATH="$WORK/ostub:$PATH" \
    sh "$HERE/auto/strip-new-opaque" "$WORK/lower" "$WORK/upper" 2> "$WORK/opaque.err" || status=$?
[ "${status:-0}" != 0 ] || { echo 'FAIL: opaque directory over a base path accepted' >&2; exit 1; }
grep -q 'replaces a base path: /kept/sub' "$WORK/opaque.err"
echo 'PASS: opaque directory over a base path rejected'
rm -f "$WORK/strip.log"
rmdir "$WORK/lower/kept/sub"
STRIP_LOG=$WORK/strip.log PATH="$WORK/ostub:$PATH" \
    sh "$HERE/auto/strip-new-opaque" "$WORK/lower" "$WORK/upper"
grep -q '/upper/kept/sub$' "$WORK/strip.log" && grep -q '/upper/fresh$' "$WORK/strip.log"
echo 'PASS: opaque marks on new directories stripped'
