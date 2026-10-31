# 統合 ISO の Ventoy QEMU 検証計画

対象は作業ツリー内に新規作成する 13 GiB の仮想ディスクのみ。入力 ISO は
読み取り専用とし、ネットワーク・実媒体を使わない。実行上限は 4 時間。
空き容量 10 GiB 未満なら新しい処理を止める。同時 QEMU は 2 台、RAM 合計
14 GiB 以下とする。

## 問いと判定

- プラグインなしで ISO 内の 9 項目と追加 cpio が有効か、注入・置換が要るか。
  Ventoy メニューと ISO GRUB の画像、カーネル引数、premount ログを記録する。
- premount で Ventoy の mapper が見えるか。媒体名と選択した層をログで確認する。
- toram が選択した OS の層だけを複写し USB を外せるか。
  tmpfs の使用量、全 mount、loop、device-mapper、USB 削除後の全層読出し、
  Python の新規起動、apt-get check を記録する。
- 対立する結果は、正しい連鎖だけが tmpfs にある場合と、元媒体を参照する場合。
  既存 CD-ROM 対照では toram の読出し成功と通常起動の I/O エラーが記録済み。
  今回も通常項目を USB 取り外しの対照とする。対照で判別不能なら断定しない。

## 順序・打ち切り

1. Alpine/HVF で Ventoy2Disk.sh -I の MBR ディスクを作る。区画・版・EFI の
   バイトを確認し、第 1 区画へ ISO を 1 回だけコピーする。
2. プラグインなしの Server toram を起動する。メニュー到達と premount の
   選択複写成功を基準に次へ進む。失敗は画面・ログから原因を絞る。
3. Server の取り外し、Lubuntu、Ubuntu、通常項目の対照を実施する。
   独立した読出し専用起動は並行可能。ディスク作成中は起動しない。
4. 設定の雛形と文書を実測に合わせ、make test と Markdown 検査を実行する。

起動待ちは 1 回 60 分以内とし、120 秒ごとの画像と serial の更新を確認する。
2 回方式を変えても原因が不明なら計画を見直す。期限までに終わらない場合は
証拠・再開手順と実施していない範囲を残す。実機・Secure Boot は対象外。

## 第 1 回の観測と方式の見直し

Alpine の glibc 向け formatter は musl loader と `__fxstat64` の薄い互換
ライブラリで実行でき、元の `-I` は成功。exFAT は明示した `-t exfat` で
マウントできた。EFI 区画の末尾の欠落は配布物の同じ区画から補完し、全域一致。

Ventoy の通常モードは `Failed to open \\EFI\\BOOT\\ - No mapping` の後に
8 × 32 ピクセルの黒画面となり、ISO メニューは観測できなかった。
タイマーだけで進める自動操作は、この状態を成功とは判定できない。
次は GRUB2 モードで shim の連鎖を避け、ISO の grub.cfg に到達するかを観測する。
ISO 内の設定を変える前に、起動モードの影響を区別する。

## 判定の材料の実測基準

既存 B2 の `server-toram-delivery-clean.txt` は、CD 排出後に
`READ_LAYER_COUNT=2`、`MEDIA_READ_RC=0`、`PY_OK`、`APT_RC=0` を記録。
`server-normal-v3.serial.log` は同じ排出後に `Input/output error` を記録している。
原本は兄弟作業ツリー `ubuntu-merge/build/evidence/B2/` で読み取り確認した。
この差を基準に、今回もキャッシュを落とした全層読出しとプログラムの新規起動を
使う。単に起動済みの画面が残ることは、取り外し成功の根拠にしない。

読み取り専用の仮想 USB では GRUB2 の kernel/initrd までは読めたが、
Ventoy の mapper 作成が `-EROFS` で失敗した。書込み可能な qcow2 差分では
同じ経路から `/dev/mapper/ventoy` を検出し、Server の選択複写を実行できた。
以後は raw を保持する個別の qcow2 差分で実施する。
