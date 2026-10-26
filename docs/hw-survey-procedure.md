# 実機を Live USB から検査する

ディスクに書き込む検査をせず、機種・電池・SMART・入力・表示・冷却の情報を集める。画面とログは日本語フォントのない tty でも読める ASCII 英語で表示する。自動で取得できた範囲を `GOOD`(良)・`FAIR`(可)・`BAD`(不可)で示し、情報が無ければ `N-A`(未取得)、動作を試していなければ `UNTESTED`(未試験)とする。`N-A`・`UNTESTED` は合格を意味しない。注意は `WARN`、目安は `HINT`、手動確認は `MANUAL`、目視・照合は `CHECK` と表示する。認識しただけの入力機器やポートを動作確認済みとは扱わない。

## 準備と起動

1. Ventoy の USB に `bootkit-linux-amd64-cli.iso` を入れておく。
2. 検査したい HDD・USB をすべて接続し、AC アダプタを接続する。
3. Ventoy でその ISO を選び、起動メニューで該当する項目を選ぶ。

| 機種 | 起動メニュー |
| --- | --- |
| その他(generic) | `Hardware survey: generic, auto` |
| Lenovo G560 / 0679 / 20042 | `Hardware survey: Lenovo G560, auto` |
| ThinkPad Edge 14 / 0578 | `Hardware survey: ThinkPad Edge 14 (0578), auto` |

いずれも `bootkit.safe=1` を付けた安全モードで起動し、tty1 で自動検査する。検査終了後は要約を残して Enter を待つ。撮影してから Enter を押すとシェルに戻る。通常起動では自動検査しない。arm64 にこの起動メニューはない。

端末からは `survey` の 6 文字で機種を自動判定できる。root 以外なら sudo で再実行する。

```sh
survey
survey --list
survey --profile edge14-0578
survey --profile g560
survey --profile generic
survey --long
```

機種判定には DMI の製品名・版・ファミリーを使い、CPU も記録する。対応機種と判定できない場合は generic にする。機種を指定した場合はその指定を優先する。

## 自動で行うこと

機種を確定し、電池・BIOS・SMART・Security と、アイドル温度・入力・rfkill・USB・DRM を取得する。内蔵の固定ディスクだけを `hdparm -t --direct` で 3 回読み、中央値を出す。CPU は `stress-ng --cpu 2 --timeout 180s` で負荷を掛け、温度とクロックを監視する。crit の 5°C 手前に達するか温度を取得できなくなれば負荷を止める。アイドル温度や負荷コマンドが取得できない場合は冷却を未試験とする。

実行の初めに `swapoff -a` で swap を停止する。停止に失敗した場合は CPU 負荷・メモリ試験を省略する。BIOS・SATA モード・ファン・電池の設定は変えない。無線や有線の情報は読み取りだけで、接続やネットワークへの送信はしない。

`hw-survey --speed` の詳細と `disk-guard-suggest` の対象案も RAM に保存する。対象案は表示するだけで、消去コマンドを実行しない。SMART の情報取得は USB も対象だが、SMART 自己診断と読み出し速度測定は USB・取り外し可能媒体・Live の起動媒体を除外する。起動媒体の親ディスクを判定できなければ、測定と自己診断をすべて省略する。

## 撮影とログ

撮影するのは検査終了時の要約画面。要約は 1 行 80 桁・全体 40 行以内で、長い行の末尾は `...` で省略し、全文は `summary-body.txt` と詳細ログに残す。機器が多い場合は残りを詳細ログに残す。長い `disk-guard.sh --expect` のコマンドは詳細ログの参照先を表示する。例は表示項目を抜粋した架空の値で、実測結果ではない。

```text
== ThinkPad Edge 14 / 0578 / edge14-0578 ==
Model: 0578TEST / ThinkPad Edge / ThinkPad Edge
CPU: Intel Core i5
BIOS: 80ET65WW (FAIR; legacy: no EFI variables is normal)
PCI: GOOD (expected IDs match)
BAT1: FAIR 60.0% design 47.52Wh (HINT 47.52Wh; no cycle rating)
Memory: 4.00 GiB / 1067 MT/s/ / FAIR (HINT ~1067MT/s) (slots/parts in logs)
Disk sda: FAIR  5=0 197=0 198=0  SATA:3.0Gb/s (HINT 3.0Gb/s) Security sda: ...
sda: median 85.00 MB/s (HINT: FAIR; HDD 5400:70-110 / 7200:100-130)
Cooling: GOOD idle=52/max=75C (HINT 45-65; crit=100) MHz=N-A-N-A
SMART long / RAM test: UNTESTED (enable with --long)
MANUAL: CMOS battery / HDD and Supervisor passwords
CHECK: dead pixels[ ] hinges[ ] keys[ ] fan noise[ ]
Ports: eSATA / ExpressCard / VGA / HDMI UNTESTED without devices
Logs(RAM): /run/survey.XXXXXX
GOOD/FAIR/BAD: measured scope only. N-A/UNTESTED do not mean PASS.
Press Enter after taking a photo
```

