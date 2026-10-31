# 統合 ISO の RAM 選択複写 (bootkit-ramsel)

## 動作

カーネル引数に `toram` と `bootkit.os=<os>` (os は `ubuntu`・`lubuntu`・`server`)
の両方があるとき、initramfs の casper-premount 段階で、媒体 (ISO) から
`casper/bootkit-chains/<os>.list` に挙がった層の列だけを tmpfs (`/bootkit-ram`)
へ複写し、casper 本体にはその tmpfs を媒体 (`livefs_root`) として使わせる。
`pool/`・他の OS の層・他の `initrd.<os>`・連鎖に無い層は載らない。
複写後の層の参照先は RAM 内だけで、元媒体のマウントは残らないため、
起動後に USB を抜ける。
複写に失敗したとき (RAM 不足・媒体が見えない・層の欠落・写し誤り) は、
理由を出して停止する (`panic` 相当)。黙って媒体参照のまま続けない。
`toram` が無いとき、または `bootkit.os` が無いときは何もしない
(素の casper の動作)。

層が L 個、合計 S バイトのとき、サイズの見積もり・照合は `stat -c` に
よる O(L)、データ複写は O(S)。`wc` による全データの余計な読み直しを避ける。
`stat -c` が無い単体試験環境では `wc` へ戻る。予期しない I/O の異常終了も
`failed` に残して親が停止できるようにする。子の終了コードも親が照合し、
理由ファイルを残せなかった異常終了も停止する。

RAM の見積もりは複写前に行う。連鎖の合計に 64 MiB の余裕を足した量を
`/proc/meminfo` の `MemAvailable` (無ければ `MemFree`+`Cached`) と比べ、
足りなければ複写を始めずに止める。

## なぜこの接続か

素の casper は `copy_live_to` で媒体のルート全体を複製するため、
層の選択だけでは複製量は減らない。かわりに premount 段階で選択複写し、
その tmpfs を `LIVEMEDIA` 経由で casper に渡す。casper 本体 (`/scripts/casper`)
の置換はしない。置換するのは `/scripts/casper-premount/ORDER` だけで、
標準の 2 行 (`10driver_updates`・`20iso_scan`) に次の 2 段を足したものに
差し替える。理由は、premount の各台本は子プロセスで走り、親のシェル変数を
変えられないため、複写の結果 (`LIVEMEDIA` の切替えと `TORAM` の解除) と
失敗の理由はファイル (`/run/bootkit-ramsel/env`・`failed`) 経由で親へ返す。
`ORDER` 自体は親のシェルで読み込まれるため、この読み戻しと失敗時の
`panic` は親の側で動く。

選ばなかった方式: `/scripts/casper` の置換は、casper の更新のたびに追従が
要り保守の費用が高い。`live-media=` の固定は媒体の装置名を決め打ちに
できない (Ventoy では `/dev/mapper/ventoy`、直起動では `/dev/sr0` など)。
`todisk=` は RAM でなく装置への複写で目的が違う。

## カーネル引数

- `toram`: 選択複写の発動条件の 1 つ。素の casper の複製は抑止される
  (premount が `TORAM` を解除するため、二重の複写は起きない)。
- `bootkit.os=<os>`: 層の連鎖の選択。`casper/bootkit-chains/<os>.list` を読む。
- `layerfs-path=<leaf 層>`: 層の重ね順の指定 (casper の標準引数)。
  実統合 ISO では各 OS の末端層を指定する。
  例: `layerfs-path=common.server.squashfs`。
- `console=ttyS0,115200`: 検証用の serial 出力。実運用には要らない。

`toram` と `bootkit.os` のどちらかが無い起動では本処理は何もしない。
`bootkit.os` があるのに媒体に連鎖が無い起動は、誤った媒体の疑いとして止める。

## T1 とのインターフェース

