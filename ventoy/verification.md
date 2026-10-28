# Ventoy 一式の検証記録

確認日: 2026-10-25。ネットワーク・実デバイス・ISO 起動は使っていない。作業範囲の指定に合わせ、検証記録は `ventoy/` 内に置く。

## 問いと判定方法

設定の重大な条件が壊れたとき、正常版と区別して失敗を返せるかを確かめる。検査が成功する結果と、目的の assertion で失敗する結果を対照にする。単なる起動失敗や前提不足では、条件を検出したとは判定しない。

| 条件 | 判定材料 | 実測 |
| --- | --- | --- |
| 正常版 | 一式の検査が終了コード 0 | `ALL PASS: Ventoy bundle` |
| GRUB の文字画面ラベルを変更前へ戻す | 新ラベルの一致を検出 | `GRUB 項目/順序が違う` で失敗 |
| GRUB の既定を 0 から 1 へ変更 | Lubuntu 以外の既定を検出 | `Lubuntu が既定でない` で失敗 |
| GRUB の先頭を文字画面へ戻す | Lubuntu が先頭でないことを検出 | `GRUB 項目/順序が違う` で失敗 |
| ISO 別名に余分な語を戻す | 別名の完全一致を検査 | `alias が違う` で失敗 |
| server-modoki の対話指定を削除 | storage の対話指定の欠落を検出 | `storage 対話指定がない` で失敗 |
| JSON 統合を追記のみへ変更 | 2 回目の出力が異なることを検出 | `merge が非冪等` で失敗 |
| 偽の完全な Packages 索引 | 追加・削除対象名がすべて存在 | 終了コード 0 |
| openssh-server などが欠ける偽索引 | 欠落名を検出 | 終了コード 1、欠落名を表示 |
| 索引を指定しない | 未検証を成功扱いしない | 終了コード 77 |
| 偽セッションファイルを切り替える | AccountsService と SDDM の出力 | LXQt / Ubuntu を区別、他の設定は保持 |
| 必要なセッションファイルを削除 | 欠落を検出 | 終了コードが非 0 |
| 偽 formatter が成功 / 失敗 | 引数、通常ファイル、残った出力 | 正常時だけファイルが残り、失敗時は後始末 |

対照実験は一式の `--mutation-check` に組み込み、元のファイルを変更せず、独立したコピーだけを壊す。いずれも想定した assertion で落ちることまで確認した。実機における設定の有効性は、この結果から推論しない。

## 実行コマンドと結果

- `sh tests/test-ventoy-bundle.sh`: 成功。内部で全シェルスクリプトの `sh -n` と ShellCheck 0.11.0 も成功。
- `sh tests/test-ventoy-bundle.sh --mutation-check`: 成功。上の 6 種の変更をすべて検出。
- `python3 -I -m py_compile ventoy/merge-ventoy-json.py ventoy/check-package-index.py`: 成功。
- `sh tests/test-ventoy-bundle.sh --check-packages`: 想定どおり終了コード 77。ネットワーク取得は実行していない。
- `python3 ~/.agents/hooks/md-lint.py ventoy/README.md ventoy/verification.md README.md`: 指摘 0 件。
- `git diff --check`: 成功。
- `TMPDIR="$PWD/ventoy" sh tests/test-flavor-files.sh`: 成功。
- `TMPDIR="$PWD/ventoy" sh tests/test-boot-config.sh`: amd64 / arm64 × 3 フレーバーすべて成功。
- `TMPDIR="$PWD/ventoy" sh tests/test-disk-guard.sh`: 9 件成功。
- `TMPDIR="$PWD/ventoy" sh tests/test-qemu-boot-args.sh`: 32 件成功。下記の作業範囲逸脱あり。
- `TMPDIR="$PWD/ventoy" sh tests/test-release-assets.sh`: 成功。
- `TMPDIR="$PWD/ventoy" sh tests/test-survey.sh`: 成功。

