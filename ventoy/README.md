# Ventoy の USB 用の一式

公式の `ubuntu-26.04.1-desktop-amd64.iso` だけを使い、Live 起動では文字画面・LXQt・GNOME、自動インストールでは Ubuntu + Server 機能・Lubuntu + Server 機能・Server のみを選ぶための設定。Server と Lubuntu の ISO は置かない。**実機では未検証**であり、既存 USB へ自動で書き込む仕組みは含めない。

Ventoy は **1.1.18 以上**を使う。依頼元で確認済みの情報では、1.1.11 に Ubuntu のインストールが失敗する既知の問題があり、1.1.12 で修正されている。この一式では 1.1.18 を前提にする。

## USB への置き方

USB の最初のパーティションに、最終コピーで次の配置にする。先に手元の通常ディスク上で生成・検査し、USB 上で persistence ファイルを作らない。既存の `ventoy.json` は保存しておく。

```text
/ISO/live/ubuntu-26.04.1-desktop-amd64.iso
/ISO/persistence/ubuntu-26.04.1-amd64.dat
/ventoy/ventoy.json
/ventoy/ubuntu/grub.cfg
/ventoy/ubuntu/ubuntu-pack-setup.sh
/ventoy/ubuntu/bootkit-session.sh
/ventoy/ubuntu/bootkit-session.service
/ventoy/ubuntu/bootkit-motd.sh
/ventoy/script/ubuntu-plus-server.yaml
/ventoy/script/lubuntu-plus-server.yaml
/ventoy/script/server-only.yaml
```

persistence は Live の変更を保存する ext4 ファイルで、ラベルは `casper-rw`、既定サイズは 4096 MiB (4 GiB)。新規の通常ファイルだけを作り、既存ファイル・シンボリックリンク・デバイスは拒否する。Linux では `truncate` と `mkfs.ext4`、Apple Silicon Mac では Homebrew の `e2fsprogs` に含まれる `/opt/homebrew/opt/e2fsprogs/sbin/mke2fs` が必要。道具がなければ案内して終了コード 77 を返す。

```sh
sh ventoy/make-persistence.sh ./ubuntu-26.04.1-amd64.dat
```

第 2 引数でサイズを MiB 単位で変更できる。`/Volumes/` 配下への作成は、シンボリックリンク経由も拒否する。`--allow-external` を先頭に付けた場合だけ許すが、通常の運用は手元で作成して最終コピーとする。

既存の設定を読み、別ファイルへ統合する例:

```sh
python3 -I ventoy/merge-ventoy-json.py /Volumes/VENTOY/ventoy/ventoy.json ./ventoy.generated.json --dry-run
python3 -I ventoy/merge-ventoy-json.py /Volumes/VENTOY/ventoy/ventoy.json ./ventoy.generated.json
```

生成した JSON とファイル群を最終コピーする。`control` など既存の設定と、別 ISO の項目は保つ。同じ Ubuntu ISO の `persistence`・`conf_replace`・`auto_install`・`menu_alias` の項目は置き換え、重複を除く。再実行しても結果は同じ。同一ファイル・同一実体への直接書き込みは `--in-place` がなければ拒否する。`--dry-run` は標準出力に表示するだけ。

## Live 起動

Ventoy で ISO を選ぶと、自動インストールのテンプレート選択と persistence 選択を経て、ISO 内の GRUB 起動メニューに進む。persistence の選択画面は ISO 内のメニューより前に出る。Ventoy 側で選択が省略される場合もあるため、保存領域を使う設定で起動したことを確認する。テンプレートの既定は「なし」(`autosel: 0`、待ち時間 15 秒)で、通常の Live 起動を選ぶ。

| ISO 内の項目 | 動作 |
| --- | --- |
| Server only (text mode) | 既定。30 秒で選択。`multi-user.target` で文字画面を起動 |
| Lubuntu (LXQt, needs the pack) | 追加パック導入後、LXQt セッションを選択 |
| Ubuntu (GNOME) | 元の Try or Install Ubuntu と同じカーネル引数。追加後も GNOME を選択 |
| Ubuntu (safe graphics) | `nomodeset` を使う |
| Ubuntu (copy to RAM) | `toram` を使う。ISO と作業領域に足りる RAM が必要 |
| Boot from next volume / UEFI Firmware Settings | UEFI だけで表示 |

`conf_replace` は通常の起動モードで `/boot/grub/grub.cfg` を差し替える。別の起動モードや `loopback.cfg` は対象外。`persistent` オプションは Ventoy に任せ、GRUB には手動で加えない。

## Live の追加パックの初回導入

persistence を有効にした Ubuntu Live から、USB の `ventoy/ubuntu/` を開き、**Live ユーザーの端末**で実行する。初回は文字画面でも Ubuntu の GUI でもよい。

```sh
cd /path/to/USB/ventoy/ubuntu
sudo sh ubuntu-pack-setup.sh
```

書き込み可能な `casper-rw`、ネットワーク経路、DNS を確認してから APT 索引を更新し、`lubuntu-desktop ubuntu-server openssh-server` を導入する。容量の概算は LXQt 約 1.9GB + Server 約 240MB。APT キャッシュ・更新差分・ユーザーデータは別途必要で、4 GiB の保存領域には余裕が小さい。実際の空き容量とダウンロード量は APT の表示でも確認する。

導入中のサービス自動起動を `policy-rc.d` で抑え、既存の policy は終了時に戻す。SSH サービスとソケットは停止・無効化する。完了印は全工程の成功後だけに残し、2 回目は何もしない。途中失敗時はエラーで止まり、再実行で導入を続ける。既存の SSH を意図的に有効化した場合も、完了印のある再実行は変更しない。

