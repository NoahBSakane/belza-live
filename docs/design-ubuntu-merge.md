# Ubuntu・Lubuntu・Server 統合 ISO 案の調査メモ

調査日: 2026-10-29。委譲元の指示どおり実装はしない。読み取り専用調査の結果と設計判断だけを書く。数値はすべて実測か公開一次資料の抜粋で、推定には「推定値」、確かめられていないことには「未確認」と付ける。

**結論: 案 B(統合)は成立するが、素の casper 引数だけでは選んだ層だけを RAM に載せられない。** 統合 ISO 内を OS ごとのサブディレクトリに分け `live-media-path=` で層の選択はできるが、`toram` の複製範囲は ISO のルート全体のまま変わらない(コードで確認)。そのため選択コピーには initramfs への起動スクリプト注入(または独自 initrd)が必要で、QEMU での検証が必須。RAM 量は Ubuntu 約 4.6GiB・Lubuntu 約 3.6GiB・Server 約 1.5GiB の層複製が基礎となり、持ち主の上限(6.0・3.7・2.7GiB)には作業メモリ込みで Lubuntu が厳しい。推奨は案 B の併置型(B1)。詳細は §8。

## 1. 調査範囲・版・方法

- 対象 ISO(いずれも公式。SHA-256 は公式 SHA256SUMS と `shasum -a 256` で照合し一致を確認): Ubuntu desktop 26.04.1(`ubuntu-26.04.1-desktop-amd64.iso`、6,482,409,472 バイト)、Server 26.04.1(`ubuntu-26.04.1-live-server-amd64.iso`、2,927,861,760 バイト)、Lubuntu 26.04.1(`lubuntu-26.04.1-desktop-amd64.iso`、3,927,552,000 バイト)。【U1】【U2】【U3】
- casper は 3 つの ISO の initrd 内の `/scripts/casper`・`/scripts/casper-helpers` を取り出して SHA-256 を照合し、公開の 26.04.2 と完全一致を確認した。したがって公開ソースの行番号つきの挙動はそのまま 3 ISO に当てはまる。【C1】【C2】
- 層ファイルの比較は squashfs ファイルの SHA-256(サイズが異なるもの同士は同一ファイルたり得ないことを併用)、manifest の差分比較、5 層のファイル一覧(`unsquashfs -ll`)の突合せ、共有 3 ファイルの抜き打ちハッシュ照合で行った。作業用展開は `/private/tmp/ubuntu-merge-research/` のみに行い、USB には触れていない。一時展開は調査後に削除する。【U1】【U2】【U3】
- ネットワークは使わず、公開資料は司令塔取得の `sources/` のみを読んだ。`sources/` に無い資料(例: Ventoy の Secure Boot 文書)は「未確認」と書く。

## 2. 層の一覧と「RAM に載せる量」の内訳

`toram` 指定時の標準 casper は `copy_live_to(livefs_root, ram)` で `livefs_root`(ISO のルート)全体を複製する。`cp -a ${copyfrom}/*` と `.disk` が対象で、複製後に層をマウントする。`pool/` を除外する処理は無い。【C1: `copy_live_to` 162–205 行、`mountroot` 929–977 行】

### 2.1 Ubuntu desktop 26.04.1

| ファイル | サイズ(バイト) | 備考 |
| --- | --- | --- |
| `casper/minimal.squashfs` | 3,432,136,704 | 土台。非圧縮 6,506,545,152(`install-sources.yaml` と `.size`) |
| `casper/minimal.standard.squashfs` | 590,053,376 | desktop 追加分。非圧縮 3,443,830,784(`.size`) |
| `casper/minimal.standard.live.squashfs` | 793,112,576 | ライブ固有+インストーラ(bootstrap snap 665 等) |
| `casper/initrd` | 95,487,354 | 内包 casper は 26.04.2 と同一 |
| `casper/vmlinuz` | 17,295,752 | 3 ISO で同一ハッシュ(§3) |
| 言語・secureboot 層(約 40 個) | 合計 約0.25GB | `minimal.<lang>` 各約 17MB 等 |
| `pool/`(253 ファイル) | 1,288,512,058 | インストーラ用 deb |
| `casper/` 全体 | 5,173,421,743 | |
| ISO 全体 | 6,482,409,472 | `toram` 複製量 ≒ 6.04GiB |

