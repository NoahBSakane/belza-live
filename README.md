# bootkit-linux

Debian 13(trixie)の、診断・救出ツール入りの Live と、Debian インストーラーを 1 本にまとめた ISO を、`live-build` で作る設定。Legacy BIOS(syslinux)だけの古い PC でも起動できる iso-hybrid を狙う。ビルドは GitHub Actions(`debian:trixie` の特権コンテナ)で行う。

状態: **試作中**。実機での起動は、まだ確認していない。

## 何が入るか

- Live の診断環境: `smartmontools`・`mdadm`・`btrfs-progs`・`hdparm`・`nvme-cli`・`gddrescue`・`testdisk`・`fio`・`memtester`・`iperf3`・`restic` など(`config/package-lists/diag.list.chroot`)。
- Debian Installer(`--debian-installer live`)。`config/includes.installer/preseed.cfg` は、ロケール・キーボード・時刻・ミラーだけを決め、**ディスクには触れない**(何も自動で消さない)。
- ディスクを無人で構成する例(md RAID1 の 3 台ミラー + BIOS boot + データ用の区画)は `examples/` にある。**対象のディスクを、すべて消す**ので、内容を読み、実際の構成に合わせて、明示的に使うこと。
- 安全装置 `disk-guard.sh`(ISO の `/cdrom/disk-guard.sh`)は、消す前に、対象のディスクが想定どおり(USB でない・取り外し可能でない・容量が範囲内・型番が合う)かを確かめ、1 つでも違えば、何も消さずに終わる。試験は `tests/test-disk-guard.sh`(条件を外した版で失敗することも確認済み)。

## フレーバー

`FLAVOR` で、同じ診断ツールに足すデスクトップを選ぶ(`auto/config`)。ISO 名は `bootkit-linux-<arch>-<flavor>.iso`。

- `cli`: コマンドラインのみ。
- `lxqt`: LXQt と Calamares を足す。
- `icewm`: 軽量な IceWM を足す。tty1 の自動ログイン後に X を起動する。起動オプション `nox` を付けると CLI のままで、あとから `startx` で起動できる。

## 作り方

GitHub の Actions の `build-iso` を手動で実行する(`workflow_dispatch`)か、`auto/` と `config/` を変更して main に push する。成果物の ISO と `SHA256SUMS` が、アーティファクトに 30 日保管される。

手元で作る場合は、Debian 13 の amd64 の環境(仮想マシンやコンテナ)で、`live-build`・`debootstrap`・`xorriso`・`syslinux` などを入れ、`./auto/config && ./auto/build` を実行する。ビルド領域に約 13GB が要る。

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

- `--memtest` は、Debian の `live-build` の不具合(#1122654。memtest86+ 8.x でファイル名が変わった)のため、いまは `none` にしている。必要なら、バイナリを `config/includes.binary` に置く。
- Debian 13 の公式 Live も、完全には再現可能ではない(boot 画面とファームウェアの一部が異なる。squashfs は再現できる)。この ISO も、SHA-256 の完全一致は目標にしない。固定できるのは、設定とパッケージの版まで。
- ファームウェア(`non-free-firmware`)を含めている。不要なら、`auto/config` の `--archive-areas` と `--firmware-*` を変える。

## 参考にした先行事例

- [nodiscc/debian-live-config](https://github.com/nodiscc/debian-live-config)(GPL-3.0): trixie、`--debian-installer live`、memtest86+、BIOS と UEFI のオフラインインストールの試験。
- [jasonfen/rescuebot](https://github.com/jasonfen/rescuebot)(GPL-3.0): 診断ツール入りの trixie の ISO、snapshot.debian.org での日付の固定。
- [jandie1505/rescue-os](https://github.com/jandie1505/rescue-os)(GPL-3.0): GitHub Actions の特権コンテナでのビルド。

## ライセンス

GPL-3.0(`LICENSE`)。
