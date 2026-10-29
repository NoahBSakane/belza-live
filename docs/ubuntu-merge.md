# Ubuntu Merge (案 B2):共通の層を共有する統合 ISO

公式の Ubuntu desktop・Lubuntu・Ubuntu Server(いずれも 26.04.1 amd64)を、
共通の層を共有する 1 つの ISO に統合する。3 つの OS を別々に持つ案
(B1)は採らない。各 OS の起動では、その OS の層の列だけが RAM に載り、
載る量は本物の ISO の層の合計と同じ程度に収める。

現行の仕様を中心に書く。経緯は書かない。

## 層の割り当て

各 OS の層(起動に使う squashfs の列)は次のとおり。同一ディレクトリ
(`/casper`)に置き、leaf の名前をドットで短くしていって親を探す
casper の `layerfs-path` の規則に従う。

| 層ファイル | 内容 | 使う OS | 層のサイズ |
| --- | --- | --- | --- |
| `common.squashfs` | 3 OS で同一のファイル(パス・種別・内容・モード・所有者・xattr・リンク先が一致) | 全部 | 1,297,661,952 |
| `common.dl.squashfs` | desktop と Lubuntu だけに同一であるファイル | Ubuntu・Lubuntu | 472,125,440 |
| `common.dl.ubuntu.squashfs` | Ubuntu の残り(固有 + desktop-Server 共通の複製) | Ubuntu | 2,952,462,336 |
| `common.dl.lubuntu.squashfs` | Lubuntu の残り(固有 + Lubuntu-Server 共通の複製) | Lubuntu | 1,980,138,624 |
| `common.server.squashfs` | Server の残り(固有 + 両共通の複製) | Server | 217,894,912 |

5 層の合計は 6,920,283,264 バイト(6.45GiB)。本物の主要 10 層の合計
10,088,198,336 バイト(9.40GiB)に対して 3.17GB の削減である。

起動の連鎖(`casper/bootkit-chains/<os>.list`。親から子の順。T2 との
インターフェースで変えない):

- Ubuntu (`bootkit.os=ubuntu`): `common.squashfs`、`common.dl.squashfs`、
  `common.dl.ubuntu.squashfs`。`layerfs-path=common.dl.ubuntu.squashfs`
- Lubuntu (`bootkit.os=lubuntu`): `common.squashfs`、
  `common.dl.squashfs`、`common.dl.lubuntu.squashfs`
- Server (`bootkit.os=server`): `common.squashfs`、`common.server.squashfs`

範囲の定義:各 OS の「全層」は次の主要層だけを指す。desktop の言語・
secureboot 派生層(`minimal.de` など約 40 層)は対象外で、統合 ISO には
入れない(起動の既定項目に影響しない。Secure Boot の要否は未確認)。

- Ubuntu: `minimal` ← `minimal.standard` ← `minimal.standard.live`
- Lubuntu: 同名 3 層
- Server: `ubuntu-server-minimal` ← `.ubuntu-server` ← `.installer`
  ← `.installer.generic`

重ねの意味は overlayfs と同じで、上層の非ディレクトリは同パスと
下層サブツリーを隠す。whiteout は使わない(各 OS の各パスは連鎖中の
ちょうど 1 層に入る)。

共有できない重複の扱い:desktop と Server だけに共通のファイル
(非圧縮 24MB、約 8MB 相当)と Lubuntu と Server だけに共通のファイル
(非圧縮 70MB、約 25MB 相当)は、層を増やす費用と比べて複製する。
層の木では両立しない集合(共通集合が包含関係にない)は共有できない。
重複の合計は圧縮後で約 33MB で、ISO 全体(約 10GB)の 0.4% 未満である。

ハードリンク(nlink>1)のパスとデバイスへのハードリンク先は、
inode の共有を保つため共有対象から外して各 OS の leaf に入れる。
デバイスとその peer は同じ層に同居させる。

## 層の作り方

層は本物と同じ圧縮・ブロックサイズ(xz、128KiB)で作る。
macOS では root なしで所有者・デバイスノード・xattr を展開できない
ため、展開物のメタデータは使わず、次で再現する:

