# bootkit-linux

Debian 13(trixie)の、診断・救出ツール入りの Live と、Debian インストーラーを 1 本にまとめた ISO を、`live-build` で作る設定。Legacy BIOS(syslinux)だけの古い PC でも起動できる iso-hybrid を狙う。ビルドは GitHub Actions(`debian:trixie` の特権コンテナ)で行う。

状態: **試作中**。実機での起動は、まだ確認していない。

## 何が入るか

- Live の診断環境: `smartmontools`・`mdadm`・`btrfs-progs`・`hdparm`・`nvme-cli`・`gddrescue`・`testdisk`・`fio`・`memtester`・`iperf3`・`restic` など(`config/package-lists/diag.list.chroot`)。
- 起動修復・複製・転送: `efibootmgr`・`fsarchiver`・CIFS / SSHFS / NFS・`dislocker`・`chntpw`。GRUB の修復用ツールは amd64 / arm64 ごとに同梱し、amd64 には `memtest86+` も入れる。
- イメージの展開: Zstandard・LZ4・XZ・bzip2・LZO・lzip・lrzip と、bzip2 / lzip の並列展開器。他の Clonezilla で作ったイメージの復元に使う。
- 無線 LAN: `wpasupplicant`・`iw`・NetworkManager。
- 補助ツール: `nwipe` による消去、QEMU / WIM のイメージ操作、`mc`・`htop`・`ncdu`・`pv`、ネットワーク・センサー・媒体の調査、`stress-ng`、`gpart`・`foremost`・`safecopy` による救出。
- Debian Installer(`--debian-installer live`)。`config/includes.installer/preseed.cfg` は、ロケール・キーボード・時刻・ミラーだけを決め、**ディスクには触れない**(何も自動で消さない)。
- ディスクを無人で構成する例(md RAID1 の 3 台ミラー + BIOS boot + データ用の区画)は `examples/` にある。**対象のディスクを、すべて消す**ので、内容を読み、実際の構成に合わせて、明示的に使うこと。
- 安全装置 `disk-guard.sh`(ISO の `/cdrom/disk-guard.sh`)は、消す前に、対象のディスクが想定どおり(USB でない・取り外し可能でない・容量が範囲内・型番が合う)かを確かめ、1 つでも違えば、何も消さずに終わる。試験は `tests/test-disk-guard.sh`(条件を外した版で失敗することも確認済み)。

## フレーバー

`FLAVOR` で、同じ診断ツールに足すデスクトップを選ぶ(`auto/config`)。ISO 名は `bootkit-linux-<arch>-<flavor>.iso`。

- `cli`: コマンドラインのみ。
- `lxqt`: LXQt と Calamares を足す。
- `icewm`: 軽量な IceWM を足す。tty1 の自動ログイン後に X を起動する。起動オプション `nox` を付けると CLI のままで、あとから `startx` で起動できる。

IceWM では、携帯回線モデムを管理する ModemManager を削除する(NetworkManager は残す)。キーボードは JIS 配列が既定で、`Ctrl+Alt+K` で JIS / US を切り替える。端末から `kbd-toggle` を実行すると、切り替え後の配列名(`jp` / `us`)を表示する。起動時から US 配列にするには、起動メニューでカーネルの起動オプションの `keyboard-layouts=jp` を `keyboard-layouts=us` に変更する。`nox` で CLI のまま起動した場合も、`kbd-toggle` で切り替えられる(コンソールの配列変更には root 権限が必要なため、`sudo kbd-toggle` を使う)。

日本語入力の Fcitx5 / Mozc は同梱するが、自動では起動しない。IceWM 上で `Ctrl+Alt+J`、または端末から `ime-on` で起動し、そのあとに起動するアプリで日本語入力を使う。入力用の環境変数は X セッションの開始時に設定する。IceWM の既定のキー割り当て(`Alt+Tab` など)も使える。

## 起動メニュー

既存の Live・fail-safe(カーネルの互換性設定)・インストーラーの項目に加え、全フレーバーで次を選べる。amd64 は Legacy BIOS と UEFI、arm64 は UEFI に対応する。