`grub.cfg`(543 バイト)は `linux /casper/vmlinuz --- quiet splash` のみで `layerfs-path=`・`toram` の指定は無い。`LIVE_MEDIA_PATH` の既定値は `casper` で、引数も既定のため起動時は `casper/` 内の全 squashfs が重なる(§4 参照)。`.disk/info` は `Ubuntu 26.04.1 LTS "Resolute Raccoon" - Release amd64 (20260826)`。【U1】

層の連鎖は名前規則と manifest(互いに重なりゼロの差分形式、§3)から `minimal` ← `minimal.standard` ← `minimal.standard.live` と読める。`minimal.standard.live` の役割は一覧で確認した `ubuntu-desktop-bootstrap` snap と `casper.service` から裏付けたが、793MB の内訳詳細は未確認。言語層は `minimal.<言語>` 形式で土台の翻訳追加分と見られるが、起動時に全言語層が重なる場合の表示への影響は未確認。【U1】

### 2.2 Ubuntu Server 26.04.1(live-server)

| ファイル | サイズ(バイト) | 備考 |
| --- | --- | --- |
| `casper/ubuntu-server-minimal.squashfs` | 1,335,115,776 | 土台(`type: fsimage`)。非圧縮 2,447,507,456 |
| `casper/ubuntu-server-minimal.ubuntu-server.squashfs` | 156,299,264 | server seed(`type: fsimage-layered`)。非圧縮(積層計)3,055,915,008 |
| `casper/ubuntu-server-minimal.ubuntu-server.installer.squashfs` | 27,041,792 | subiquity snap 環境+自動ログイン設定 |
| `casper/ubuntu-server-minimal.ubuntu-server.installer.generic.squashfs` | 98,304 | 設定のみ(manifest 本体は 0 バイト) |
| `casper/initrd` | 99,677,109 | 内包 casper は 26.04.2 と同一 |
| `casper/vmlinuz` | 17,295,752 | 3 ISO で同一ハッシュ |
| `pool/`(324 ファイル) | 1,271,661,842 | インストール先に配備する deb 群 |
| `casper/` 全体 | 1,636,634,351 | |
| ISO 全体 | 2,927,861,760 | `toram` 複製量 ≒ 2.73GiB |

`grub.cfg`(394 バイト)は `linux /casper/vmlinuz ---` のみで追加引数無し。`.disk/info` は `Ubuntu-Server 26.04.1 LTS "Resolute Raccoon" - Release amd64 (20260826)`。`install-sources.yaml` に installer 層の記載は無く、層の連鎖は名前規則(`ubuntu-server-minimal` ← `.ubuntu-server` ← `.installer` ← `.installer.generic`)と manifest の差分形式から読む。installer 層の一覧には `snap-subiquity-7403.mount` 系 unit・getty 自動ログイン・`subiquity-shell` があり、起動後は subiquity の TUI インストーラ環境になると判断した。ライブセッションのシェル到達手順の実機確認は未確認。【U2】

### 2.3 Lubuntu 26.04.1

| ファイル | サイズ(バイト) | 備考 |
| --- | --- | --- |
| `casper/minimal.squashfs` | 2,037,972,992 | 土台。非圧縮 4,839,821,312(`.size`) |
| `casper/minimal.standard.squashfs` | 1,691,181,056 | LXQt 等。非圧縮 2,793,799,680(`.size`) |
| `casper/minimal.standard.live.squashfs` | 28,471,296 | calamares 関連(live 固有) |
| `casper/initrd` | 98,539,412 | 内包 casper は 26.04.2 と同一 |
| `casper/vmlinuz` | 17,295,752 | 3 ISO で同一ハッシュ |
| `pool/`(113 ファイル) | 34,170,750 | 小さい(言語パック中心と見られるが内訳未確認) |
| `casper/` 全体 | 3,873,715,582 | |
| ISO 全体 | 3,927,552,000 | `toram` 複製量 ≒ 3.66GiB |

