# Ventoy の USB 用の一式

Ubuntu・Lubuntu・Ubuntu Server 26.04.1 amd64 は、共通層を共有する
統合 ISO (B2) で使う。Ventoy は **1.1.18 以上**とし、ISO 選択後に
**Boot in grub2 mode** を選ぶ。

## 統合 ISO の配置と起動

USB の第 1 パーティションへ、次の配置で統合 ISO を置く。

```text
/ISO/live/ubuntu-merge-26.04.1-amd64.iso
```

ISO 内の GRUB メニューで、3 OS それぞれの通常・safe graphics・copy to RAM
の計 9 項目を選ぶ。copy to RAM は選択した OS の層だけを RAM へ複写する。
起動に必要な GRUB と追加 cpio は ISO に含まれ、Ventoy の injection や
conf_replace、追加パック、永続化用の `.dat` は不要。

表示名の雛形は [merge/ventoy.json](merge/ventoy.json)。既存の設定へは、
手元に保存した JSON を入力にして次のように統合する。

```sh
python3 -I ventoy/merge-ventoy-json.py existing.json merged.json --dry-run
python3 -I ventoy/merge-ventoy-json.py existing.json merged.json
```

統合 ISO の表示名だけを置き換え、他の ISO やプラグイン設定は保持する。
同じ入力・出力への書き込みには `--in-place` が必要。
既存の injection・conf_replace に統合 ISO 向けの試験設定があれば、
その内容を別途照合する。設定の詳細は [統合 ISO 用設定](merge/README.md)、
層構成・作成方法は [統合 ISO の仕様](../docs/ubuntu-merge.md)を参照する。

## 起動の確認範囲

Ventoy 1.1.18 の QEMU では、GRUB2 モードで UEFI の 3 OS と BIOS の Server の
copy to RAM 起動が完了し、仮想 USB の取り外し後も全層読出し・Python・APT が
成功した。通常モードは UEFI で `Failed to open \EFI\BOOT\ - No mapping`
となり、180 秒以内に ISO メニューへ進まなかったため、GRUB2 モードを使う。

実機・Secure Boot・safe graphics・OS インストール、BIOS の Lubuntu / Ubuntu は
未検証。Server は取り外し後に残留 mapper の I/O エラーを記録したが、RAM の
層読出しと Python・APT は成功した。条件と証拠は
[Ventoy QEMU 検証](../docs/ventoy-qemu.md)を参照する。

## Ventoy の更新(Mac、MBR のディスク)

Ventoy の更新ツールは Windows と Linux 用で、Mac 用はない。MBR のディスクで、Ventoy 1.1.18 の `tool/VentoyWorker.sh` の更新(Update)と同じバイト操作を再現するスクリプトを `ventoy/update-ventoy-mbr.py` に置く。第 1 パーティション(ISO などのデータ)には触れない。

```sh
# 展開した配布物(ventoy-1.1.18/)を指定する。--apply が無いと、検査と退避の計画だけを表示する。
sudo python3 -I ventoy/update-ventoy-mbr.py --ventoy-dir ./ventoy-1.1.18 /dev/rdisk4
sudo python3 -I ventoy/update-ventoy-mbr.py --ventoy-dir ./ventoy-1.1.18 --backup-dir ./backup --apply /dev/rdisk4
```

- 対象は、MBR で、第 2 パーティションが Ventoy の形(タイプ 0xEF、65536 セクタ、ラベル VTOYEFI)で、セキュアブート版(`/EFI/BOOT/grubx64_real.efi` がある)のディスクに限る。GPT・セキュアブート版でないもの・第 3 以降のパーティションがあるものは拒否する。非セキュアブート版は、本物が呼ぶ `vtoycli partresize -s` を再現していないため扱わない。
- 書き込み前に、先頭 1MiB と第 2 パーティションを `--backup-dir` へ退避し、書き込み後に全領域を読み戻して照合する。書き込みは 512 バイト境界に揃えてある(`/dev/rdisk` は端数の書き込みができない)。
- Mac のデバイスへの書き込みは root が要る。先に `diskutil unmountDisk diskN` でマウントを外す。
- 検証(2026-10-26): Alpine Linux 上の本物の `Ventoy2Disk.sh -I` で作った 2GiB の仮ディスクに、起動コード・コア領域を壊した状態を作り、本物の `-u` とこのスクリプトを同じ入力で実行して比較した。active フラグの入れ替えがある場合とない場合の両方で、先頭 1MiB と第 2 パーティションの先頭 64,883 セクタが完全に一致した。第 2 パーティションの末尾は、Alpine の busybox `dd` が書き漏らして本物の方が欠けた(約 647 セクタ)。Alpine などの busybox 環境では本物の更新スクリプトを使わない。
- 実機での実行(2026-10-26): MBR・第 2 パーティション 32MiB・セキュアブート版の 1TB の USB(第 1 パーティションにデータ約 870GB)で、`update-ventoy-mac.sh` と同じ手順(検査 → 退避 → 書き込み → 読み戻し照合)を実行し、読み戻し照合が成功した。更新後の USB の第 1 パーティションのファイルは無傷だった。更新後の Ventoy を QEMU(UEFI)の仮ディスクで起動し、1.1.18 のメニュー表示を確認した。
- Mac から呼ぶ入口: `bash ventoy/update-ventoy-mac.sh <ボリューム名> <展開した ventoy-X.Y.Z のフォルダ>`(`sudo` のパスワードが要る)。
- Apple 仮想化(UTM の Apple バックエンド)の VM に USB の NVMe ケース(SuperSpeed Plus)を渡すと、`can't set config #1, error -32` で認識できなかった。VM 経由の更新はできない。

## 検査

```sh
make test
```

通信不要の全テストには、統合 ISO 用 JSON の保持・置換・冪等性と、
空白を含むパスの試験を含む。実媒体の更新や ISO の実起動は実行しない。
