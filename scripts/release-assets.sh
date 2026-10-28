#!/bin/sh
# Usage: release-assets.sh INPUT_DIR OUTPUT_DIR COMMIT BUILD_RUN_URL NOTES_FILE
# INPUT_DIR contains one artifact directory per ISO. OUTPUT_DIR must not exist.
set -eu
export LC_ALL=C

die() { echo "$*" >&2; exit 1; }
[ "$#" -eq 5 ] || die 'Expected INPUT_DIR OUTPUT_DIR COMMIT BUILD_RUN_URL NOTES_FILE'
input=$(cd "$1" && pwd)
output=$2
commit=$3
run_url=$4
notes=$5
limit=${RELEASE_MAX_BYTES:-2147483648}
part_bytes=${RELEASE_PART_BYTES:-1992294400}
for number in "$limit" "$part_bytes"; do
    case "$number" in ''|*[!0-9]*) die 'Size limits must be positive integers';; esac
    [ "$number" -gt 0 ] || die 'Size limits must be positive integers'
done
[ "$limit" -le 2147483648 ] || die 'Release limit exceeds 2 GiB'
[ "$part_bytes" -le "$limit" ] || die 'Part size exceeds release limit'
[ "$part_bytes" -le 1992294400 ] || die 'Part size exceeds 1900 MiB'
mkdir "$output"
output=$(cd "$output" && pwd)
: > "$output/SHA256SUMS"
: > "$output/SHA256SUMS.parts"
count=0
for iso in "$input"/*/*.iso; do
    [ -f "$iso" ] || continue
    name=${iso##*/}
    case "$name" in
        bootkit-linux-amd64.iso|bootkit-linux-arm64.iso) ;;
        *) die "Unexpected ISO name: $name" ;;
    esac
    if grep -Fq "  $name" "$output/SHA256SUMS"; then die "Duplicate ISO: $name"; fi
    # Check each downloaded artifact before building the combined manifest.
    (cd "${iso%/*}" && sha256sum -c SHA256SUMS)
    digest=$(sha256sum "$iso")
    printf '%s  %s\n' "${digest%% *}" "$name" >> "$output/SHA256SUMS"
    size=$(wc -c < "$iso")
    if [ "$size" -gt "$limit" ]; then
        [ "$size" -le "$((part_bytes * 100))" ] || die 'Two-digit part suffixes are insufficient'
        if [ "$part_bytes" -eq 1992294400 ]; then
            split -b 1900M -d -a 2 "$iso" "$output/$name.part"
        else
            split -b "$part_bytes" -d -a 2 "$iso" "$output/$name.part"
        fi
        (cd "$output" && sha256sum "$name".part*) >> "$output/SHA256SUMS.parts"
    else
        cp "$iso" "$output/$name"
    fi
    count=$((count + 1))
done
[ "$count" -eq 2 ] || die 'Expected exactly two ISO artifacts (amd64 and arm64)'
for asset in "$output"/*; do
    [ "$(wc -c < "$asset")" -le "$limit" ] || die "Oversized asset: $asset"
done

cat > "$notes" <<EOF
## フレーバー

- cli: コマンドラインの診断・救出環境。
- lxqt: 診断ツールに LXQt と Calamares を追加。
- icewm: 診断ツールに軽量な IceWM を追加。

amd64 と arm64 の ISO を1つずつ用意しています。各 ISO の起動メニューで選択し、既定は icewm です。
Debian Installer の Start installer は cli 基本層だけを導入します。

## ダウンロードと検証

2 GiB (2147483648 バイト)を超える ISO は、1 ファイル最大 1900 MiB に分割しています。
必要な ISO の part ファイルをすべて同じディレクトリへ保存し、番号順に結合してください。
以下の「<名前>」は、ダウンロードした ISO の名前(拡張子の手前まで)に置き換えます。

\`\`\`sh
sha256sum --ignore-missing -c SHA256SUMS.parts
cat <名前>.iso.part* > <名前>.iso
sha256sum --ignore-missing -c SHA256SUMS
\`\`\`

SHA256SUMS は結合後の完全な ISO、SHA256SUMS.parts は各分割ファイルの SHA-256 です。
分割されていない ISO は、そのまま SHA256SUMS で検証できます。
検証結果で、使う ISO と、その全 part ファイルが OK になったことを確かめてください。
macOS では sha256sum の代わりに shasum -a 256 -c を使えます(必要なファイルの行だけをチェックサム一覧から選びます)。

ビルドしたコミット: \`$commit\`

[build-iso の実行]($run_url) (この実行の build ジョブ)
EOF
