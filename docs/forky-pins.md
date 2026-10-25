# forky から限定して入れる複製ツール

確認日: 2026-10-25。対象: Debian 13(trixie)を基盤とする全フレーバー、amd64 / arm64。

## 選定結果

forky の `partclone`・`clonezilla`・`drbl` の Depends / Pre-Depends をたどると、trixie に追加するライブラリは `libntfs-3g91` だけで足りる。`libisal2`・`liburcu8t64`・`libxxhash0` は partclone の新しい依存だが、trixie に要件を満たす版があるため、forky からは入れない。

| パッケージ | trixie | forky | 採用元 |
| --- | --- | --- | --- |
| clonezilla | 5.9.9-1 | 5.19.7-1 | forky |
| drbl | 5.4.10-1 | 5.11.15-1 | forky |
| partclone | 0.3.36+repack-1 | 0.3.49-1+b1 | forky |
| libntfs-3g91 | なし | 1:2026.9.28-2 | forky |
| libisal2 | 2.31.1-1.1 | 2.31.1-3 | trixie |
| liburcu8t64 | 0.15.2-2 | 0.15.7-1 | trixie |
| libxxhash0 | 0.8.3-2 | 0.8.3-2+b2 | trixie |
| libc6 | 2.41-12+deb13u4 | 2.43-7 | trixie |
| procps | 2:4.0.4-9 | 2:4.0.7-1 | trixie |

表の版は amd64 / arm64 で共通。partclone の上流版は 0.3.49 であり、Clonezilla Live 3.3.3 の partclone 0.3.50 と同一ではない。0.3.50 の Btrfs 修正まで含むとは扱わない。

## 直接依存と再帰検査

- partclone の Depends: `libblkid1 (>= 2.17.2), libc6 (>= 2.38), libext2fs2t64 (>= 1.42), libisal2 (>= 2.19.0), libncursesw6 (>= 6), libntfs-3g91, libssl3t64 (>= 3.0.0), libtinfo6 (>= 6), liburcu8t64 (>= 0.13.0), libuuid1 (>= 2.16), libxxhash0 (>= 0.8.0)`。
- clonezilla の Depends: `drbl, file, pigz, pixz, gdisk, bc, dialog, fdisk | util-linux (>= 2.40), e2fsprogs, parted, python3, procps`。
- drbl の Depends: `perl, bash (>= 5.2), ipcalc, bc, fdisk, e2fsprogs, syslinux-common, procps`。
- libntfs-3g91 の Depends: `libc6 (>= 2.38)`。

`libntfs-3g91` の依存は `libc6 (>= 2.38)` だけで、trixie の `2.41-12+deb13u4` で満たせる。Clonezilla・DRBL の `procps` も trixie から入る。

`tests/check-forky-deps.py` は両リリースの main 索引を各 1 回読み、まずツール 3 つだけを forky に置換し、trixie で満たせない依存を再帰的に求め、必要な追加ライブラリと限定リストの一致を検査する。そのうえで限定リスト内は forky、ほかは trixie の候補を作る。Depends / Pre-Depends の代替条件・版条件・仮想パッケージの Provides を評価し、選んだ依存先を重複なく再帰走査する。索引の読込みは総サイズに比例し、走査は訪問したパッケージ数と依存条件数に比例する。今回の結果は amd64 が 94 パッケージ・246 条件、arm64 が 93 パッケージ・244 条件で成功した。基盤ライブラリを forky へ更新する必要はない。

候補内に満たせる依存がない場合、限定リストを自動で拡大せず失敗する。未知の依存式も失敗する。これは公開索引の依存条件の検査であり、APT による競合・インストール順序の解決や ISO の実ビルド・起動を検証するものではない。

## live-build と APT の設定

trixie の索引で確認した live-build は `1:20250505+deb13u1`。その [Debian パッケージ](https://deb.debian.org/debian/pool/main/l/live-build/live-build_20250505+deb13u1_all.deb)を curl で取得し、ar と tar で展開して実装を読んだ。

`usr/share/live/build/functions/packages.sh` の `Check_package_available` は、`apt-cache show "^<pkg>$"` の `Package:` 行がちょうど 1 行の場合だけ利用可能と判定する。trixie と forky を常設すると、同名の複数版が 2 行になり、インストーラーの部品選択が壊れる。amd64 では `libfuse3-4` の代わりに存在しない `libfuse3-3` を選んで失敗し、arm64 の GRUB 部品も判定から外れるおそれがある。

そのため `config/archives/` に forky を置かず、通常のパッケージ一覧では `clonezilla`・`partclone` を trixie から入れる。`auto/config` は全フレーバー・全アーキテクチャで `config/hooks/live/0400-forky-clonezilla.hook.chroot` を生成する。対象名は `config/forky-packages.txt` だけで管理し、hook の処理本体は `auto/forky-hook.sh` に置く。

hook 内だけで forky の取得元と pin を追加する。既定優先度は 100、限定リストだけ 990 とし、`apt-get update` の後に `apt-get install -y -t forky` に一覧の名前を渡す。導入後は、各パッケージの dpkg の版が `apt-cache policy` の forky の版と一致することを検査する。`-t` による依存先への波及も検出するため、`libc6`・`libc-bin`・`libsystemd0`・`libudev1`・`systemd`・`udev`・`apt`・`dpkg` の導入前後の版が同一であることを確認し、違えばビルドを止める。

終了時の trap は、成功・失敗のどちらでも取得元・pin・forky の索引を削除し、`apt-get update` と `apt-get clean` を実行する。後始末が失敗した場合もビルドを失敗させる。hook 終了後は forky を APT の取得元に残さない。

## 再検査

```sh
sh tests/check-package-lists.sh
sh tests/test-flavor-files.sh
sh tests/test-forky-hook.sh
python3 -B tests/test-forky-deps.py
```

公開索引は更新されるため、版の固定ではなく対象名の限定である。検査は現在の公開索引で行い、取得不能時の終了コードは 77。索引を再利用する場合は `sh tests/check-package-lists.sh CACHE_DIR`。新しいディレクトリを指定すると索引を更新する。フレーバーの検査は全 6 構成の hook 生成と構文、別スイートの常設禁止を検査する。hook の試験では偽の APT を使い、pin 100 / 990、正常更新、更新なし、基盤の版の変更、取得・導入・照合・後始末の失敗を区別し、いずれでも取得元・pin・索引の削除と clean の実行を検査する。

## 索引の出典

以下の Debian 公開索引を直接取得した。SHA-256 は確認時の圧縮ファイルの値。

- [trixie/main/binary-amd64/Packages.xz](https://deb.debian.org/debian/dists/trixie/main/binary-amd64/Packages.xz): `7778d3e3f303b7ddb8ce0fe7c8d57473a076c6bf2e8f241f75421d2396352498`。
- [trixie/main/binary-arm64/Packages.xz](https://deb.debian.org/debian/dists/trixie/main/binary-arm64/Packages.xz): `be16b37b2f740f066ea93d35d56f04f94d63693e5a3eb421b052bf86fae75bcd`。
- [forky/main/binary-amd64/Packages.xz](https://deb.debian.org/debian/dists/forky/main/binary-amd64/Packages.xz): `dfc14d8a15bb4830c5152293691cc375f8010d1821805b11a6229abfdd079dc1`。
- [forky/main/binary-arm64/Packages.xz](https://deb.debian.org/debian/dists/forky/main/binary-arm64/Packages.xz): `edb06276e373431e90dc4c305547657ce0c4e19db21ff8011709f1d29391bf0d`。
