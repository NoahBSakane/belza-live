# アーキテクチャごとの統合 ISO

amd64 と arm64 に各1つの ISO を作る。起動時に IceWM(既定)・CLI・LXQt を選び、GUI の差分層は同時に1つだけ重ねる。

| 選択 | `/live/` 内の module ファイル(最下層から順) |
| --- | --- |
| `module=cli` | `cli.module`: `filesystem.squashfs` |
| `module=icewm` | `icewm.module`: `filesystem.squashfs`、`10-icewm.squashfs` |
| `module=lxqt` | `lxqt.module`: `filesystem.squashfs`、`10-lxqt.squashfs` |

## ビルドと層の条件

`auto/build` は `lb bootstrap` → `lb chroot` → `auto/layers build` → `lb installer` → `lb binary` → `lb source` の順に実行する。`auto/config` は CLI だけを構成し、`auto/flavor` が従来と同じ GUI パッケージ・includes・IceWM hook を生成する。

`auto/layers` は、CLI chroot を lowerdir とする overlayfs に GUI を導入する。redirect・metacopy・index を無効にし、root で upperdir を xattr 付きの SquashFS に圧縮する。whiteout(文字デバイス 0/0)と opaque ディレクトリを残し、dpkg 状態も差分側に保持する。基本 chroot は変更しない。ビルド用の `/dev`・`/proc`・`/sys`・`/run` は別マウントとし、サービスの自動起動を抑止する。APT キャッシュ・索引・ログは空にし、差分の `/boot` は除外する。カーネルと initrd は CLI 基本層のものだけを使う。

live-build は `binary_rootfs` の後、チェックサム・ISO 作成の前に binary hook を実行する。`0900-layers.hook.binary` で `.layers/images/` の差分・module・GUI パッケージ一覧を `binary/live/` にコピーする。基本 squashfs は live-build が作るため、差分生成時にはまだ不要。再ビルドで入力を変更する場合は live-build の既存ステージキャッシュも消して作り直す。

## 起動とインストール

Debian 13 の live-boot は `module=NAME` を解析し、`/live/filesystem.NAME.module`、`/live/NAME.module` の順で探す。空白・改行区切りで読み、順にマウントした一覧を逆順の lowerdir にするため、一覧の最後が最上層になる。すべての Live 項目に `module=` を付け、一覧がない場合の全 squashfs 自動列挙を避ける。既存の toram は IceWM、safe・survey・fail-safe は CLI を選ぶ。BIOS は IceWM にだけ `menu default`、GRUB は `default=0` と先頭の IceWM を使う。

d-i の live-installer は `/cdrom/live/filesystem.squashfs` の固定名を対象にし、module 一覧を読まない。そのため `Start installer` は CLI 固定。LXQt に Calamares は残すが、統合構成での導入は未検証。

## 検証と後続作業

`make test` は module の名前・順序・層の存在、ビルド順序と失敗の伝播、起動項目と既定を通信なしで検査する。層欠落・逆順・余計な層・既定変更の壊した版も非0で落ちることを確かめる。

CI の特権コンテナでは binary hook が実際の squashfs を再マウントし、各 module の icewm/startlxqt の有無を検査する。さらに合成した whiteout・opaque を同じ圧縮・再マウント経路で検査し、失敗した ISO は完成させない。これは起動試験の代用ではない。初回 CI 後に、amd64 BIOS/UEFI と arm64 UEFI の3系統、toram、d-i の CLI 導入、Calamares を QEMU で確認する。メニュー階層化・USB の旧 ISO 削除は後続作業。

統合版の容量・時間は未実測。容量は基本圧縮層 C と GUI 差分 I・L、起動部 H の和 `C + I + L + H`。処理量は基本構築1回と各 GUI の導入・圧縮の和で、独立した3回の基本構築を避ける。ディスク使用量には基本 chroot、live-build の作業コピー、最大1つの展開差分、差分の保持・binary コピー・完成 ISO、APT キャッシュが加わる。`build.log` にステージ別の秒数と差分サイズを記録し、初回 CI の完成 ISO とディスク使用量で見積もりを更新する。

## 確認した一次ソース

- [live-boot(7), trixie](https://manpages.debian.org/trixie/live-boot-doc/live-boot.7.en.html): `module=NAME` と `/live`。
- live-boot `1:20250815~deb13u1`: [9990-cmdline-old](https://sources.debian.org/src/live-boot/1%3A20250815~deb13u1/components/9990-cmdline-old/)、[9990-overlay.sh](https://sources.debian.org/src/live-boot/1%3A20250815~deb13u1/components/9990-overlay.sh/)、[9990-misc-helpers.sh](https://sources.debian.org/src/live-boot/1%3A20250815~deb13u1/components/9990-misc-helpers.sh/)。引数解析・一覧読込・層順・既定 overlay。
- live-build `1:20250505+deb13u1`: [build](https://sources.debian.org/src/live-build/1%3A20250505%2Bdeb13u1/scripts/build/build/)、[binary](https://sources.debian.org/src/live-build/1%3A20250505%2Bdeb13u1/scripts/build/binary/)、[binary_hooks](https://sources.debian.org/src/live-build/1%3A20250505%2Bdeb13u1/scripts/build/binary_hooks/)、[binary_grub_cfg](https://sources.debian.org/src/live-build/1%3A20250505%2Bdeb13u1/scripts/build/binary_grub_cfg/)。ステージ順・hook の実行場所・テンプレート変数。
- [live-installer 58, support/squashfs](https://sources.debian.org/src/live-installer/58/support/squashfs/): d-i の固定名。