`grub.cfg`(711 バイト)は desktop と同形に加え OEM 項目がある。`minimal.standard` が desktop の同名層(0.59GB)より大幅に大きい(1.69GB)のは LXQt 側にアプリ本体が入る構成差と見られるが、層内の内訳精査は未確認。`.disk/info` は `Lubuntu 26.04.1 LTS "Resolute Raccoon" - Release amd64 (20260826)` で 3 ISO のスナップショット日付は同一。【U3】

## 3. 層の共有の可否

### 3.1 ファイル単位の比較

9 個の主要 squashfs の SHA-256 はすべて異なり、同一バイナリの層は一つも無い。サイズが異なるもの同士は同一ファイルたり得ないので、サイズ比較だけでも同一性は否定できる。全層のサイズと代表ハッシュは次のとおり(ハッシュは先頭 16 桁)。【U1】【U2】【U3】

| 層 | サイズ(バイト) | SHA-256(先頭) |
| --- | --- | --- |
| desktop `minimal` | 3,432,136,704 | `b5ec27b9…` |
| desktop `minimal.standard` | 590,053,376 | `8aec5b15…` |
| desktop `minimal.standard.live` | 793,112,576 | `247e5d1e…` |
| server `ubuntu-server-minimal` | 1,335,115,776 | `1c7a0f50…` |
| server `.ubuntu-server` | 156,299,264 | `a4b7d569…` |
| server `.installer` | 27,041,792 | `e4979d60…` |
| server `.installer.generic` | 98,304 | `88eb0e16…` |
| lubuntu `minimal` | 2,037,972,992 | `f360bc1e…` |
| lubuntu `minimal.standard` | 1,691,181,056 | `0bcb4b40…` |
| lubuntu `minimal.standard.live` | 28,471,296 | `30c5efea…` |

3 ISO の `vmlinuz` は同一ハッシュ(`0ad39b13…`)で、カーネル(7.0.0-30-generic)は共通。initrd はサイズが少しずつ違う(95〜100MB)が、内包の casper 2 ファイルは 3 ISO とも公開 26.04.2 と完全一致した。initrd の差分の内訳(ファームウェア等)は未確認。【U1】【U2】【U3】【C1】【C2】

### 3.2 パッケージ単位の比較

各層の `.manifest` は下位層に対する差分形式(行頭 `+`、ヘッダ 2 行つき)で、層ごとの追加パッケージ集合そのものを表す。ヘッダと `+` を除いて集計した結果が次のとおり。共通パッケージはすべて同一バージョンで、版違いはゼロだった。3 ISO のスナップショット日付が同一(20260826)であることと整合する。【U1】【U2】【U3】

| 比較 | 共通 | うち同一版 | 版違い |
| --- | --- | --- | --- |
| desktop 土台と Lubuntu 土台 | 1123 | 1123 | 0 |
| desktop 土台と Server 土台 | 465 | 465 | 0 |
| Lubuntu 土台と Server 土台 | 458 | 458 | 0 |
| desktop 追加分と Lubuntu 追加分 | 74 | 74 | 0 |
| desktop live と Lubuntu live | 17 | 17 | 0 |

層固有パッケージ数は desktop 土台 411、Lubuntu 土台 521、Server 土台 31。各層の総数は desktop 土台 1550・追加 229・live 54、Lubuntu 土台 1653・追加 322・live 42、Server 土台 505・seed 207・installer 16。なお Server の installer 層には `casper 26.04.2` と `snap:subiquity 26.04/stable 7403` が含まれ、initrd 照合とは別経路でも casper の版が裏付けられた。【U1】【U2】【U3】

### 3.3 ファイル内容の共有と再構成時の推定値

