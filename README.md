# bootkit-linux

Debian 13(trixie)の、診断・救出ツール入りの Live と、Debian インストーラーを 1 本にまとめた ISO を、`live-build` で作る設定。Legacy BIOS(syslinux)だけの古い PC でも起動できる iso-hybrid を狙う。ビルドは GitHub Actions(`debian:trixie` の特権コンテナ)で行う。

状態: **試作中**。実機での起動は、まだ確認していない。

- [Ventoy の USB 用の一式](ventoy/README.md)

## 何が入るか

- Live の診断環境: `smartmontools`・`mdadm`・`btrfs-progs`・`hdparm`・`nvme-cli`・`gddrescue`・`testdisk`・`fio`・`memtester`・`iperf3`・`restic` など。F2FS / JFS、SCSI の調査、`lsof`・`strace`・`jq`・Git・Vim も使える(`config/package-lists/diag.list.chroot`)。
- 起動修復・複製・転送: `efibootmgr`・`fsarchiver`・CIFS / SSHFS / NFS・`smbclient`・`dislocker`・`chntpw`、`zerofree`、ISO / SquashFS 操作、`wget`・`lftp`・BorgBackup・GnuPG・`kexec-tools`。GRUB の修復用ツールは amd64 / arm64 ごとに同梱し、amd64 には `memtest86+` も入れる。
- イメージの展開: 7-Zip・Zstandard・LZ4・XZ・bzip2・LZO・lzip・lrzip と、bzip2 / lzip の並列展開器。他の Clonezilla で作ったイメージの復元に使う。
- 無線 LAN: `wpasupplicant`・`iw`・NetworkManager・`rfkill`・`wireless-tools`。
- 補助ツール: `nwipe` による消去、QEMU / WIM のイメージ操作、`mc`・`htop`・`ncdu`・`pv`、ネットワーク・センサー・媒体の調査、`stress-ng`、`gpart`・`foremost`・`safecopy`・Sleuth Kit・EWF による救出。`screen`、従来のネットワーク管理・経路調査、OpenVPN / WireGuard、シリアル端末、`iotop`・`sysstat`・`ipmitool` も同梱する。
- GUI の区画編集: LXQt / IceWM には `gparted` を同梱する。CLI には含めない。
- Debian Installer(`--debian-installer live`)。`config/includes.installer/preseed.cfg` は、ロケール・キーボード・時刻・ミラーだけを決め、**ディスクには触れない**(何も自動で消さない)。
- ディスクを無人で構成する例(md RAID1 の 3 台ミラー + BIOS boot + データ用の区画)は `examples/` にある。**対象のディスクを、すべて消す**ので、内容を読み、実際の構成に合わせて、明示的に使うこと。
- 安全装置 `disk-guard.sh`(ISO の `/cdrom/disk-guard.sh`)は、消す前に、対象のディスクが想定どおり(USB でない・取り外し可能でない・容量が範囲内・型番が合う)かを確かめ、1 つでも違えば、何も消さずに終わる。試験は `tests/test-disk-guard.sh`(条件を外した版で失敗することも確認済み)。

## Clonezilla・partclone の版

Clonezilla と partclone は、trixie より新しい複製・復元ツールを使うため、forky から限定して入れる。Clonezilla 5.19.7・DRBL 5.11.15・partclone 0.3.49 と、追加で必要な `libntfs-3g91` だけを対象にし、それ以外は trixie のままにする。全フレーバー・amd64 / arm64 に共通で、Live の端末から `sudo clonezilla` で使える。

対象は `config/forky-packages.txt` で一元管理する。全構成で、ビルド中の `0400-forky-clonezilla.hook.chroot` 内だけ forky の取得元と優先度を追加し、導入後は失敗時も取得元・pin・索引を除去する。導入した版と基盤パッケージの版の不変も検査する。

live-build の `Check_package_available` は、同名パッケージの版が複数あると利用不可と判定する。そのため別スイートを常設すると、インストーラーの部品選択が壊れる。forky は APT の取得元に常設しない。

版は公開索引の更新に伴って変わるため、依存関係をビルド前に検査する。[確認した版・依存関係と検査方法](docs/forky-pins.md)を参照。

## 調査スクリプト

全フレーバーの `/usr/local/bin/` に、実機の診断情報を日本語で表示するコマンドを入れる。