- `Live system, copy to RAM`: 通常の Live に `toram` を加え、Live のファイルシステムを RAM にコピーする。コピーを完了して起動したあとは起動 USB を取り外せる。Live のコピーと通常の動作に足りる RAM が必要。
- `Live system, safe mode`: 通常の Live に `bootkit.safe=1` を加える。udev(機器の検出と初期設定を行う仕組み)が起動する前に、md ソフトウェア RAID の自動組み立てと LVM の自動有効化の規則を無効にする。検出したブロックデバイスとパーティションを `blockdev --setro` で読み取り専用にする。`loop*`・`ram*`・`sr*`・`zram*` は対象外。規則は Live 起動後も残り、あとから接続された機器にも適用する。
- `Memtest86+`: amd64 のみ。BIOS・UEFI とも `Utilities` 内からメモリーを検査できる。arm64 には表示しない。

安全モードは、壊れかけのディスクに対する OS の自動処理による書き込みを抑えるためのもの。ハードウェアの書き込み防止装置ではなく、管理者による明示的な操作は禁止しない。たとえば `mdadm --assemble` の実行や `blockdev --setrw` による解除は可能で、機器への直接のコマンドや機器自身の内部処理まで防ぐものではない。udev の規則以外から行う RAID 組み立て・LVM 有効化も制限しない。安全モードでも起動 USB 自体を読み取り専用にするため、USB の書き換えには解除が要る。実機での安全モードの動作確認は未実施。

## 作り方

GitHub の Actions の `build-iso` を手動で実行する(`workflow_dispatch`)か、`auto/` と `config/` を変更して main に push する。成果物の ISO と `SHA256SUMS` が、アーティファクトに 30 日保管される。

手元で作る場合は、Debian 13 の amd64 の環境(仮想マシンやコンテナ)で、`live-build`・`debootstrap`・`xorriso`・`syslinux` などを入れ、`./auto/config && ./auto/build` を実行する。ビルド領域に約 13GB が要る。

## リリース

`v*` タグを push すると、そのタグのコミットから amd64・arm64 の各フレーバーをビルドし、GitHub Release に公開する。タグの push ではプレリリースとして公開する。同じタグの Release が既にあれば失敗し、上書きしない。

手動の場合は Actions の `release` で、既存タグを `tag` に指定する。`dry_run` は既定で true で、公開予定の添付ファイル名・サイズ・SHA-256 と本文をログへ表示し、Release は作らない。公開する場合は `dry_run` を false にし、正式リリースにする場合は `prerelease` も false にする(既定は true)。

2 GiB (2147483648 バイト)を超える ISO は、最大 1900 MiB の `bootkit-linux-<arch>-<flavor>.iso.part00`、`part01` などに分割する。必要な ISO の全 part ファイルと `SHA256SUMS`・`SHA256SUMS.parts` を同じディレクトリへ保存し、次の順で検証・結合する。`<名前>` は `bootkit-linux-amd64-lxqt` などに置き換える。

```sh
sha256sum --ignore-missing -c SHA256SUMS.parts
cat <名前>.iso.part* > <名前>.iso
sha256sum --ignore-missing -c SHA256SUMS
```

`SHA256SUMS` は完全な ISO、`SHA256SUMS.parts` は各 part ファイルのチェックサム。使う ISO と全 part ファイルが検証結果で `OK` になることを確かめる。上限以下の ISO は分割されず、`SHA256SUMS` でそのまま検証できる。macOS では `shasum -a 256 -c` を使い、必要なファイルの行だけをチェックサム一覧から選ぶ。Release 本文にはビルドしたコミットと `build-iso` の実行へのリンクも載せる。

## QEMU での起動試験

Mac では Homebrew の QEMU(`brew install qemu`)と Python 3 を使う。`tests/qemu-boot.py` は Python の標準ライブラリだけで動き、TCG による CPU エミュレーションで ISO を起動する。実ディスクは接続しない。

