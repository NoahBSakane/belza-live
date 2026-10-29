# 統合 ISO の RAM 選択複写 (bootkit-ramsel)

現行の仕様を中心に書く。経緯は書かない。未確認の点は末尾に集める。

## 動作

カーネル引数に `toram` と `bootkit.os=<os>` (os は `ubuntu`・`lubuntu`・`server`)
の両方があるとき、initramfs の casper-premount 段階で、媒体 (ISO) から
`casper/bootkit-chains/<os>.list` に挙がった層の列だけを tmpfs (`/bootkit-ram`)
へ複写し、casper 本体にはその tmpfs を媒体 (`livefs_root`) として使わせる。
`pool/`・他の OS の層・他の `initrd.<os>`・連鎖に無い層は載らない。
複写後に元の媒体の参照は残らないため、起動後に USB を抜ける。
複写に失敗したとき (RAM 不足・媒体が見えない・層の欠落・写し誤り) は、
理由を出して停止する (`panic` 相当)。黙って媒体参照のまま続けない。
`toram` が無いとき、または `bootkit.os` が無いときは何もしない
(素の casper の動作)。

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
  試作 ISO では各 OS の末端層を指定する。
  例: `layerfs-path=server.minimal.server.installer.generic.squashfs`。
- `console=ttyS0,115200`: 検証用の serial 出力。実運用には要らない。

`toram` と `bootkit.os` のどちらかが無い起動では本処理は何もしない。
`bootkit.os` があるのに媒体に連鎖が無い起動は、誤った媒体の疑いとして止める。

## T1 とのインターフェース

- 統合 ISO の `casper/bootkit-chains/<os>.list`: 1 行に 1 つの squashfs 名。
  親から子の順。層は `casper/` に置き、名前はドットで短くすると親になる
  (casper の `layerfs-path` の規則)。
- `bootkit.os=<os>` が OS を指定する。
- 本処理は層の中身を見ない。層の再構成と同一性の保証は T1 の担当。
- T1 の ISO ができたら、試作 ISO は捨て、`ventoy/ramsel/` の成果物
  (下の injection) を載せ替える作り。
- 層名の制約: casper の `layerfs-path` 導出は、末端層から点を1つずつ削って
  親を列挙し、点なし名の層まで要求する。そのため各連鎖の根は点なし名に
  する (例: `server` ← `server.ubuntu-server` ← ...)。
  根に点がある命名 (例: `server.minimal` を根にする) では起動時に
  `File system layers are missing` で止まる。QEMU で実証済み。

## ファイル

`ventoy/ramsel/` に置く。いずれも POSIX sh または標準ライブラリだけの
python3 で、Ventoy の injection に載せる前提の成果物である。

- `30bootkit-ramsel`: premount の台本 (子プロセス)。媒体の探索・複写・検証と
  `/run/bootkit-ramsel/env`・`failed` の書き出しを行う。
- `ORDER`: 置換する `/scripts/casper-premount/ORDER`。
  標準の 2 行に本台本の呼出しと読み戻し・失敗時の `panic` を足したもの。
- `make-injection.sh`: 上の 2 点を `bootkit-ramsel-injection.tar.gz` に固める。
- `rebuild-initrd.py`: 公式 initrd の主部に上 2 点を入れて再構成する
  (試作 ISO 用。標準 ORDER が想定と違う場合は止める)。
- `make-trial-iso.sh`: 試作の統合 ISO を組む (約 11GB、`build/` に出力)。
- `verify-qemu.py`: QEMU での検証駆動 (下の手順)。

試験は `tests/test-ramsel.sh` (`make test` に含まれる)。QEMU の実起動は
含まず、構文・`ORDER` の固定・台本の単体試験 (成功・無発動・RAM 不足・
不正な値・欠落層) を行う。

## Ventoy の injection への載せ方

アーカイブの作り方:

```sh
sh ventoy/ramsel/make-injection.sh
```

`ventoy/ramsel/bootkit-ramsel-injection.tar.gz` ができる。中身は次の 2 点で、
initramfs の `/` に展開される前提の配置である。

```text
scripts/casper-premount/30bootkit-ramsel
scripts/casper-premount/ORDER
```

`ventoy.json` の `injection` への書き方の案 (統合 ISO の項目ごと):

```json
{
  "injection": [
    {
      "image": "/ISO/bootkit-ubuntu-merge.iso",
      "archive": "/ventoy/bootkit-ramsel-injection.tar.gz"
    }
  ]
}
```

grub 項目 (T1 の `conf_replace` で置く `grub.cfg`) には OS ごとに
`toram bootkit.os=<os> layerfs-path=<leaf>` を付ける。

Ventoy 1.1.18 の `default-hook.sh` との干渉の調査結果
(読んだ箇所と結論。実起動は後の作業で、QEMU 直起動で検証した範囲):

- hook は `/init` に `export LIVEMEDIA=/dev/mapper/ventoy` を挿す。
  本台本は媒体の探索で `LIVEMEDIA` を最優先で試すため、Ventoy 媒体に
  対応できる。直起動 (`/dev/sr0` など) は装置走査で見つける。
- hook が `/scripts/casper` の `LIVEMEDIA=` 代入を書き換えるのは
  `live-media=` が引数にある場合だけ。本方式は `live-media=` を使わない
  (premount 後に `LIVEMEDIA=/bootkit-ram` を親へ返す) ため、この書換えと
  競合しない。
- hook は `ORDER` に触らない。置換 `ORDER` との競合は無い。
- `find_cow_device` の差し込みは永続化を使う場合だけ関係する。
  本方式は `NOPERSISTENT=Yes` で動くため関係しない。
- premount 時点で `/dev/mapper/ventoy` が見えるかは、Ventoy の実起動で
  確かめるまでは未確認。見えない間の再試行 (約 30 秒) は入れてある。

## 検証結果

検証の駆動は `ventoy/ramsel/verify-qemu.py`。試作 ISO を UEFI (OVMF) で
起動し、grub 項目を番号で選ぶ。serial (`ttyS0`) でログイン・操作し、
HMP で撮影と ISO の取り外しを行う。公式 ISO の比較・対照は BIOS +
`-kernel`・`-initrd`・`-append` で起動する (比較対象の版を変えないため。
媒体の扱いは起動方式に依らない)。

(以下、実測値を書く)

## 既知の制約・未確認の点

- 実機・Ventoy の実起動・Secure Boot は未検証。
- 試作 ISO を `bootkit.os` 無しで起動すると、3 OS の層が混ざって重なる。
  T1 の `grub.cfg` は全項目に `bootkit.os` を付けること。
- GUI のメニュー操作は serial 経由の shell 操作と撮影で代用し、
  項目を開く操作までは行っていない。
- premount 時点の `/dev/mapper/ventoy` の可視性は未確認 (再試行あり)。
- 再層化 (B2) 後の層名・連鎖が変われば、`.list` と `layerfs-path` を
  合わせ直す (本処理の変更は要らない)。