ログの保存先は画面に表示する `/run/survey.XXXXXX/`。保存先が tmpfs・ramfs・overlay であることを作成前に確認する。それ以外や判定不能なら中止する。電源を切るとログは失われる。スロットごとの Size・Speed・Part Number、SMART の属性、無線の帯域、Security、センサーの詳細はログで読む。

## 所要時間と長時間検査

短いコースは起動・目視を含め約 30 分が目安。CPU 負荷は 180 秒で、ディスク台数や応答時間によって全体の時間は変わる。

長時間検査は起動メニューではなく端末から `survey --long` を実行する。通常の検査に加えて SMART long と memtester の 1 パスを実行する。メモリは実行時の `MemAvailable` の半分以下を確保し、swap を停止できたときだけ検査する。SMART long は対象ディスク同士を並列実行し、結果を回収する。待機は最大 6 時間で、時間切れ・未対応・結果未取得を合格にしない。

所要時間 1.5〜3 時間は推測であり、容量・CPU・メモリ量・媒体の状態で変わる。SMART 自己診断はユーザーデータを書き換える試験ではないが、媒体自身の内部処理や診断履歴の更新まで止めるものではない。

## 異常の読み方

- SMART 197(保留中)・198(訂正不能)が非 0 なら、総合判定が PASSED でも不可。5(代替処理済み)が非 0 なら注意。187・196・199・10・194 も記録する。属性の生の単位や意味は機種に依存する。
- ATA Security の locked は不可。enabled と frozen も記録し、frozen は正常として扱う。解除やパスワードの設定はしない。
- 読み出し速度の中央値が 40MB/s 未満なら不可という目安。5400rpm の 70〜110MB/s、7200rpm の 100〜130MB/s は推測。SSD の上限としては使わない。SATA の 3.0Gb/s、メモリの 1067MT/s 前後、アイドルの 45〜65°C も目安で、取得値と一緒に読む。800MT/s、`limiting speed`、PIO は注意として記録する。
- 電池の満充電容量 / 設計容量が 70%以上なら良、50〜69%なら可、50%未満なら不可。これも利用判断の目安であり推測。sysfs の設計値を優先し、設計値が無ければ健康度を計算しない。
- PCI や BIOS の期待値との不一致は故障と断定しない。G560 は `HINT mismatch (update needed)`(初期値と違う・要更新)と表示し、実測値を更新材料にする。

## 機種ごとの注意

ThinkPad Edge 14 / 0578 は Arrandale/HM55 世代。tp_smapi は使えず、電池の cycle_count が 0 でも劣化判定に使わない。ファンの読み値は不確実なので、無い場合も故障にしない。レガシー BIOS のため EFI variables 非対応は正常。TrackPoint 未認識は異常候補として手動確認する。Intel 1000 の 2.4GHz のみは正常で、6200 は 5GHz にも対応する。有線 100Mb/s はケーブルや相手機器を含めて確認する。従来のドック用コネクタは対象外。

Lenovo G560 / 0679 / 20042 の機種固有値は未確認の初期値。GPU は UMA / DIS、SATA は AHCI / IDE を記録し、変更しない。10de:0a70 があり BIOS が 29CN31WW より古い場合、画面異常を既知の VBIOS 不具合の範囲として記録する。10ec:8136 の LAN は 100Mb/s が正常で、ギガビットと確認できた構成だけ 1000Mb/s を目安にする。メモリの公式上限は 8GB で、SMBIOS の 16GB 表記は保証ではない。TrackPoint・thinkpad_acpi・指紋・TPM が無くても減点しない。無線の Hard blocked と本体のワイヤレススイッチ位置を併せて記録する。

CMOS 電池・HDD/Supervisor パスワードは Linux から確実には分からないため手動確認する。液晶のドット抜け、ヒンジの割れ、キー打鍵、ファン音は目視欄に記録する。

## やってはいけないこと

書き込む検査(`badblocks -w/-n`、fio の write、`stress-ng --hdd`、`nvme format`、`dd of=/dev/…`)、ATA Security 操作、BIOS 更新、SATA モード変更をこの手順に足さない。安全モードはハードウェアの書き込み防止装置ではなく、管理者が別のコマンドを実行したときの書き込みまでは防がない。

この変更を含む ISO のビルド、QEMU、実機での自動起動と画面表示は未検証。