土台 3 層の通常ファイル一覧を突き合わせた(同パス・同サイズを共有とみなす。抜き打ち 3 ファイル `libc.so.6`・`dash`・`ls` は 3 層で SHA-256 が完全一致し、同版パッケージの裏付けと合わせて内容一致の根拠とする)。【U1】【U2】【U3】

| 集合 | ファイル数 | 一覧バイト数(非圧縮相当) |
| --- | --- | --- |
| 3 層共通 | 63,921 | 3,222,057,581 |
| desktop・Lubuntu のみ共通 | 27,086 | 1,091,581,704 |
| desktop・Server のみ共通 | 503 | 421,626,917 |
| Lubuntu・Server のみ共通 | 220 | 10,612,459 |
| desktop 固有 | 37,795 | 4,296,876,944 |
| Lubuntu 固有 | 88,518 | 1,267,190,636 |
| Server 固有 | 677 | 21,691,264 |

注意: 一覧バイト数はハードリンクの多重計上を含む(例: desktop 固有内の snap は seed と snaps の 2 経路で約 1.43GB 重複)。3 層共通集合には snap を含まず、層全体の追加リンクは約 141 件(エントリ数−inode 数)で影響は小さい。各層の一覧合計に対する圧縮率は desktop 土台 0.379、Lubuntu 土台 0.362、Server 土台 0.361、desktop 追加 0.310、Lubuntu 追加 0.392 だった。【U1】【U2】【U3】

「共通の土台層 + OS ごとの差分層」に再構成した場合の圧縮後の推定値は次のとおり(一覧バイトに上記圧縮率を掛けた推定値。再圧縮の差は未確認)。3 層共通土台は約 1.2GB、desktop・Lubuntu 共通分は約 0.4GB、desktop 固有は重複補正後で約 1.1GB、Lubuntu 固有は約 0.46GB、Server 固有分(3 集合の合計)は約 0.16GB。追加層は desktop 約 0.59GB・Lubuntu 約 1.69GB の大半が固有と見られるが、内訳の精査は未確認。live・installer 層は OS 固有として計上する。推定の幅は ±30% 程度とみておく。【U1】【U2】【U3】

## 4. 選んだ層だけを RAM に載せる方式

### 4.1 前提: 素の casper 引数では複製範囲を狭められない

`mountroot()` は `find_livefs()` が返した `livefs_root`(パーティションのルート)を `copy_live_to()` に渡し、複製後に `mount_images_in_directory(livefs_root)` で層を重ねる。`live-media-path=` は後者の層探索ディレクトリ(`$livefs_root/$LIVE_MEDIA_PATH`)にだけ効き、複製元のルートは変えない。したがって OS ごとのサブディレクトリ(`casper-ubuntu/` 等)に分けても、`toram` の複製量は ISO 全体のままである。`layerfs-path=` は leaf 層の指定(相対時は `live-media-path` 起点、同階層は同一ディレクトリ必須)で、複製範囲には無関係。manpage も `toram` を「読み取り専用媒体全体を RAM に複製」と定義する。【C1: `mountroot`・`copy_live_to`・`setup_overlay`・`find_livefs`】【M】

素朴な `live-media-path=` 併置の効果と限界は次のとおり。起動メニューごとに `live-media-path=casper-ubuntu` 等を付ければ、その OS の層だけが正しく重なる(未設定だと全 squashfs が重なり 3 OS 分が混ざるため必須)。しかし RAM 複製は ISO 全体(併置型で約 13GB、§7)が対象となり、選んだ OS の量にはならない。方式(a)はこの意味で不成立。【C1】【M】

### 4.2 方式の比較

