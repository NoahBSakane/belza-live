# Ventoy 一式の検証記録

確認日: 2026-10-25。ネットワーク・実デバイス・ISO 起動は使っていない。作業範囲の指定に合わせ、検証記録は `ventoy/` 内に置く。

## 問いと判定方法

設定の重大な条件が壊れたとき、正常版と区別して失敗を返せるかを確かめる。検査が成功する結果と、目的の assertion で失敗する結果を対照にする。単なる起動失敗や前提不足では、条件を検出したとは判定しない。

| 条件 | 判定材料 | 実測 |
| --- | --- | --- |
| 正常版 | 一式の検査が終了コード 0 | `ALL PASS: Ventoy bundle` |
| GRUB の既定を 0 から 2 へ変更 | Server 以外の既定を検出 | `Server が既定でない` で失敗 |
| server-only の対話指定を削除 | storage の対話指定の欠落を検出 | `storage 対話指定がない` で失敗 |
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
- `sh tests/test-ventoy-bundle.sh --mutation-check`: 成功。上の 3 種の変更をすべて検出。
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