- 統合 ISO の `casper/bootkit-chains/<os>.list`: 1 行に 1 つの squashfs 名。
  親から子の順。層は `casper/` に置き、名前はドットで短くすると親になる
  (casper の `layerfs-path` の規則)。
- `bootkit.os=<os>` が OS を指定する。
- 本処理は層の中身を見ない。層の再構成と同一性の保証は T1 の担当。
- 実統合 ISO は `tools/ubuntu-merge/assemble.sh` が追加 cpio と GRUB を
  組み込む。Ventoy でも ISO 内の追加 cpio を使う。
- 層名の制約: casper の `layerfs-path` 導出は、末端層から点を1つずつ削って
  親を列挙し、点なし名の層まで要求する。そのため各連鎖の根は点なし名に
  する (例: `server` ← `server.ubuntu-server` ← ...)。
  根に点がある命名 (例: `server.minimal` を根にする) では起動時に
  `File system layers are missing` で止まる。QEMU で実証済み。

## ファイル

`ventoy/ramsel/` に置く。いずれも POSIX sh または標準ライブラリだけの
python3 で、統合 ISO の追加 cpio と検証用アーカイブを生成する。

- `30bootkit-ramsel`: premount の台本 (子プロセス)。媒体の探索・複写・検証と
  `/run/bootkit-ramsel/env`・`failed` の書き出しを行う。
- `ORDER`: 置換する `/scripts/casper-premount/ORDER`。
  標準の 2 行に本台本の呼出しと読み戻し・失敗時の `panic` を足したもの。
- `make-injection.sh`: 上の 2 点を `bootkit-ramsel-injection.tar.gz` に固める。
- `make-cpio.py`: 同じ 2 点を再現可能な gzip/newc に固める。実統合 ISO は
  toram 項目だけ `initrd /casper/initrd.<os> /casper/bootkit-ramsel.cpio.gz` と
  連結指定する。4,238 バイトの追加アーカイブで、3 OS の実 ISO 起動で
  連結後の premount 実行を確認済み。
- `rebuild-initrd.py`: 公式 initrd の主部に上 2 点を入れて再構成する
  (試作 ISO 用。標準 ORDER が想定と違う場合は止める)。
- `make-trial-iso.sh`: 試作の統合 ISO を組む (約 11GB、`build/` に出力)。
- `verify-qemu.py`: QEMU での検証駆動 (下の手順)。UNIX socket が使えない
  環境では `--transport pipe` でワークツリー内の FIFO と stdio を使う。

試験は `tests/test-ramsel.sh` (`make test` に含まれる)。QEMU の実起動は
含まず、構文・`ORDER` の固定・台本の単体試験 (成功・無発動・RAM 不足・
不正な値・欠落層) を行う。

## Ventoy での起動

Ventoy は 1.1.18 以上を使い、ISO 選択後に **Boot in grub2 mode** を選ぶ。
統合 ISO 内の GRUB が OS ごとに `toram bootkit.os=<os> layerfs-path=<leaf>` と
追加 cpio を指定する。injection・conf_replace の設定は不要。
配置と設定は [統合 ISO 用設定](../ventoy/merge/README.md)を参照する。

`make-injection.sh` は同じ premount と `ORDER` を検証用の tar.gz に固める
補助として残す。統合 ISO の通常の起動手順では使わない。

Ventoy 1.1.18 の `default-hook.sh` は `/init` に
`export LIVEMEDIA=/dev/mapper/ventoy` を挿す。本台本は `LIVEMEDIA` を
優先して探索し、premount 後は `LIVEMEDIA=/bootkit-ram` を親へ返す。
`live-media=` は使わず、Ventoy hook は `ORDER` に触らないため、
追加 cpio の読み戻しと競合しない。QEMU では premount 時点で
`/dev/mapper/ventoy` を検出している。

## 検証結果