| コマンド | 調べる内容 |
| --- | --- |
| `survey [--profile ID] [--long]` | 機種別の期待値照合・読出速度・CPU冷却・撮影用要約。root 以外は sudo で再実行 |
| `hw-system` | 機種・BIOS・CPU の型番と機能・メモリとスロット・カーネル。システムのシリアルは出さない |
| `hw-disks` | ディスクの型番・シリアル・容量・接続・SATA リンク速度・SMART の健康と属性・注意点 |
| `hw-disk-speed [--mb N] [デバイス...]` | 先頭・中間・末尾を各 N MiB(既定 512)直接読み出し、MB/s と平均を表示。起動媒体は除外 |
| `hw-ports` | SATA・USB・ExpressCard などの認識、関連するカーネルログ、NIC のリンクと速度 |
| `hw-battery` | 電池の健康度・サイクル数・充電しきい値の有無・AC の接続状態 |
| `disk-guard-suggest` | 内蔵ディスクから `disk-guard.sh --expect` の対象案と照合用の一覧を作る |
| `hw-survey` | 各コマンドの詳細ログを保存し、最後に撮影用の 40 行以内の要約を表示 |

```sh
sudo hw-survey
sudo hw-survey --speed
sudo hw-survey --speed --mb 128 --out /tmp/my-hw-survey
```

`--speed` を付けたときだけ順次読み出しを測る。ディスクへの書き込み・マウント・RAID の組み立て・SMART 自己診断・ネットワーク送信は行わず、電池の設定も変更しない。USB 変換器で SMART が取得できない場合は SAT 指定で 1 回再取得する。SMART の生の値(特に摩耗・読み書き量)の単位は機種によって異なる。

出力は既定で `/tmp/hw-survey-<日時>/` の RAM 上に保存する。保存前にファイルシステムが tmpfs・ramfs・overlay かを確かめ、それ以外や判定不能なら中止する。ディスク上へ保存するときだけ `--allow-disk` を明示する。既存の保存先は上書きしない。Live の終了時に RAM 上のログは失われる。欠けている診断コマンドは「未取得」と表示して続ける。試験では `HW_SYSFS` と `HW_PROC` で情報源を差し替えられる。

`disk-guard-suggest` は、USB・取り外し可能な媒体・起動媒体を除き、容量の 95%〜105% を許容範囲にする。**これは今の実機の値から作った案。想定と違うディスクが混ざっていないか、人が一覧表で確かめてから使う**。`sdX` の名前は起動のたびに変わりうるため、併記した `/dev/disk/by-id` も照合する。この案を表示するだけではインストールも消去も実行しない。

`survey` は DMI から ThinkPad Edge 14 / 0578、IdeaPad G560 / 0679 / 20042 を判定し、該当しなければ generic にする。`survey --list` で指定可能な ID を表示する。内蔵の固定ディスクだけを `hdparm -t --direct` で 3 回読み、中央値を表示し、180 秒の CPU 負荷と温度監視を追加する。`survey --long` では SMART long と空きメモリの半分以下の memtester 1 パスも実行する。swap は停止し、停止できなければ負荷・メモリ試験を省略する。出力は RAM 上だけで、撮影用の要約を表示したまま Enter を待つ。

amd64 の起動メニューにある `Hardware survey: ThinkPad Edge 14 (0578), auto`、`Hardware survey: IdeaPad G560, auto`、`Hardware survey: other PC, auto (generic)` を選ぶと、安全モードで起動して tty1 で自動検査する。通常起動・arm64 では自動検査しない。[実機検査の手順と判定の目安](docs/hw-survey-procedure.md)を参照。

## ローカルのテスト

`make` または `make help` で一覧を表示する。`make test` は `tests/test-*.sh` と `tests/test-forky-deps.py` を並列に実行して結果を集計し、失敗があれば非 0 で終わる。空白を含むパスのコピー試験は独立した段階で実行する。`make test-survey` は検査スクリプト、`make test-boot` は起動設定だけを検査する。macOS の make と GNU make に対応し、ISO のビルド・通信・push は行わない。実デバイスを使わず、偽の sysfs/proc とコマンドで検査する。

## フレーバー

`FLAVOR` で、同じ診断ツールに足すデスクトップを選ぶ(`auto/config`)。ISO 名は `bootkit-linux-<arch>-<flavor>.iso`。

- `cli`: コマンドラインのみ。
- `lxqt`: LXQt と Calamares を足す。
- `icewm`: 軽量な IceWM を足す。tty1 の自動ログイン後に X を起動する。起動オプション `nox` を付けると CLI のままで、あとから `startx` で起動できる。

IceWM では、携帯回線モデムを管理する ModemManager を削除する(NetworkManager は残す)。キーボードは JIS 配列が既定で、`Ctrl+Alt+K` で JIS / US を切り替える。端末から `kbd-toggle` を実行すると、切り替え後の配列名(`jp` / `us`)を表示する。起動時から US 配列にするには、起動メニューでカーネルの起動オプションの `keyboard-layouts=jp` を `keyboard-layouts=us` に変更する。`nox` で CLI のまま起動した場合も、`kbd-toggle` で切り替えられる(コンソールの配列変更には root 権限が必要なため、`sudo kbd-toggle` を使う)。

