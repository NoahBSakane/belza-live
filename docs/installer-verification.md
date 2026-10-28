# 統合 ISO のインストール検証

実行担当が QEMU で行う検証。単体試験の偽 mount では、initrd 内の道具・実 squashfs・パッケージ整合性は検証できない。2026-10-29 時点で、以下の実インストールは未実施。

## 対象と隔離

amd64 BIOS、amd64 UEFI、arm64 UEFI のそれぞれで、icewm・lxqt・cli の3通りを別々の新規空ディスクに導入する(計9通り)。ホストの物理ディスク・USB・既存の VM ディスクは接続しない。`qemu-img create -f qcow2 <専用パス> 32G` で試験用ディスクを作り、対応する QEMU に `-drive file=<専用パス>,format=qcow2,if=virtio` と ISO を渡す。UEFI の可変領域も試験ごとに分ける。既存の `tests/qemu-boot.py` はディスクを接続しない起動試験用なので、導入は別の QEMU コマンドで行う。

## d-i の3フレーバー

1. トップの6項目、先頭・既定の `Live (icewm)`、Other flavors と Safe / Survey の中身を確認する。amd64 の survey は3機種、arm64 は自動 survey なし。各 Live 項目のカーネル行で、module と safe/survey/toram の引数も確認する。
2. `Start installer` から検査対象の `Start installer (<flavor>)` を選び、カーネル行に対応する `bootkit.flavor=` があることを確認する。
3. d-i の shell で `/proc/cmdline` と `/usr/lib/live-installer.d/00bootkit-layer` の存在・実行権を確認する。getfattr/setfattr、tar、squashfs mount の利用可否も記録する。
4. 空の試験ディスクだけを対象に、区画・ユーザー・bootloader を設定して完了する。GUI の層移植がオフラインで可能なことを確かめる回は、ネットワークアダプターを付けず、ネットワークミラーを使わない。通常の d-i が追加取得を要求する場合は、それと層移植を分けて記録する。
5. `/var/log/syslog` の `bootkit-layer:` に、フレーバー・サイズ・秒数・`layer applied (offline)` があることを確認する。cli では層を移植しない。導入後に調べられるよう installer のログを保存する。
6. ISO を外してディスクから再起動し、作成したユーザーでログインする。root で `dpkg --audit` が無出力、`apt-get check` が終了コード0になることを確認する。
7. icewm は IceWM セッション、lxqt は LXQt セッションを起動し、端末を開く。cli は GUI が入っていないことを確認する。hostname・locale・fstab、再生成した initrd と bootloader、ユーザーと権限も確認する。

## Calamares と異常系

LXQt の Live セッションから、同じ隔離条件で Calamares を起動する。`/etc/calamares/modules/unpackfs.conf` の2 entry とログの展開順(基本 → LXQt)を確認する。導入後は上と同じ再起動・dpkg・apt・GUI の確認を行う。

d-i は別の空ディスクで、引数なし、cli、未知の値、および媒体の層がない条件も試す。引数を外す試験以外では installer のほかの引数を保つ。層欠落・mount 失敗は理由を表示して CLI のまま継続することを確認する。whiteout/opaque は ISO ビルド時に拒否されるため、実インストール試験用の通常 ISO に混入させない。

結果には ISO の SHA-256、コミット、QEMU の版・アーキテクチャ・firmware、選択フレーバー、各コマンドの出力と終了コード、GUI の結果、未完了の段階を記録する。コピー・属性復元に失敗したログがあれば、成功扱いにしない。