| 方式 | RAM に載る量の式 | USB を抜ける時点 | 必要な作業 | リスク |
| --- | --- | --- | --- | --- |
| (a) サブディレクトリ+`live-media-path` | ISO 全体 ≒ 13GB(併置型)。選択不可 | 複製完了後(量が大きすぎて現実的でない) | ISO 再構成、grub 3 項目 | 複製量が大きく起動が遅い。RAM 不足で失敗する |
| (b1) injection で casper-premount スクリプト追加 | 選択層+initrd 等(§2 の OS 別量)+W+H | 選択層の複製完了かつ USB 参照が消えた後 | 注入アーカイブ作成、premout スクリプト実装 | premount 段階で Ventoy 媒体が見えるか未確認。失敗時の fallback 設計が要る |
| (b2) injection で `/scripts/casper` 置換 | 同上 | 同上 | 26.04.2 への選択コピーパッチ実装 | Ventoy の hook 編集との適用順が未確認。上書きで LIVEMEDIA 固定が消える恐れ |
| (b3) 独自 initrd を grub で追加指定 | 同上 | 同上 | initrd 作成、grub 書換、署名対応 | Secure Boot で署名が要る(未確認)。保守負担 |
| (c) 再層化+独自 ISO(§3.3 の共有土台化) | 同上(ISO 自体は約 9〜11GB に縮む) | 同上 | 層の再生成、manifest 再作成、起動検証 | 層の作り直しで内容差が出る恐れ。公式 ISO と別物になる |

(b1)の premount スクリプトは `run_scripts /scripts/casper-premount` で `find_livefs` より先に走るため、ここで Ventoy 媒体から選択層だけを tmpfs に写し、その tmpfs を `livefs_root` として使わせる接続が考えられる。ただし premount 時点で `/dev/mapper/ventoy` が利用可能か、注入スクリプトの実行順は対象 ISO で未確認。`todisk=` は RAM でなく指定装置へ複製する既存引数で、選択コピーにはならないが検証時の逃がし先の候補になる。【C1: `mountroot` 925–979 行】【V2】

(c)は §3.3 の共有土台を活かす追加策で、選択コピー(b)と組み合わせる形になる。単独では RAM 量を減らせない。方式(c)単体という意味では「なし」に近い。【C1】

`memdisk` は「ISO 全体をメモリに載せるが 1GB 未満が条件・起動後に ISO をマウントしない用途向け」と定義され、統合 ISO(10GB 超)には使えない。`conf_replace` は iso9660 のみ・通常起動のみ・最大 2 ファイルという制約がある。【V4】【V5】

## 5. Server の特殊性

live-server の起動は「ライブセッションとして動く」もので、インストール済みシステムの起動ではない。層の役割分担は次のとおり。土台層(一般的な最小システム、507 パッケージ)に server seed 層(209 パッケージ: `ubuntu-server` 等のメタパッケージ、クラウド・管理ツール。GUI は含まない)が重なり、さらに installer 層(16 パッケージ: `casper`・`initramfs-tools`・`openssh-server`・ネットワーク導入支援と `snap:subiquity`)が重なる。installer 層の一覧には subiquity の mount unit・getty 自動ログイン・`subiquity-shell` があり、起動後は subiquity TUI による導入作業環境になると判断した。【U2】

RAM に載せて動かす対象は、この「subiquity が動くライブセッション」全体である。層の選択コピーは土台+seed+installer(+generic)の 4 層で約 1.52GiB となり、持ち主の上限 2.7GiB には作業メモリ込みでも余裕がある。`pool/`(1.27GB)はライブ動作には不要で、インストール先への配備用に ISO 内に残すかは設計選択になる(残せば USB が大きくなる)。【U2】

今の「Ubuntu Server-modoki」(desktop 土台にサーバーパックを追加した文字画面)との差は次のとおり。本物の Server 層は GUI・desktop 系を一切含まず、土台が小さい(非圧縮 2.45GB 対 desktop 土台 6.51GB)。逆に modoki にはある desktop 由来の復旧手段(GUI、desktop 用ドライバ等)は本物には無い。運用手順の互換確認は未確認。【U1】【U2】

## 6. Ventoy 1.1.18 での起動制約

