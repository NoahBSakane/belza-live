# アーキテクチャごとの統合 ISO

amd64 と arm64 に各1つの ISO を作る。起動時に IceWM(既定)・CLI・LXQt を選び、GUI の差分層は同時に1つだけ重ねる。

| 選択 | `/live/` 内の module ファイル(最下層から順) |
| --- | --- |
| `module=cli` | `cli.module`: `filesystem.squashfs` |
| `module=icewm` | `icewm.module`: `filesystem.squashfs`、`10-icewm.squashfs` |
| `module=lxqt` | `lxqt.module`: `filesystem.squashfs`、`10-lxqt.squashfs` |

## ビルドと層の条件

`auto/build` は `lb bootstrap` → `lb chroot` → `auto/layers build` → `lb installer` → `lb binary` → `lb source` の順に実行する。`auto/config` は CLI だけを構成し、`auto/flavor` が従来と同じ GUI パッケージ・includes・IceWM hook を生成する。

`auto/layers` は、CLI chroot を lowerdir とする overlayfs に GUI を導入する。redirect・metacopy・index を無効にし、root で upperdir を xattr 付きの SquashFS に圧縮する。層は追加・上書きだけとし、whiteout(文字デバイス 0/0)と opaque ディレクトリがあればビルドを失敗させる。dpkg 状態は基本と GUI を含む全体を差分側に保持する。基本 chroot は変更しない。ビルド用の `/dev`・`/proc`・`/sys`・`/run` は別マウントとし、サービスの自動起動を抑止する。APT キャッシュ・索引・ログは空にし、差分の `/boot` は除外する。カーネルと initrd は CLI 基本層のものだけを使う。

live-build は `binary_rootfs` の後、チェックサム・ISO 作成の前に binary hook を実行する。`0900-layers.hook.binary` で `.layers/images/` の差分・module・GUI パッケージ一覧を `binary/live/` にコピーする。基本 squashfs は live-build が作るため、差分生成時にはまだ不要。再ビルドで入力を変更する場合は live-build の既存ステージキャッシュも消して作り直す。

## 起動とインストール

Debian 13 の live-boot は `module=NAME` を解析し、`/live/filesystem.NAME.module`、`/live/NAME.module` の順で探す。空白・改行区切りで読み、順にマウントした一覧を逆順の lowerdir にするため、一覧の最後が最上層になる。すべての Live 項目に `module=` を付け、一覧がない場合の全 squashfs 自動列挙を避ける。toram・safe・survey・fail-safe は既定の IceWM を選ぶ。BIOS は IceWM にだけ `menu default`、GRUB は `default=0` と先頭の IceWM を使う。

## 層の移植

d-i の live-installer は `/cdrom/live/filesystem.squashfs` の固定名を対象にし、module 一覧を読まない。GUI をネットワークから再取得する代わりに、ISO 内の差分層を追加コピーする。`Start installer (icewm|lxqt|cli)` が `bootkit.flavor=` を渡し、`00bootkit-layer` が `10-<flavor>.squashfs` を read-only loop マウントする。live-installer 58 の基本コピーの後、network・openssh-server・ssl-cert・initramfs-tools の各 hook とユーザー作成より前に実行する。この時点なら passwd/group/shadow と dpkg 状態を GUI 層の全体で上書きできる。58 の実装は `run-parts` コマンドではなく、名前順のループで実行可能ファイルを呼ぶ。

`config/includes.installer/usr/lib/live-installer.d/00bootkit-layer` は、live-build の `Repack_initrd` が includes の内容を `cpio -pumd0` で initrd のルートへ追加する経路で収録する。対象のパスと実行権を保つ。基本コピーと同じ POSIX sh・tar と、`attr-udeb` 依存の getfattr/setfattr を使い、hardlink・symlink・mode・所有者と、ACL/capabilities を含む xattr を移す。udeb では tar の除外オプション・stat・mkfifo が無効なため、find で除外済みの非重複ルート一覧を作り、tar の1回の呼出に渡す。デバイス番号は ls -ln で調べ、FIFO は mknod の p 型で作る。一覧から外した祖先ディレクトリの mode と所有者も明示的に復元する。tar は FIFO を介し、作成側・展開側の終了状態を両方確認する。展開用の巨大な tar を RAM に保存しない。

除外するのは `/boot`・`/etc/fstab`・`/etc/crypttab`・`/etc/default/locale`・`/var/cache/apt`・`/var/lib/apt/lists`・`/var/log`。installer の対象ディスク構成・ロケールと、その後の kernel/initrd の生成を守る。xattr の移植からも同じパスを除く。コピー前に文字デバイス 0/0 と overlay の opaque/whiteout 属性を拒否する。ビルド時も、除外するキャッシュ等の upper エントリーを除去してから `auto/assert-additive` で検査し、圧縮後の再マウントでも検査する。削除を必要とする GUI パッケージ変更は、この方式ではビルド失敗になる。

