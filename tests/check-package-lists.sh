#!/bin/sh
# Debian の公開索引で全フレーバーのパッケージ名を検査する。
# 使用法: tests/check-package-lists.sh [CACHE_DIR]
# CACHE_DIR 環境変数も使用可。省略時は一時キャッシュを終了時に削除する。
# キャッシュを更新するには、新しいディレクトリを指定する。
set -eu
if [ "$#" -gt 1 ]; then
    printf '%s\n' '使用法: tests/check-package-lists.sh [CACHE_DIR]' >&2
    exit 1
fi
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/check-package-lists.XXXXXX")
trap 'rm -rf "$WORK"' 0
trap 'exit 1' HUP INT TERM
CACHE_DIR=${1:-${CACHE_DIR:-$WORK/indexes}}
mkdir -p "$CACHE_DIR"
CACHE_DIR=$(CDPATH='' cd -- "$CACHE_DIR" && pwd)
for tool in curl xz awk; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        printf '検査できない: %s が必要です\n' "$tool" >&2
        exit 77
    fi
done

fetch_index() {
    arch=$1 area=$2
    index=$CACHE_DIR/trixie-$area-$arch-Packages.xz
    if [ -s "$index" ] && xz -t "$index" 2>/dev/null; then
        return 0
    fi
    # 途中までのダウンロードをキャッシュとして採用しない。
    partial=$WORK/$area-$arch.xz
    if ! curl --fail --location --silent --show-error \
        --connect-timeout 15 --max-time 180 --retry 2 \
        "https://deb.debian.org/debian/dists/trixie/$area/binary-$arch/Packages.xz" \
        -o "$partial"; then
        printf '検査できない: trixie/%s/binary-%s の索引を取得できません\n' "$area" "$arch" >&2
        return 77
    fi
    if ! xz -t "$partial"; then
        printf '検査できない: trixie/%s/binary-%s の索引が壊れています\n' "$area" "$arch" >&2
        return 77
    fi
    mv "$partial" "$index"
}

# 6 索引の転送は独立。各索引の走査は 1 回、照合はパッケージごとに定数時間。
pids=''
for arch in amd64 arm64; do
    for area in main contrib non-free-firmware; do
        fetch_index "$arch" "$area" &
        pids="$pids $!"
    done
done
unavailable=0
for pid in $pids; do
    if ! wait "$pid"; then unavailable=1; fi
done
[ "$unavailable" -eq 0 ] || exit 77
for arch in amd64 arm64; do
    : > "$WORK/$arch.packages"
    for area in main contrib non-free-firmware; do
        # 展開失敗をパイプラインの後段で隠さない。
        xz -dc "$CACHE_DIR/trixie-$area-$arch-Packages.xz" > "$WORK/Packages"
        awk '$1 == "Package:" { print $2 }' "$WORK/Packages" >> "$WORK/$arch.packages"
    done
done

mkdir -p "$WORK/bin" "$WORK/build"
printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/lb"
chmod +x "$WORK/bin/lb"
# auto/config が元の作業ツリーの生成物を消さないよう、コピーで実行する。
cp -R "$HERE/auto" "$HERE/config" "$WORK/build/"
failed=0
for flavor in cli lxqt icewm; do
    for arch in amd64 arm64; do
        (
            cd "$WORK/build"
            PATH="$WORK/bin:$PATH" FLAVOR=$flavor ARCH=$arch sh auto/config
        ) > "$WORK/auto-config.log" 2>&1 || {
            cat "$WORK/auto-config.log" >&2
            exit 1
        }
        if awk -v arch="$arch" -v flavor="$flavor" '
            FILENAME == ARGV[1] { available[$1] = 1; next }
            function fail(message) {
                print "FAIL: " flavor "/" arch " " FILENAME ":" FNR ": " message
                failed = 1
            }
            FNR == 1 {
                if (depth) fail("前のファイルの #endif がありません")
                depth = 0
                active[0] = 1
            }
            /^[[:space:]]*#if[[:space:]]/ {
                if ($2 != "ARCHITECTURES" || NF < 3) {
                    fail("未対応の条件: " $0)
                    next
                }
                matches = 0
                for (i = 3; i <= NF; i++) if ($i == arch) matches = 1
                depth++
                active[depth] = active[depth - 1] && matches
                branch[depth] = matches
                has_else[depth] = 0
                next
            }
            /^[[:space:]]*#else([[:space:]]|$)/ {
                if (!depth || has_else[depth] || NF != 1) fail("不正な #else")
                else {
                    active[depth] = active[depth - 1] && !branch[depth]
                    has_else[depth] = 1
                }
                next
            }
            /^[[:space:]]*#endif([[:space:]]|$)/ {
                if (!depth || NF != 1) fail("不正な #endif")
                else depth--
                next
            }
            {
                sub(/#.*/, "")
                if (!active[depth]) next
                for (i = 1; i <= NF; i++) {
                    if (!($i in available)) fail("パッケージが存在しません: " $i)
                    count++
                }
            }
            END {
                if (depth) fail("#endif がありません")
                if (!count) fail("パッケージ一覧が空です")
                if (failed) exit 1
                print "PASS: " flavor "/" arch " (" count " パッケージ指定)"
            }
        ' "$WORK/$arch.packages" "$WORK/build/config/package-lists/"*.list.chroot; then
            :
        else
            failed=1
        fi
    done
done
exit "$failed"