- 独自の統合 ISO は iso9660(Rock Ridge)で作る。`conf_replace` は iso9660 の ISO のみ対応で UDF は不可と明記されている。公式 3 ISO は iso9660 として読めた(xorriso でツリー取得)ので、同形式での再構成が条件になる。【V5】【U1】【U2】【U3】
- `conf_replace` は通常起動モードのみで、grub2 モード・memdisk モードでは効かない。1 ISO あたり最大 2 ファイル。起動項目の追加は置換後の grub.cfg 内で完結させる設計にする。【V5】
- `injection` は「ファイルを initramfs の `/` に展開する枠組み」で、内容の実行や casper との接続は自作の仕事になる。Linux の対応形式は `.zip`・`.tar.gz`・`.tar.bz2`・`.tar.xz`(`.tar.lzma` を含む表記もある)。大容量アーカイブの実用上限の記載は無い。【V2】
- `persistence` は backend の `.dat` を指定する方式で、Ubuntu のラベルは `casper-rw`。統合 ISO で永続化を残すなら OS ごとに backend を分ける必要があるが、今回の RAM 常駐方針との組合せ設計は未確認。【V3】
- Ventoy 1.1.18 の `default-hook.sh` は、initrd の `/init` に `disk_mount_hook` を挿入し、`LIVEMEDIA=/dev/mapper/ventoy` を export して casper の `LIVEMEDIA=` 代入を同値に書き換える。`live-media=` がカーネル引数にある場合のみ後者が動く。統合 ISO でもこの挙動は変わらないと見られるが、実機での分岐実行は未確認。`find_cow_device` の wrapper 注入は永続化使用時のみ関係する。【V1】
- Secure Boot については `sources/` に対象文書が無く未確認。独自 ISO・独自 initrd・置換 grub.cfg での起動可否は QEMU と実機で確かめる必要がある。
- なおサイズ上限の明記は `sources/` の memdisk 文書(1GB 未満条件)以外に見当たらず、13GB 級 ISO の Ventoy 起動可否自体も検証事項になる。検証は QEMU で行い、実 USB での確認は別途持ち主の操作になる。

## 7. 作業量の見積もり

### 7.1 統合 ISO の大きさ

併置型(B1: 既存層を OS 別サブディレクトリに並べるだけ)はファイル合計でほぼ確定する。OS 別ライブ層(ubuntu 約 4.82GB・lubuntu 約 3.76GB・server 約 1.52GB)、desktop 言語層 約 0.25GB、initrd+vmlinuz 3 組 約 0.33GB、manifest 等 約 1MB、boot 約 8MB、pool 3 OS 分 約 2.60GB(pool 重複の有無は未確認)、ISO 管理領域 約 8MBで、合計は約 13.3GB になる。USB は Ventoy 本体と余裕を見て 16GB 以上が要る(現行 USB の容量は未確認のため持ち主確認)。【U1】【U2】【U3】

再層化型(B2: §3.3 の共有土台化)は約 9〜11GB の推定値(再圧縮の差は未確認で ±2GB 程度の幅)。削減効果の大半は土台 3 層の共通化による。【U1】【U2】【U3】

### 7.2 工程表

| 工程 | 内容 | 規模の目安 | 所要の目安 |
| --- | --- | --- | --- |
| E1 ISO 再構成(B1) | 3 ISO から層・pool・boot を OS 別配置に複製し xorriso 等で iso9660 化、grub 3 項目+`live-media-path` | 新規スクリプト 1 本(約 100〜200 行)、grub 約 30 行 | 実行 30〜60 分(複製・ISO 化中心) |
| E2 選択コピー起動処理 | (b1) premount スクリプト +(b2 予備)パッチ、injection アーカイブ化 | 新規 sh 約 100〜200 行、アーカイブ定義 1 式 | 実装半日、単体確認含む |
| E3 QEMU 検証 | OS 別起動・層の重なり確認・RAM 量記録・USB 切り離し相当試験 | 検証手順書 1 式、VM 定義 3 式 | 1 項目 10〜20 分 × 約 10 項目。初回は半日〜1 日 |
| E4 再層化(B2、任意) | 共通土台・差分層の再生成、manifest 再作成 | mksquashfs 手順+検証(層ごとに GB 級処理) | 層生成 各 10〜30 分+回帰検証。B1 の後に実施 |
| E5 永続化・SB 対応 | backend 分離、署名・起動可否確認 | 未定(検証結果による) | 未定 |

