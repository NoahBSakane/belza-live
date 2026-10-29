# 統合 ISO のインストール検証

実行担当が QEMU で行う検証。単体試験の偽 mount では、initrd 内の道具・実 squashfs・パッケージ整合性は検証できない。2026-10-29 に、amd64(UEFI)・arm64(UEFI)の icewm・lxqt・cli と、amd64 の `bootkit.flavor=` なしの導入を実施した。結果は末尾の『結果(2026-10-29)』。下の手順のうち、amd64 BIOS の導入・Calamares・フレーバーの未知の値・層の欠落・mount 失敗の異常系は未実施。

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

## 結果(2026-10-29)

対象は commit 31193a8 の CI(run 40729162574)の ISO。SHA-256 は amd64
`ff624d4e4655a57d72f98feebe0e7b72f15694ef3671df126203e18f65bd8403`、
arm64 `8d40589fe13b987d6eb483f426c091c3cbbeec535560410d7ebbea5d9a90a645`。
QEMU は 11.1.2。amd64 は TCG、arm64 は HVF(Apple Silicon)。
UEFI は edk2、ネットワークなし(`-net none`)。
試験ディスクは新規の空の 32GiB qcow2(virtio)。

メニューは amd64(UEFI・BIOS)と arm64(UEFI)で確認した。
トップ 6 項目(先頭・既定が Live (icewm))、Other flavors(cli・lxqt)、
Safe / Survey、Start installer の 3 項目(各 `bootkit.flavor=` を確認)、
Advanced install options、Utilities を確認した。
Live の icewm・cli・lxqt(`module=` 値、cli は icewm と startlxqt が無いこと)が起動した。

導入は `Start installer` の各フレーバーで、すべて合格した。

| アーキテクチャ | フレーバー | `bootkit-layer:` の syslog | 導入後の使用容量 |
| --- | --- | --- | --- |
| amd64 | icewm | bytes=386256896、seconds=144、offline で成功 | ― |
| amd64 | lxqt | bytes=2414972928、seconds=1395(TCG)、offline で成功 | 9.0G / 29G |
| amd64 | cli | 行なし(`00bootkit-layer` は無言で終了) | 2.6G / 29G |
| amd64 | `bootkit.flavor=` なし | cli と同じ(行なし、`/target` に icewm・startlxqt なし) | ― |
| arm64 | icewm | bytes=368545792、seconds=24、offline で成功 | ― |
| arm64 | lxqt | bytes=2317918208、seconds=170、offline で成功 | 9.5G / 29G |
| arm64 | cli | 行なし | 3.1G / 29G |

導入後は全 7 通りで共通の確認をした。
作成ユーザーでログインした。
`dpkg --audit` が無出力、`apt-get check` が終了 0。
icewm は IceWM、lxqt は LXQt のセッションが起動した。
cli は icewm・startlxqt が無い。

観察(合否に影響なし)は次のとおり。

- 導入後の LXQt のセッションで Ctrl+Alt+T が反応しなかった(Alt+F2 の runner から端末は起動できた。原因は未調査)。
- cli の導入では `bootkit-layer:` の行が出ない(層なしの表明の行は無い)。
- 導入システムの `/proc/cmdline` に `bootkit.flavor=` は無い(導入システム独自の cmdline のため)。

未実施は amd64 BIOS(syslinux)での導入、実機(Ventoy からの起動)、
Calamares、フレーバーの未知の値・層の欠落・mount 失敗の異常系。