自動起動の表示マネージャーは GDM にそろえ、`bootkit-session.service` を表示マネージャーより前に実行する。`bootkit.session=lubuntu` の場合は LXQt、それ以外は Ubuntu のセッションを選ぶ。セッションのファイル名は `/usr/share/xsessions/`・`/usr/share/wayland-sessions/` に実在する `.desktop` から検出し、見つからなければエラーにする。GDM 用の AccountsService のセッション設定を切り替え、手動起動用の SDDM は LXQt の自動ログインに設定する。Live ユーザーの自動ログインを前提とする設定であり、インストール済み OS にこのセットアップを実行しない。

文字画面でログインすると、導入後は次の案内を表示する。初回の導入前には、この案内を出すファイル自体がまだない。

```text
GUI を使うには: sudo systemctl start gdm3 (Ubuntu) または sudo systemctl start sddm (Lubuntu)。
次回から GUI で起動するには、起動メニューで Lubuntu か Ubuntu を選ぶ。
```

手動で GUI を起動する前にも、セッションは現在の `bootkit.session` に応じて設定される。既に GUI が動作中の場合、別の表示マネージャーを同時に起動しない。導入直後の切り替えは再起動で行う。

## 自動インストール

Ventoy のメニューはファイルパスを表示するので、目的の名前の YAML を選ぶ。すべて `ubuntu-desktop-minimal` を元にし、**storage と identity は人が選ぶ**。消去対象・ユーザー・パスワードを固定しない。storage 画面で Ventoy USB をインストール先に選ばない。`$$VT_LINUX_DISK_NONVTOY_CLOSEST_...$$` はコメントの接頭辞説明だけで、変数を既定では使わない。

共通設定は英語ロケール・日本語キーボード・東京時間。追加パッケージの取得にはネットワークが必要で、オフラインインストールを保証しない。`ssh.install-server` は false、追加した OpenSSH も後処理でサービスとソケットを無効化する。

| テンプレート | 追加・後処理 |
| --- | --- |
| ubuntu-plus-server.yaml | `ubuntu-server` と `openssh-server` を追加し、GNOME を残す |
| lubuntu-plus-server.yaml | さらに `lubuntu-desktop` を追加。SDDM を設定。DM の設定失敗は警告して続行する |
| server-only.yaml | `ubuntu-server openssh-server linux-generic` を追加。指定した GUI パッケージを 1 個ずつ存在確認して purge。デスクトップ snap を削除し、autoremove。文字画面と networkd を既定にする |

Server のみでは既存 netplan の `renderer: NetworkManager` を `networkd` へ変更し、`00-installer-config.yaml` にも指定する。NetworkManager を無効にし、networkd と systemd-resolved を有効にする。Wi-Fi など既存設定の networkd への適合性、公式 Server のパッケージ・snap・ネットワーク構成との一致は未確認。GUI を外した Desktop を公式 Server ISO と同等だとは扱わない。

## 検査

ネットワークや実デバイスを使わない検査:

```sh
sh tests/test-ventoy-bundle.sh
sh tests/test-ventoy-bundle.sh --mutation-check
python3 -I -m py_compile ventoy/merge-ventoy-json.py
python3 ~/.agents/hooks/md-lint.py ventoy/README.md README.md
```

シェルの構文、ShellCheck (導入済みの場合)、GRUB の項目、YAML の宣言・対話指定、JSON の保持・重複除去・冪等性、外付けへの生成拒否、危険なコマンドを検査する。PyYAML があれば YAML 全体も解析し、なければ宣言と対話指定を静的に検査する。壊した版は別コピーで検査し、元ファイルには触れない。実機の動作の証明ではない。

パッケージ索引検査は別実行。ネットワークを明示的に許す場合:

```sh
sh tests/test-ventoy-bundle.sh --check-packages --download
```

`resolute/main` と `resolute/universe` の公式 `binary-amd64/Packages.xz` を読み、追加パッケージと purge 対象名の実在を確認する。ネットワークがない・取得できない場合は終了コード 77。`--download` を省くと通信せず 77 を返す。ローカルの `main.xz` と `universe.xz` を使う場合は `--indexes /path/to/indexes` を指定する。パッケージ名の実在検査であり、依存解決や公式 Server manifest との同等性の検査ではない。

## 未検証の項目

- Ventoy 1.1.18 での Ubuntu 26.04.1 の BIOS / UEFI 起動、persistence の保存・復元、`conf_replace` の実効。原文 GRUB・loopback の参照ファイルはこの作業ツリーにはなく、元ファイルの見た目・機能の完全一致も未確認。
- Desktop ISO に対する Ventoy 自動インストールと、3 テンプレートの適用・storage/identity 画面の表示。Desktop ISO への適用は Ventoy 公式資料に未記載との依頼元情報。
- `bootkit.session` の実効、systemd の順序、SDDM / GDM のセッション選択・Live 自動ログイン。Ubuntu 26.04 の Contents 索引・パッケージ内一覧は未入手で、設定パス・キーの版固有の有効性は未確認。スクリプトにも明記している。
- GUI の apt 追加が 4 GiB の persistence に収まること、追加後の GNOME / LXQt の動作、`toram` と persistence の併用・USB の取り外し。
- Ubuntu 26.04 の追加・削除対象パッケージ名の公式索引による実在確認、SDDM の設定、Server 用後処理の実行、netplan と networkd の通信。
- Server のみと公式 Ubuntu Server の manifest・snap・カーネル・サービス・設定の差。purge 対象の公式 Server manifest 不在も未確認で、完全な Server 化は保証しない。