所要はすべて推定値で、QEMU の実測が無い現段階の目安である。難所は E2 の premount 時点の媒体可視性と Ventoy hook との干渉、E3 の Lubuntu の RAM 上限(§8)の実測、E4 の層再生成の同一性保証である。【C1】【V1】【V2】

## 8. 案 A と案 B の比較・推奨・確認事項

### 8.1 選択コピー時の RAM 量(層複製分の確定値)

| OS | 選択層+initrd+vmlinuz(バイト) | GiB |
| --- | --- | --- |
| Ubuntu | 4,928,085,762 | 約 4.59 |
| Lubuntu | 3,873,460,508 | 約 3.61 |
| Server | 1,635,527,997 | 約 1.52 |

ここに作業メモリ W と一時重複 H が加わる。持ち主の上限(6.0・3.7・2.7GiB)に対し、Ubuntu と Server は余裕があるが、Lubuntu は層だけで 3.61GiB のため W+H 込みで 3.7GiB を超える可能性が高く、実測での合否判定が必須の難所になる。【U1】【U2】【U3】

### 8.2 比較表

| 観点 | 案 A(modoki のまま RAM 量を再現) | 案 B(統合して選択層だけ RAM 化) |
| --- | --- | --- |
| 楽さ | 楽だが目的不達成。4.0GB 土台は不変 | B1 併置+E2 が最短。B2 再層化は追加作業 |
| 実現性 | 不成立(算術)。土台が本物より大きい | 条件付き成立。選択コピーは要自作・要検証 |
| RAM 量 | 4.6GiB+ が基礎で上限超過 | OS 別 4.59・3.61・1.52GiB+W+H(Lubuntu 要実測) |
| USB の大きさ | 現状維持(約 6.5GB+永続化) | 約 13.3GB(B1)か約 9〜11GB(B2)。16GB 以上が要る |
| リスク | 方針違反(本物より大きい) | 自作起動処理・SB・Ventoy 干渉の検証負債 |

### 8.3 推奨と持ち主への確認事項

推奨は案 B の併置型(B1)+(b1)選択コピーで、QEMU 検証で成立を見てから B2 再層化を検討する段取りである。理由は、B1 が公式層を無改変で保てるため内容の正しさが層ハッシュで保証でき、再層化の同一性リスクを踏まずに RAM 量の実測へ進めるからである。【U1】【U2】【U3】

持ち主に確認したい点は次の 3 点である。

1. Lubuntu の 3.7GiB 上限は作業メモリ込みの厳守か。実測で超えた場合の方針(上限緩和か Lubuntu の RAM 常駐の見送り)を決めたい。
2. 統合 ISO に `pool/`(計約 2.6GB、server 1.27GB を含む)を残し、インストール機能を維持するか。削れば USB を約 2.6GB 縮められる。
3. 16GB 以上の USB 調達と、独自 ISO・独自 initramfs 処理での Secure Boot 方針(署名の扱い)を決めたい。

## 9. 出典と版

公開資料の確認日はすべて 2026-10-29。版の指定が無い Ventoy 公式文書はその日の掲載内容で、Ventoy 1.1.18 の実行結果を保証しない。