```sh
# amd64・Legacy BIOS(既定)。起動後、このターミナルは制御待ちになる。
python3 -I tests/qemu-boot.py --iso bootkit-linux-amd64-cli.iso \
  --prefix /private/tmp/bootkit-bios

# amd64・UEFI
python3 -I tests/qemu-boot.py --iso bootkit-linux-amd64-cli.iso \
  --firmware uefi --prefix /private/tmp/bootkit-uefi

# arm64 は UEFI を明示する。
python3 -I tests/qemu-boot.py --iso bootkit-linux-arm64-cli.iso \
  --arch arm64 --firmware uefi --prefix /private/tmp/bootkit-arm64
```

`--mem` は MiB(既定 2048)、`--smp` は CPU 数(既定 2)、`--timeout` は起動からの期限(既定 3600 秒)。期限を超えると QEMU を止め、終了コード 1 で終了する。`--dry-run` を付けると、QEMU を起動せず、組み立てたコマンドを表示する(可変領域のパスは仮のもの)。UEFI ファームウェアは `brew --prefix` 配下の `share/qemu` から探し、可変領域のテンプレートがあれば一時コピーを使う。

`ready:` が出たら、別のターミナルから `<prefix>.ctl` にコマンドを行単位で追記する。起動時に既存の ctl は空にする。同じ prefix を同時に使わないこと。

```sh
cat >> /private/tmp/bootkit-bios.ctl <<'EOF'
wait 10
shot boot
type uname -a
key ret
wait 2
shot result
quit
EOF
```

- `shot 名前`: `<prefix>-名前.png` を保存する。名前は英数字・`_`・`.`・`-` が使える。
- `type 文字列`: 英数字・ASCII 記号をキーとして送る。末尾の Enter は送らない。
- `key キー名`: QEMU の `sendkey` のキー名を送る(`ret`、`esc`、`ctrl-alt-f2` など)。
- `wait 秒`: 指定した秒数だけ待つ。待っている間も実行期限は有効。
- `quit`: QEMU を止めて終了する。

ゲストを `keyboard-layouts=jp` で起動する場合は、スクリプトにも `--kbd jp` を付ける。既定は US 配列。JIS 配列では `|` は `shift-yen`、`=` は `shift-minus`、`^` は `equal` として送る。この指定はゲストの配列自体を切り替えない。日本語の文字列は直接入力できない。

QEMU の標準出力・標準エラーは `<prefix>.qemu.log` に保存する(同じ prefix で再起動すると上書き)。起動失敗時にはログの末尾も表示する。終了・中断時には QEMU、短いパスのモニターソケット、一時コピーした可変領域を片付け、ctl・PNG・ログを残す。

引数の組み立てとキー配列の試験は `bash tests/test-qemu-boot-args.sh` で実行できる。この試験は QEMU を起動しない。

## 既知の注意

- Memtest86+ は amd64 で有効、arm64 では無効。trixie の memtest86+ 7.20-1 は live-build 20250505+deb13u1 が扱うファイル名と一致する。[Debian #1122654](https://bugs.debian.org/1122654) は 8.x でのファイル名変更に関する不具合であり、8.x に更新する場合は再確認が要る。
- Debian 13 の公式 Live も、完全には再現可能ではない(boot 画面とファームウェアの一部が異なる。squashfs は再現できる)。この ISO も、SHA-256 の完全一致は目標にしない。固定できるのは、設定とパッケージの版まで。
- ファームウェア(`non-free-firmware`)を含めている。不要なら、`auto/config` の `--archive-areas` と `--firmware-*` を変える。

## 参考にした先行事例

- [nodiscc/debian-live-config](https://github.com/nodiscc/debian-live-config)(GPL-3.0): trixie、`--debian-installer live`、memtest86+、BIOS と UEFI のオフラインインストールの試験。
- [jasonfen/rescuebot](https://github.com/jasonfen/rescuebot)(GPL-3.0): 診断ツール入りの trixie の ISO、snapshot.debian.org での日付の固定。
- [jandie1505/rescue-os](https://github.com/jandie1505/rescue-os)(GPL-3.0): GitHub Actions の特権コンテナでのビルド。

## ライセンス

GPL-3.0(`LICENSE`)。
