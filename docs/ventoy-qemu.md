# 共通層の統合 ISO: Ventoy 1.1.18 の QEMU 検証

2026-10-31、オフラインで作業ツリー内の使い捨てディスクを使用。
UEFI の 3 OS の toram 起動・USB 取り外し後の操作と通常項目の対照を確認した。
Server の残留 mapper のエラーログと、通常モードの制約は下記のとおり。

## 構成

- 入力 ISO: 9,654,042,624 バイト、SHA-256
  `761b156da9d45fd9b666d6a6cb42dd4fd1e961063c8a7bfeab6937ba560a7d04`。
  入力は書き換えていない。コピーは仮想 USB の `/ISO/live/` へ 1 回だけ。
- 仮想 USB: `build/ventoy-usb.raw`、13 GiB のスパース、MBR、exFAT + 32 MiB EFI。
- インストール: Alpine virt 3.22.7 aarch64 / HVF、2 vCPU、2 GiB RAM で
  配布物の `Ventoy2Disk.sh -I /dev/vda`。更新処理は実行していない。
- 起動: QEMU x86_64、TCG、Westmere、4 vCPU、q35、
  `edk2-x86_64-code.fd`、`qemu-xhci` + `usb-storage`。
  BIOS の追加試験は pc / SeaBIOS、4 GiB RAM。
  ゲストには個別の qcow2 差分を通して書込み可能に見せ、元の raw を保持する。
  読み取り専用 USB では Ventoy の mapper 作成が `-EROFS` となった。
- 同時 QEMU は最大 2 台、ゲスト RAM の合計は最大 14 GiB。
  観測した最小空き容量は 27 GiB。
- ネットワークは `-net none`。実 USB・実ディスクは使っていない。

Alpine の formatter は glibc 向けで、標準の musl だけでは実行できなかった。
この試験 VM 内だけで musl loader への alias と、`__fxstat64` を AArch64 の
fstat syscall に渡す小さな互換ライブラリを使った。元の formatter・installer
は変更していない。互換 ELF の生成器は `tools/ubuntu-merge/make-ventoy-musl-compat.py`、
実行スクリプトは `build/`、ログは下記証拠に保存。
exFAT は `mount -t exfat` でマウントした。

busybox `dd` の pipe 短読込みにより `-I` の EFI 区画は byte 33,194,015
から末尾がゼロだった。一致する接頭部を確認し、配布物の同じ区画イメージから
不足した末尾を補完した。32 MiB 全体が配布物と一致。更新スクリプトの結果へ
置き換えたものではない。詳細は `efi-completion.txt`。

互換 ELF の再生成は次のとおり。生成物を道具用 ISO に含め、VM 内の
`/tools/compat.so` として使った。VM 内で `/lib/ld-linux-aarch64.so.1` と
`/lib/libc.so.6` を `/lib/ld-musl-aarch64.so.1` へ向け、
`LD_PRELOAD=/tools/compat.so` を指定して元の `Ventoy2Disk.sh -I` を実行した。

```sh
python3 -I tools/ubuntu-merge/make-ventoy-musl-compat.py build/compat.so
```

`tools/ubuntu-merge/check-ventoy-image.py` は作業ツリー内の MBR/exFAT raw
だけを開き、指定した ISO のサイズと SHA-256 をコピーせずに照合する。
ハッシュは入力と仮想 USB の両方で上記の値に一致した。

## 設定と起動経路

プラグイン設定のないディスクで実施した。Ventoy の ISO メニュー、
Boot in normal mode / Boot in grub2 mode の選択メニューを確認。
通常モードは `Failed to open \EFI\BOOT\ - No mapping`、黒画面で
180 秒以内に ISO メニューへ進まなかった。書込み可能な USB でも同じ。
GRUB2 モードでは ISO 内の 3 OS × 3 項目が serial に表示され、ISO の
`grub.cfg` がそのまま読まれた。GRUB 中の VGA は 8 × 32 の黒画像となるため、
項目と入力は serial 原本でも照合する。GUI の成否は起動後の画面で別に判定する。