PyYAML は未導入だったため、YAML 全体の解析は実施していない。代わりに cloud-config・autoinstall・version・storage/identity の宣言と、複数行 late-command のシェル構文を検査した。公式索引・manifest・Contents を使う確認は未実施。その他の未確認項目は [README](README.md#未検証の項目) に列挙した。

## 作業範囲と後始末

変更は `ventoy/`、`tests/test-ventoy-bundle.sh`、ルート README のリンク追記に限定し、`git add`・`git commit` は行っていない。テストのコピー・偽の索引・偽の root・偽の persistence ファイルはテスト終了時に削除し、構文検査で作られた `ventoy/__pycache__/` も削除した。

既存の `test-qemu-boot-args.sh` は `TMPDIR` を使わず `/private/tmp` を固定指定しており、実行前の確認で見落とした。このテストだけは作業ツリー外の `/private/tmp/qb-args-5yfhwj_f` に一時ファイルを作成した。テストの自動後始末が済み、そのパスが存在しないことを読み取りで確認した。既存テストは編集していない。

## 名称変更の検証 (2026-10-29)

問いは、新名への更新漏れを検査で区別できるか。新名の正常版と、文字画面ラベルだけを変更前へ戻した独立コピーを対照にする。正常版の終了コード 0 と、コピーの `GRUB 項目/順序が違う` による非 0 を判定材料とし、他の理由の失敗は名称の検出とは判定しない。内部のセッション ID・切替スクリプト・YAML の内容は変更しない。

- `/bin/bash tests/test-ventoy-bundle.sh --mutation-check`: 終了コード 0。正常版は `ALL PASS: Ventoy bundle`、文字画面ラベルを変更前へ戻したコピーは `GRUB 項目/順序が違う` で失敗し、`PASS: 壊した版を検出 (menu-name: GRUB 項目/順序が違う)` を出力した。既定項目・対話指定・冪等性の 3 条件も失敗を検出した。
- `/bin/bash` は 3.2.57。Ventoy の全シェルと試験の構文検査、および試験内の ShellCheck 0.11.0 は成功した。
- `python3 ~/.agents/hooks/md-lint.py ventoy/README.md ventoy/verification.md`: 日本語行の MD013 を除外する既定の markdownlint 検査で指摘 0 件。
- 3 つの YAML は変更前の Git の内容とバイト単位で一致。`bootkit-session.sh` も未変更。
- 旧名の検索は `ventoy/` と `tests/` で 0 件。リポジトリ全体では、依頼範囲外の `.agent-handoff/task-J-ventoy.md` に過去の指示が 5 行残るため、`.git` だけを除外した検索は 0 件にならない。この指示書は編集していない。

試験側の偽 root は環境変数を引用して参照するよう修正し、空白を含む作業ツリー内で完結させた。ツリー外への書き込みは行わず、今回の確認は通信・実デバイスを使わない Ventoy 関連の全試験に限定した。PyYAML がないため YAML の全体解析と実機起動は未実施。

## 起動既定・ISO 別名の検証 (2026-10-29)

問いは、先頭かつ既定が `Lubuntu-modoki (LXQt)` で、ISO 別名が `Ubuntu-modoki 26.04.1 bundle` の条件を検査が区別できるか。正常版、既定番号を文字画面の 1 に戻したコピー、番号 0 のまま文字画面を先頭に戻したコピー、ISO 別名に余分な語を戻したコピーを対照にする。元の設定は変更せず、作業ツリー内の独立コピーで実行する。正常版の終了コード 0 と、異常版の意図した assertion による非 0 を材料とし、別の理由による失敗は検出成功に含めない。

試験の一時領域とログも作業ツリー内に限定し、実デバイス・ネットワーク・実機起動は使わない。

`TMPDIR="$PWD/ventoy" PYTHONDONTWRITEBYTECODE=1 /bin/bash tests/test-ventoy-bundle.sh --mutation-check` は終了コード 0。正常版と 6 種の異常版で次の出力を得た。異常版はそれぞれ終了コードが非 0 で、意図した assertion の出力があることまで試験内で検査する。

```text
PASS: 壊した版を検出 (menu-name: GRUB 項目/順序が違う)
PASS: 壊した版を検出 (default: Lubuntu が既定でない)
PASS: 壊した版を検出 (default-order: GRUB 項目/順序が違う)
PASS: 壊した版を検出 (alias: alias が違う)
PASS: 壊した版を検出 (interactive: storage 対話指定がない)
PASS: 壊した版を検出 (idempotence: merge が非冪等)
ALL PASS: Ventoy bundle (実機の起動は未検証)
```

正常版は全検査に合格し、既定番号の変更は `Lubuntu が既定でない`、先頭順序の変更は `GRUB 項目/順序が違う`、ISO 別名の変更は `alias が違う` で失敗するため、各条件の崩れを区別できた。

- Bash 3.2.57 で上の試験と構文検査が成功。ShellCheck 0.11.0 も成功。
- Python は `compile()` で構文検査し、バイトコードを出力していない。
- Markdown は `python3 ~/.agents/hooks/md-lint.py ventoy/README.md ventoy/verification.md` で指摘 0 件。
- `git diff --check` は成功。
- 対象の 2 ディレクトリ内で廃止表記と旧名は 0 件。リポジトリ全体では、範囲外の `.agent-handoff/task-J-ventoy.md` に廃止表記が 1 行、旧名が 5 行残る。この過去の指示書は変更していない。
- `sh tests/run-tests.sh` は終了コード 0。通常の全試験と空白・ピリオドを含むパスでの再試験が成功し、最後に `ALL PASS: 空白・ピリオドを含むパスで既存の全試験が成功` を出力した。runner が設定する作業ツリー内の `TMPDIR` は、QEMU 引数試験の `TemporaryDirectory` でも使われる。実際の QEMU 起動は行っていない。
- 今回の一時ログ `ventoy/.menu-full-test.log`・`ventoy/.menu-mutation-test.log` と、全試験が作った `.agent-handoff/mutation-*.log` の 8 ファイルは結果を上に記録して削除した。試験のコピーと一時ディレクトリは各試験の終了処理で削除済み。指定された前回の一時ログ・リンク用ディレクトリは着手時から存在しなかった。git の add・commit・push は行っていない。

## 追加起動項目と ISO 別名の検証計画 (2026-10-29)

問いは、Lubuntu を既定とする 8 起動項目 + UEFI 2 項目の順序・カーネル引数と、ISO 別名 `Ubuntu-modoki 26.04.1 bundle` を検査が区別できるか。正常版と、既定番号・先頭順序・旧 ISO 別名・追加した 3 項目それぞれの欠落を独立コピーで対照にする。既存の名称・対話指定・冪等性の対照も維持する。番号と順序、起動行の完全一致、生成した JSON の別名を一次の判定材料にする。

正常版の終了コード 0 と、各異常版の意図した assertion による非 0 を区別する。他の理由の失敗は未判定とする。試験の一時領域・ログを作業ツリー内に限定し、通信・実媒体・実機起動は使わない。実測結果を以下に記す。

`TMPDIR="$PWD/ventoy" PYTHONDONTWRITEBYTECODE=1 /bin/bash tests/test-ventoy-bundle.sh --mutation-check` は終了コード 0。正常版と 9 種の異常版から、次の出力を得た。

```text
PASS: 壊した版を検出 (menu-name: GRUB 項目/順序が違う)
PASS: 壊した版を検出 (default: Lubuntu が既定でない)
PASS: 壊した版を検出 (default-order: GRUB 項目/順序が違う)
PASS: 壊した版を検出 (alias: alias が違う)
PASS: 壊した版を検出 (missing-lubuntu-safe: GRUB 項目/順序が違う)
PASS: 壊した版を検出 (missing-lubuntu-ram: GRUB 項目/順序が違う)
PASS: 壊した版を検出 (missing-server-ram: GRUB 項目/順序が違う)
PASS: 壊した版を検出 (interactive: storage 対話指定がない)
PASS: 壊した版を検出 (idempotence: merge が非冪等)
ALL PASS: Ventoy bundle (実機の起動は未検証)
```

正常版は全条件に合格し、異常版は各条件に対応する assertion で失敗した。追加 3 項目を個別に消した場合も、項目数・順序の検査で区別できた。全 8 起動項目は `linux` 行と `initrd` 行を完全一致で検査しており、セッション指定・文字画面指定・`nomodeset`・`toram` の組み合わせも対象に含む。

- `PYTHONDONTWRITEBYTECODE=1 sh tests/run-tests.sh`: 終了コード 0。通常の全試験と、空白・ピリオドを含む作業ツリーのコピーでの全試験が成功。
- Bash 3.2.57 による Ventoy の全シェルと対象試験の構文検査、および上記 mutation 試験が成功。試験内の ShellCheck 0.11.0 も成功。
- `merge-ventoy-json.py` は `compile()` による構文検査が成功し、バイトコードを出力していない。
- `python3 ~/.agents/hooks/md-lint.py ventoy/README.md ventoy/verification.md`: 指摘 0 件。`git diff --check` も成功。
- `.git` を除いた作業ツリー全体の廃止表記・旧名の検索は、それぞれ 0 件。
- 今回の一時ログ `ventoy/.options-full-test.log`・`ventoy/.options-mutation-test.log` と、全試験が生成した `.agent-handoff/mutation-*.log` の 8 ファイルは結果を記録して削除。試験の独立コピーと一時ディレクトリも試験の終了処理で削除済み。前回の `.rename-test.log` と `.test-link-tmp/` は着手時から存在しなかった。
- 今回の永続的な変更は `ventoy/ubuntu/grub.cfg`・`ventoy/merge-ventoy-json.py`・`ventoy/README.md`・`ventoy/verification.md`・`tests/test-ventoy-bundle.sh` の 5 ファイル。既存の名称変更を維持し、git の add・commit・push は行っていない。作業ツリー外への書き込みは行っていない。

依頼された設定変更と試験の検出力は妥当と判定した。PyYAML がないため YAML 全体解析は行わず、既存の静的検査を実施した。実機の Lubuntu セッション・追加した起動オプション・Ventoy 経由の動作は、このオフライン試験では未確認。

## 導入スクリプト名の検証 (2026-10-29)

問いは、modoki の名前で導入スクリプトを実行でき、試験が廃止したファイル名を呼ぶと失敗するか。正常版と、独立コピーの試験だけで呼び出すファイル名を変更した版を対照にする。正常版の終了コード 0 と、異常版の `persistence 上のルートを拒否した` による非 0 を判定材料とする。別の理由の失敗は検出成功と判定しない。

一時ファイルとログは作業ツリー内に限定し、通信・実媒体・実機起動は使わない。完了マーカーと session の値の保持を検索で、セッション切替スクリプトとサービスの保持を変更前後の SHA-256 で確認する。実測結果は以下のとおり。

- `TMPDIR="$PWD/ventoy" PYTHONDONTWRITEBYTECODE=1 /bin/bash tests/test-ventoy-bundle.sh --mutation-check`: 終了コード 0。正常版は `ALL PASS: Ventoy bundle`、試験の呼び出し名だけを戻した独立コピーは `persistence 上のルートを拒否した` で失敗し、`PASS: 壊した版を検出 (setup-name: persistence 上のルートを拒否した)` を出力した。既存の 9 条件も検出成功。
- Bash 3.2.57 による Ventoy の全シェルと対象試験の構文検査、および上記の正常版・異常版の試験は成功。ShellCheck 0.11.0 も成功。
- 導入スクリプトはファイル名・自己参照・導入済みの案内文だけ変更し、導入処理は変更していない。完了マーカーと session の値は検索で保持を確認。
- `bootkit-session.sh` と `bootkit-session.service` は変更前後の SHA-256 が一致し、Git の HEAD ともバイト単位で一致。

- `.git` だけを除いた `grep -rn` では、対象外の `.agent-handoff/out-J.log` と `.agent-handoff/task-J-ventoy.md` に廃止した導入スクリプト名が計 4 行残る。`ventoy/`・`tests/`・Makefile・ワークフローには残っていない。対象外の過去記録は変更していないため、リポジトリ全体で 0 件という条件は未達。
- `TMPDIR="$PWD/ventoy" PYTHONDONTWRITEBYTECODE=1 sh tests/run-tests.sh`: 終了コード 0。通常の全試験と、空白・ピリオドを含む作業ツリーのコピーでの全試験が成功。
- `python3 ~/.agents/hooks/md-lint.py ventoy/README.md ventoy/verification.md`: 指摘 0 件。`git diff --check` も成功。
- 一時ログ `ventoy/.modoki-full-test.log`・`ventoy/.modoki-mutation-test.log` と、全試験が生成した `.agent-handoff/mutation-*.log` の 8 ファイルは、この記録を残して削除。試験の独立コピーと一時ディレクトリも終了処理で削除済み。作業ツリー外への書き込み、git の add・commit・push は行っていない。実機 USB の導入中の処理は操作していない。