- 実体(通常ファイル・symlink・fifo)は `unsquashfs` で取り出す。
  case-sensitive な作業場所が要る(terminfo など大文字小文字だけが
  違う同名がある)。デバイス・ソケットとデバイスへのハードリンクは
  展開せず疑似で作る。
- `unsquashfs -pf -` のメタデータ部を `tools/ubuntu-merge/pf2pseudo.py`
  で `mksquashfs -pf` 用に変換する(D/R/S→M、C/B 作成、L→M または
  疑似への L、x 維持。根 `/` は除き `-force-uid 0 -force-gid 0` で付ける)。
- M 行は raw パス順(親が子より先)に並べる。子より後だと mksquashfs
  が自動生成の親と「違う定義」とみなして無視する。
- `-pseudo-override` で所有者を上書きする。macOS 由来の
  `com.apple.*` xattr は `-xattrs-exclude` で除く。

各層の `.manifest`・`.size` などは `casper/bootkit-meta/<os>/` に
そのまま保存する(インストーラの検証用。起動には使わない)。

## 同一性の検証

`make verify-ubuntu-merge` が各 OS について、本物の全層を重ねた
ビューと新しい層の連鎖を重ねたビューを比べる。比較項目はパス集合・
種別・モード・所有者・xattr・symlink 先・通常ファイルの SHA-256・
デバイス番号で、時刻は数えるだけで合否に使わない。検証は ISO の
中身(取り出した層)から行う。対照試験として、同一層では一致する
ことと、1 ファイルを書き換えた層では不一致になることを確認する
(`tests/test-ubuntu-merge.sh` の合成試験)。

検証の結果(制御条件。組み立てた `build/layers` でも ISO から
取り出した層でも同じ):

- Ubuntu: 228,781 パス一致、差 0(時刻の扱いを除く差 0)
- Lubuntu: 302,726 パス一致、差 0(時刻差 18,075)
- Server: 110,345 パス一致、差 0(時刻差 14,015)

時刻差は共有化の副作用で、下層に共通ファイルが降りた OS に出る
(Ubuntu は 0)。合否には使わない。不一致の検出の対照試験は合格
(1 ファイル書き換えで失敗する)。

## ISO の組み立て

`tools/ubuntu-merge/assemble.sh` で作る。載せる物:

- `/casper`: 新層 5 個、3 つの initrd(`initrd.ubuntu`・`initrd.lubuntu`・
  `initrd.server`)、共通の `vmlinuz`(3 ISO で同一ハッシュ)、
  `bootkit-chains/`、`bootkit-meta/`
- `/boot/grub`: desktop の物を土台に 9 項目(3 OS × 通常・toram・
  safe graphics)。各項目は `bootkit.os=<os>` と層の leaf を指す
  `layerfs-path=`、`initrd` を渡す。`live-media-path` は既定(casper)。
- `/EFI`、`.disk/`(info は統合の名前。casper-uuid は desktop の物)、
  `pool/`(3 OS の和集合。同パスは同サイズを確認済みで競合なし)。
  `--no-pool` で pool なし版も作れる。
- BIOS(El Torito + MBR)・UEFI(El Torito Alt-Boot + GPT)で起動できる。

素の casper の `toram` は ISO 全体を RAM に載せる。この ISO でも同じ
挙動が既定である。RAM に選んだ層だけを載せる処理は T2 の範囲で、
この ISO の仕様ではない。

統合 ISO(`build/ubuntu-merge-26.04.1-amd64.iso`, VolId
`Ubuntu-Merge 26.04.1 amd64`)は 9,644,701,696 バイト(8.98GiB)。
3 つの本物の ISO の合計 13,337,823,232 バイト(12.42GiB)に対して
3,693,121,536 バイト(27.7%)の削減である。

各 OS の連鎖の合計(起動でその OS の層の列として RAM に載る量。
T2 の処理の対象):

- Ubuntu: 4,722,249,728(本物の層合計 4,815,302,656 の 98.07%)
- Lubuntu: 3,749,926,016(本物の層合計 3,757,625,344 の 99.80%)
- Server: 1,515,556,864(本物の層合計 1,518,555,136 の 99.80%)

いずれも本物の合計の +5% 以内である。

## 起動の確認

QEMU(x86_64 TCG、UEFI)で 3 OS それぞれ起動する。証拠は
`build/evidence/` に置く。

(結果は実施後に書く。)