日本語入力の Fcitx5 / Mozc は同梱するが、自動では起動しない。IceWM 上で `Ctrl+Alt+J`、または端末から `ime-on` で起動し、そのあとに起動するアプリで日本語入力を使う。入力用の環境変数は X セッションの開始時に設定する。IceWM の既定のキー割り当て(`Alt+Tab` など)も使える。

## SSH

全フレーバーで、SSH サーバーは既定では起動しない。必要なときは Live の端末で `ssh-on` を実行する。案内に従って Live ユーザー `user` のパスワードを変更すると、SSH サーバーを起動し、接続先のアドレスを表示する。root で実行した場合も `user` のパスワードを変更する。パスワードの変更に失敗した場合は起動しない。

既定のパスワード `live` は公開情報であり、そのまま LAN からのログインに使わない。

## 起動メニュー

既存の Live・fail-safe(カーネルの互換性設定)・インストーラーの項目に加え、全フレーバーで次を選べる。amd64 は Legacy BIOS と UEFI、arm64 は UEFI に対応する。

- `Live system, copy to RAM`: 通常の Live に `toram` を加え、Live のファイルシステムを RAM にコピーする。コピーを完了して起動したあとは起動 USB を取り外せる。Live のコピーと通常の動作に足りる RAM が必要。
- `Live system, safe mode`: 通常の Live に `bootkit.safe=1` を加える。udev(機器の検出と初期設定を行う仕組み)が起動する前に、md ソフトウェア RAID の自動組み立てと LVM の自動有効化の規則を無効にする。検出したブロックデバイスとパーティションを `blockdev --setro` で読み取り専用にする。`loop*`・`ram*`・`sr*`・`zram*` は対象外。規則は Live 起動後も残り、あとから接続された機器にも適用する。
- `Memtest86+`: amd64 のみ。BIOS・UEFI とも `Utilities` 内からメモリーを検査できる。arm64 には表示しない。

安全モードは、壊れかけのディスクに対する OS の自動処理による書き込みを抑えるためのもの。ハードウェアの書き込み防止装置ではなく、管理者による明示的な操作は禁止しない。たとえば `mdadm --assemble` の実行や `blockdev --setrw` による解除は可能で、機器への直接のコマンドや機器自身の内部処理まで防ぐものではない。udev の規則以外から行う RAID 組み立て・LVM 有効化も制限しない。安全モードでも起動 USB 自体を読み取り専用にするため、USB の書き換えには解除が要る。実機での安全モードの動作確認は未実施。

## SystemRescue との違い

診断・復旧用の道具は、SystemRescue 13.02(amd64)の主な項目をパッケージとして足してあり、多くの用途で置き換えられる。足していない、または再現していない機能は次のとおり。

- 起動時に任意のスクリプトを実行する `autorun` と、YAML の設定ファイルによる起動時の構成。
- 配布 ISO を書き換えて道具や設定を足す `sysrescue-customize`。この ISO は、`config/` を変えて作り直す。
- カーネルの版。SystemRescue 13.02 は 6.18 系で、この ISO は Debian 13 の 6.12 系。新しいハードウェアへの対応は、SystemRescue のほうが新しい場合がある。
- Secure Boot での起動は未確認。

これらが要るときは、SystemRescue の ISO を別に用意する。

## 作り方

GitHub の Actions の `build-iso` を手動で実行する(`workflow_dispatch`)か、`auto/` と `config/` を変更して main に push する。成果物の ISO と `SHA256SUMS` が、アーティファクトに 30 日保管される。

手元で作る場合は、Debian 13 の amd64 の環境(仮想マシンやコンテナ)で、`live-build`・`debootstrap`・`xorriso`・`syslinux` などを入れ、`./auto/config && ./auto/build` を実行する。ビルド領域に約 13GB が要る。

## リリース

版記号は `{n}.{yyyymmdd}.{英字+数字}` とし、タグ名は先頭に `v` を付ける(例: `v0.20261026.a0`)。`n` は 0 から始まり、メジャーリリースごとに 1 ずつ増える。`yyyymmdd` は公開日。最後の英字+数字は、数字部分がリリースごとに 1 ずつ増え(a0 → a1 → …)、英字部分は中規模のリリースごとに b → c → d → … → aa → ab → … → ba → bb → … と進む。日付と、英字・数字の部分は、それぞれ独立に動く。

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

TCG(CPU のエミュレーション)は、ホストの CPU が動画処理やディスクイメージの圧縮などの重い処理で埋まっていると、極端に遅くなり、起動が止まったように見える。この間、ゲストの時間はほとんど進まない。試験はホストの負荷が低いときに行う。参考値として、負荷が低い Mac では、CLI 版は BIOS・2GB・2 コアでログインまで約 3〜5 分かかる。

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
