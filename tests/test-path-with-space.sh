#!/bin/sh
# 空白・ピリオドを含むリポジトリのコピーで、ネットワーク不要の試験を実行する。
set -eu
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
# 一時領域をリポジトリ内に置いても、自分自身を再帰コピーしない。
# 隠しファイルを含むコピー元の一覧を、一時領域の作成前に確定する。
set -- "$HERE"/.[!.]* "$HERE"/..?* "$HERE"/*
WORK=$(mktemp -d "$HERE/test-path-with-space.XXXXXX")
pids=''
cleanup() {
    for pid in $pids; do wait "$pid" || :; done
    rm -rf "$WORK"
}
trap cleanup 0
trap 'exit 1' HUP INT TERM
COPY=$WORK/Noah\ B.\ Sakane/bootkit-linux
mkdir -p "$COPY"
for source do
    # 一致しなかった隠しファイルの glob は除く。壊れた symlink は保持する。
    # build/ は機械生成の大容量成果物で、空白パスの試験対象外のため除く。
    if [ "$source" = "$HERE/build" ]; then
        continue
    fi
    if [ -e "$source" ] || [ -L "$source" ]; then
        cp -R "$source" "$COPY/"
    fi
done
mkdir -p "$COPY/.test-tmp"
# 個々の試験が TMPDIR を使う場合も、必ず空白を含むコピー内で動かす。
TMPDIR=$COPY/.test-tmp
export TMPDIR
cd "$COPY"
tests='test-diag-packages.sh test-flavor-files.sh test-forky-hook.sh test-boot-config.sh test-survey.sh test-disk-guard.sh test-release-assets.sh'
for optional in test-additive.sh test-calamares-layers.sh test-installer-layer.sh test-installer-layer-mutations.sh test-layers.sh test-layer-mutations.sh test-ventoy-bundle.sh test-qemu-boot-args.sh test-ubuntu-merge.sh test-forky-deps.py; do
    if [ -f "tests/$optional" ]; then tests="$tests $optional"; fi
done
# 試験ごとの作業領域は独立。コピーの時間・容量はリポジトリの総容量に比例する。
for test in $tests; do
    (
        case "$test" in
            *.py) python3 "tests/$test" ;;
            *) sh "tests/$test" ;;
        esac
    ) > "$WORK/$test.log" 2>&1 &
    pids="$pids $!"
done
failed=0
for pid in $pids; do
    if ! wait "$pid"; then failed=1; fi
done
pids=''
for test in $tests; do
    printf '\n=== %s (空白・ピリオドを含むパス) ===\n' "$test"
    cat "$WORK/$test.log"
done
if [ "$failed" -ne 0 ]; then
    printf '%s\n' 'FAIL: 空白・ピリオドを含むパスで試験が失敗した' >&2
    exit 1
fi
printf '%s\n' 'ALL PASS: 空白・ピリオドを含むパスで既存の全試験が成功'