2026-10-29、`verify-qemu.py` で実統合 ISO の UEFI / GRUB 項目を選択した。
serial で `/proc/cmdline`・`df -B1`・`/proc/meminfo`・`findmnt`・
`/proc/mounts`・`losetup -a` を記録し、HMP で撮影と ISO 排出を行った。
記録は `build/evidence/B2/`。画面は Server が subiquity、Lubuntu が LXQt、
Ubuntu が GNOME のログイン画面と live セッションまでを確認した。

| OS | 選択した層の合計 (バイト) | tmpfs 使用量 (バイト) | 余分 (バイト) | 排出後 |
| --- | --- | --- | --- | --- |
| Server | 1,515,560,960 | 1,515,585,536 | 24,576 | 層の読出し・Python・apt check 成功 |
| Lubuntu | 3,749,933,056 | 3,749,957,632 | 24,576 | 全 3 層読出し・Python・apt check 成功 |
| Ubuntu | 4,722,253,824 | 4,722,278,400 | 24,576 | 全 3 層読出し・Python・apt check 成功 |

`/cdrom/casper` は選択層だけで、pool / 他 OS の層 / initrd は無い。
元 sr0 mount は残らず、層を参照する loop は tmpfs 内を指していた。
HMP の `eject -f cd0` 後、キャッシュを落として読み出し、新規プログラムを
起動した。通常項目の同じ排出対照は、各 OS とも I/O エラーになった。

公式の素 toram は、追加 cpio を付けず元の kernel / initrd で BIOS direct
起動し、同じ q35 / ide-cd 接続で計測した。root の使う層と、casper が
コピーする媒体全体の量を分けて比較する。

| OS | 公式の素 toram 使用量 (バイト) | 選択コピー使用量 (バイト) | 減った量 (バイト) |
| --- | --- | --- | --- |
| Server | 2,921,447,424 | 1,515,585,536 | 1,405,861,888 |
| Lubuntu | 3,921,702,912 | 3,749,957,632 | 171,745,280 |

公式 Server / Lubuntu の `MemAvailable` は、それぞれ 2,529,776 /
1,629,928 KiB。元の媒体全体を載せるため、選択層以外の pool・boot・initrd も
含む。証拠の接頭辞は `official-server-toram` / `official-lubuntu-toram`。
統合 ISO の UEFI 起動そのものとは bootloader の条件が異なる。

RAM 不足は Server toram / 1,280MiB の VM で確認。必要 1,582,669,824 バイト、
利用可能 1,028,845,568 バイトと表示し、コピー前に initramfs shell で停止した
(`server-short-1280`)。元媒体を参照したまま黙って起動を続けることはなかった。
追加 cpio の連結は実起動で動作したため、公式 initrd の再構成は不要だった。

## 既知の制約・未確認の点

- 実機・Secure Boot は未検証。Ventoy の QEMU 起動は下記参照。
- 実統合 ISO は全 9 項目で `layerfs-path` と `bootkit.os` を明示する。
  層の選択は `layerfs-path`、RAM 選択複写の選択は `bootkit.os` が担う。
- GUI の確認は起動画面と Lubuntu の Try 選択まで。通常のアプリの
  GUI 操作や、日本語表示・入力・インストールは未検証。
- 再層化 (B2) 後の層名・連鎖が変われば、`.list` と `layerfs-path` を
  合わせ直す (本処理の変更は要らない)。

## Ventoy 1.1.18 の経路

QEMU/UEFI の 3 OS と BIOS の Server の Ventoy GRUB2 モードでは、ISO 内の GRUB と追加 cpio が
読み込まれ、premount が `/dev/mapper/ventoy` を検出した。媒体の探索方法は
直起動と共通で、変更していない。injection や conf_replace を設定しない
ディスクでの実測である。取り外し後も未マウントの mapper が残り、Server では
その mapper に Buffer I/O エラーが出た。層の読出し・Python・APT は成功した。
OS ごとの起動・取り外し結果と通常モードの制約は
[Ventoy QEMU 検証](ventoy-qemu.md)を参照する。