3 OS とも ISO 内の追加 cpio が実行され、premount が
`/dev/mapper/ventoy` を検出した。injection・conf_replace は不要。
媒体探索コードの変更はしていない。GRUB2 モードでの結論であり、通常モードの
EFI エラーを conf_replace で解消したという結果ではない。
最終的な起動・取り外しの成否は以下の表で示す。

## 起動・USB 取り外し

| OS / 条件 | ISO メニュー | 選択複写 | 起動完了 | USB 取り外し |
| --- | --- | --- | --- | --- |
| Server toram / GRUB2 | 確認済み | 2 層、tmpfs 1,515,585,536 バイト | subiquity / shell | 全層読出し・Python・APT 成功 |
| Lubuntu toram / GRUB2 | 確認済み | 3 層、tmpfs 3,749,957,632 バイト | LXQt / shell | 全層読出し・Python・APT 成功 |
| Ubuntu toram / GRUB2 | 確認済み | 3 層、tmpfs 4,722,278,400 バイト | GNOME Live / shell | 全層読出し・Python・APT 成功 |
| Server BIOS toram / GRUB2 | 確認済み | 2 層、tmpfs 1,515,585,536 バイト | subiquity / shell | 全層読出し・Python・APT 成功 |
| Server 通常項目の対照 / GRUB2 | 確認済み | ISO / mapper を参照 | subiquity / shell | 新規コマンドが I/O エラー、対照成立 |

実機・Secure Boot・Ventoy 経由の safe graphics・OS インストール、Ventoy / BIOS の
Lubuntu / Ubuntu は未検証。ISO 単体の SeaBIOS CD-ROM 起動では Lubuntu / Ubuntu の
選択複写と全層読出し・Python・APT を確認済みである。ISO 単体の UEFI safe graphics を
含む追加結果は [RAM 選択複写](ubuntu-ramsel.md) を参照。
本節の Ventoy / BIOS の試験対象は Server のみ。

Lubuntu は標準の `snapd.seeded.service` を待ってから Try Lubuntu の画面に
到達し、Live を選択した。サービス設定や ISO は変更していない。

3 OS の取り外し後、`findmnt` と `/proc/mounts` に元 USB / mapper の
mount はなく、層の loop は tmpfs 内だけを参照した。`dmsetup ls` には
未マウントの `ventoy` / `VentoyPart` が残る。Server は 2 層、Lubuntu と Ubuntu は 3 層の全体読出しが終了値 0、
新規 Python は `PY_OK`、`apt-get check` は終了値 0。
Server は USB disconnect の guest 時刻 328.21 秒の後、331.34〜331.60 秒に
元媒体の `dm-0` / `dm-1` で `Buffer I/O error` を 4 件記録した。
全層読出しの `drop_caches` は 345.28 秒からで、その操作にはエラーがない。
BIOS の Server でも USB 切断後に同じ mapper のエラーが 4 件あり、
未使用の仮想 floppy (`fd0`) の読出しエラーもあった。層の全体読出しと
Python / APT はすべて成功した。
残留 mapper を読むプロセスは未特定で、カーネルログのエラーがゼロという
結果ではない。Lubuntu と Ubuntu の取得ログには同じ Buffer I/O エラーはなかった。

通常項目の対照は `toram` なし、`/cdrom` が `/dev/mapper/ventoy` の
iso9660 で、root の lowerdir は Server の 2 層だった。USB を外すと
`losetup` / `awk` の実行が I/O エラーとなり、層の列挙自体ができず
`READ_LAYER_COUNT=0`、`MEDIA_READ_RC=1`。新規 Python と sudo / APT も
実行できず、APT コマンドの終了値は 126。通常項目では媒体に依存することを
確認した。toram の tmpfs との差は各 OS とも層合計 +24,576 バイトである。