引数なし・cli・未知の値では何もしない。層欠落・マウント失敗・whiteout/opaque・属性読出失敗では、CLI のまま終了コード0で継続する。画面と `/var/log/syslog` にフレーバー・層のバイト数・経過秒・理由を記録する。コピー開始後の障害では完全な CLI へのロールバックは行わず、一部適用の可能性を警告する。終了時はアンマウントし、一時ディレクトリを削除する。アンマウントに失敗した場合は、マウント先を削除せず警告して保持する。

LXQt 層だけで `/etc/calamares/modules/unpackfs.conf` を配置し、`calamares-settings-debian` 13.0.13 の同じファイルを GUI パッケージ導入後に置き換える。CLI・IceWM 層には配置しない。Debian の単一 entry と同じ媒体パスを使い、基本 → `10-lxqt.squashfs` の2 entry を順に展開する。2番目の entry にも同じ除外を指定する。他の Calamares のユーザー作成・kernel・bootloader の設定は Debian パッケージのまま使う。

## 検証と後続作業

`make test` は module の名前・順序・層の存在、ビルド順序と失敗の伝播、起動項目と既定を通信なしで検査する。層欠落・逆順・余計な層・既定変更の壊した版も非0で落ちることを確かめる。

CI の特権コンテナでは binary hook が実際の squashfs を再マウントし、各 module の icewm/startlxqt の有無を検査する。さらに本物の文字デバイス 0/0 と opaque 属性を別々に作り、自己検査が各条件を拒否することを確認する。失敗した ISO は完成させない。これは起動試験の代用ではない。初回 CI 後に、amd64 BIOS/UEFI と arm64 UEFI の3系統、toram、d-i の3フレーバー導入と Calamares を [QEMU 手順](installer-verification.md)で確認する。USB の旧 ISO 削除はその後の作業。

統合版の容量・時間は未実測。容量は基本圧縮層 C と GUI 差分 I・L、起動部 H の和 `C + I + L + H`。処理量は基本構築1回と各 GUI の導入・圧縮の和で、独立した3回の基本構築を避ける。ディスク使用量には基本 chroot、live-build の作業コピー、最大1つの展開差分、差分の保持・binary コピー・完成 ISO、APT キャッシュが加わる。`build.log` にステージ別の秒数と差分サイズを記録し、初回 CI の完成 ISO とディスク使用量で見積もりを更新する。

## 確認した一次ソース

- [live-boot(7), trixie](https://manpages.debian.org/trixie/live-boot-doc/live-boot.7.en.html): `module=NAME` と `/live`。
- live-boot `1:20250815~deb13u1`: [9990-cmdline-old](https://sources.debian.org/src/live-boot/1%3A20250815~deb13u1/components/9990-cmdline-old/)、[9990-overlay.sh](https://sources.debian.org/src/live-boot/1%3A20250815~deb13u1/components/9990-overlay.sh/)、[9990-misc-helpers.sh](https://sources.debian.org/src/live-boot/1%3A20250815~deb13u1/components/9990-misc-helpers.sh/)。引数解析・一覧読込・層順・既定 overlay。
- live-build `1:20250505+deb13u1`: [build](https://sources.debian.org/src/live-build/1%3A20250505%2Bdeb13u1/scripts/build/build/)、[binary](https://sources.debian.org/src/live-build/1%3A20250505%2Bdeb13u1/scripts/build/binary/)、[binary_hooks](https://sources.debian.org/src/live-build/1%3A20250505%2Bdeb13u1/scripts/build/binary_hooks/)、[binary_grub_cfg](https://sources.debian.org/src/live-build/1%3A20250505%2Bdeb13u1/scripts/build/binary_grub_cfg/)。ステージ順・hook の実行場所・テンプレート変数。
- [live-installer 58, support/squashfs](https://sources.debian.org/src/live-installer/58/support/squashfs/): d-i の固定名。

- [live-installer 58 postinst](https://salsa.debian.org/installer-team/live-installer/-/blob/58/debian/live-installer.postinst)・[依存パッケージ](https://salsa.debian.org/installer-team/live-installer/-/blob/58/debian/control): hook 順序、tar と attr-udeb。
- [live-build installer_debian-installer](https://sources.debian.org/src/live-build/1%3A20250505%2Bdeb13u1/scripts/build/installer_debian-installer/)・[Live Manual 12.3](https://live-team.pages.debian.net/live-manual/html/live-manual/customizing-installer.en.html): includes の initrd 収録。
- [Calamares unpackfs](https://github.com/calamares/calamares/blob/calamares/src/modules/unpackfs/unpackfs.conf)・[module 設定](https://github.com/calamares/calamares/blob/calamares/src/modules/README.md): 複数 entry の順序・exclude・設定パス。
- [calamares-settings-debian 13.0.13 パッケージ](https://deb.debian.org/debian/pool/main/c/calamares-settings-debian/calamares-settings-debian_13.0.13-1_all.deb): `/etc/calamares/modules/unpackfs.conf` と settings の unpackfs 呼出を確認(2026-10-29)。

- [busybox 1.37.0-6 Debian 設定](https://deb.debian.org/debian/pool/main/b/busybox/busybox_1.37.0-6.debian.tar.xz): `debian/config/pkg/udeb` の tar・find・ls・mknod・mount の構成を確認。BusyBox 実バイナリでの実行は QEMU 検証待ち。
