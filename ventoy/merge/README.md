# 共通層の統合 ISO 用 Ventoy 設定

`ubuntu-merge-26.04.1-amd64.iso` を `/ISO/live/` に置き、Ventoy 1.1.18 以上の
ISO 選択後に **Boot in grub2 mode** を選ぶ。ISO 内の通常・safe graphics・
copy to RAM の 9 項目を使う。通常の Ventoy 起動モードは今回の QEMU/UEFI
では `Failed to open \EFI\BOOT\ - No mapping` となった。

`ventoy.json` は表示名だけを定義する雛形である。injection と conf_replace を
設定していない状態で、3 OS の toram 起動と USB 取り外し後の
全層読出し・新規 Python・APT の成功を確認した。
各 OS の起動・取り外し結果は [検証記録](../../docs/ventoy-qemu.md) を参照。

既存の JSON へは次で統合する。関係のない設定を保持し、同じ ISO の表示名は
重複させない。既存の injection・conf_replace は変更しないので、対象 ISO に
以前の試験設定を入れていた場合は、その内容を別途照合する。

```sh
python3 -I ventoy/merge-ventoy-json.py existing.json merged.json
```

RAM 選択複写は ISO 内の追加 cpio を使う。起動時の `toram` と
`bootkit.os=<os>` が必要で、ISO 内の copy to RAM 項目が両方を渡す。
Ventoy GRUB2 モードでは `rdinit=/vtoy/vtoy` も付く。