## 再実行

仮想ディスクを用意した後、Server の toram は次で実行する。ゲストの
書込みは証拠と同じ接頭辞の `.overlay.qcow2` に残る。実行ごとに新しい
`--prefix` を使う。ISO は入力識別用で、CD-ROM としては接続しない。

```sh
python3 -I ventoy/ramsel/verify-qemu.py \
  --transport pipe --mode ventoy-uefi --ventoy-mode grub2 \
  --ventoy-disk build/ventoy-usb.raw \
  --iso build/input/ubuntu-merge-26.04.1-amd64.iso \
  --mem 4096 --smp 4 --entry 8 --server-shell --expect-os server \
  --prefix build/evidence/ventoy/server-new --timeout 3600 --detach
```

entry は Server toram = 8、Lubuntu toram = 5、Ubuntu toram = 2、
Server 通常 = 6。通常項目では `--expect-os` を使わない。
取り外しは `device_del ventoyusb`。qtree で USB 装置が消えたことを確認し、
キャッシュを落とした全層読出し・新しい Python・`apt-get check` を実行する。
通常項目の対照には `--expect-detach-failure` を付ける。

BIOS の Server は上記コマンドの `--mode ventoy-uefi` を
`--mode ventoy-bios --machine pc` に変え、別の prefix で実行する。
BIOS の診断用 serial 設定は起動時にメモリ内で追加し、ISO やディスク上の
GRUB 設定は変更しない。Lubuntu / Ubuntu は `--desktop lxqt` / `--desktop gnome`、
RAM は各 6144 / 8192 MiB で検証した。Lubuntu は Try Lubuntu の選択が必要。
Ubuntu の描画にはプロセス検出からさらに時間がかかり、USB 取り外し後に
GNOME Live の画面を確認した。GRUB の `terminal_output gfxterm` への変更は
今回の UEFI で `unaligned pointer` を起こしたため、検証手順に含めない。

## 証拠

`build/evidence/ventoy/` に保存する。ログは serial の raw と transcript、
QEMU コマンド・stderr を含む。120 秒ごとに進行の画像を更新する。

| 接頭辞 / ファイル | 内容 |
| --- | --- |
| `alpine2*` | 本物の -I、MBR 区画、formatter の成功 |
| `alpine3*` | exFAT 明示マウント、ISO コピーのサイズと終了値 |
| `partition-check.txt` / `efi-completion.txt` | EFI 末尾の検査と全域一致 |
| `input-iso.sha256` / `embedded-iso.json` | 入力と exFAT 内の ISO のハッシュ一致 |
| `server-toram*` | 通常モードの最初の観測。readonly USB |
| `server-normal-rw*` | 書込み可能な USB での通常モード |
| `server-grub2*` | GRUB2。無印は readonly による mapper 失敗 |
| `server-grub2-rw*` | 書込み可能な USB での Server toram |
| `lubuntu-grub2*` / `lubuntu-after-usb.png` | LXQt、3 層、取り外し後の操作 |
| `ubuntu-grub2*` / `ubuntu-render-now.png` | GNOME Live、3 層、取り外し後の操作 |
| `server-bios-final*` | BIOS / GRUB2 の追加検証 |
| `server-control-final*` | 通常項目の USB 取り外し対照 |
| `server-control*` (final 以外) | 表示切替えで GRUB が中断。対照に数えない |
| `make-test-delivery.log` | 最終コードの通信不要の全テスト、終了値 0 |

## 検査と引き渡し

`make test` は最終コードで終了値 0 (空白・ピリオドを含むパスの試験も含む)。
`markdownlint` と `git diff --check` も合格。作業ツリー内だけを変更し、
`git add`・コミットはしていない。入力 ISO と実媒体は変更していない。
仮想 raw と証拠は再実行用に `build/` に保持し、Git に含めない。