- 【U1】 Ubuntu desktop 26.04.1 公式 ISO(`ubuntu-26.04.1-desktop-amd64.iso`、6,482,409,472 バイト、SHA-256 `601e30fb…` 全文照合済み)。`casper/`・`pool/`・`boot/grub/grub.cfg`・`.disk/`・`install-sources.yaml` の一覧とサイズを `bsdtar -tvf`・`bsdtar -xOf` で取得。initrd 内 casper の SHA-256 照合は §1 の方法による。
- 【U2】 Ubuntu Server 26.04.1 公式 ISO(`ubuntu-26.04.1-live-server-amd64.iso`、2,927,861,760 バイト、SHA-256 `cc8a95cd…` 全文照合済み)。取得方法は【U1】と同じ。
- 【U3】 Lubuntu 26.04.1 公式 ISO(`lubuntu-26.04.1-desktop-amd64.iso`、3,927,552,000 バイト、SHA-256 `a8038585…` 全文照合済み)。取得方法は【U1】と同じ。
- 【C1】 casper 26.04.2 `scripts/casper`(取得 SHA-256 `6cfed518…`)。<https://git.launchpad.net/casper/plain/scripts/casper?h=26.04.2>。ローカル名 `sources/casper-26.04.2-scripts-casper.sh`。`copy_live_to`・`setup_overlay`・`mountroot`・`find_livefs`・`is_casper_path`・`mount_images_in_directory` を読んだ。
- 【C2】 casper 26.04.2 `scripts/casper-helpers`(取得 SHA-256 `e29ece94…`)。<https://git.launchpad.net/casper/plain/scripts/casper-helpers?h=26.04.2>。ローカル名 `sources/casper-26.04.2-scripts-casper-helpers.sh`。`find_cow_device` を読んだ。
- 【M】 casper(7) manpage(resolute)。<https://manpages.ubuntu.com/manpages/resolute/man7/casper.7.html>。ローカル名 `sources/casper-man7-resolute.html`。`toram`・`todisk`・`live-media-path`・`layerfs-path`・`persistent-path` の定義を抽出。
- 【V1】 Ventoy 1.1.18 `default-hook.sh` と `casper-perst-wa.sh`。<https://raw.githubusercontent.com/ventoy/Ventoy/v1.1.18/IMG/cpio/ventoy/hook/debian/default-hook.sh>。ローカル名 `sources/ventoy-1.1.18-default-hook.sh`・`sources/ventoy-1.1.18-casper-perst-wa.sh`。
- 【V2】 Ventoy 公式 Injection Plugin。<https://www.ventoy.net/en/plugin_injection.html>。ローカル名 `sources/ventoy-doc-plugin_injection.html`。
- 【V3】 Ventoy 公式 Persistence Plugin。<https://www.ventoy.net/en/plugin_persistence.html>。ローカル名 `sources/ventoy-doc-plugin_persistence.html`。
- 【V4】 Ventoy 公式 Memdisk Mode。<https://www.ventoy.net/en/doc_memdisk.html>。ローカル名 `sources/ventoy-doc-doc_memdisk.html`。
- 【V5】 Ventoy 公式 Boot Conf Replace Plugin。<https://www.ventoy.net/en/plugin_bootconf_replace.html>。ローカル名 `sources/ventoy-doc-plugin_bootconf_replace.html`。
- 【R1】 `docs/design-ubuntu-pack-ram.md`(ram-design 作業ツリー。読むだけ)。標準 casper の `toram` が ISO ルート全体を複製することの先行確認を参照した。

## 10. 未確認事項の一覧

- 言語層・secureboot 層を含めた起動時の重なり順と表示への影響(§2.1)。起動試験で確認する。
- d-live 793MB の内訳詳細(§2.1)。選択コピー量の確定に影響する。
- Lubuntu 層 pool 34MB の内訳(§2.3)。統合 ISO の pool 設計に影響する。
- server pool と desktop pool の重複有無(§7.1)。USB 容量の確定に影響する。
- premount 時点の Ventoy 媒体の可視性と注入スクリプトの実行順(§4.2)。E2 の成否条件。
- injection による `/scripts/casper` 置換と Ventoy hook 編集の適用順(§4.2)。(b2)の成否条件。
- 独自 ISO・独自 initramfs での Secure Boot 起動可否(§6)。実機確認が要る。
- 13GB 級 ISO の Ventoy 起動可否(§6)。QEMU で確認する。
- QEMU 所要時間の実測(§7.2)。初回検証で記録する。
- modoki と本物 Server の運用手順の互換(§5)。移行時に確認する。
- 再層化時の再圧縮差と内容同一性の保証(§3.3)。B2 実施時に確認する。
