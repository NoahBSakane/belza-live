.DEFAULT_GOAL := help
.PHONY: help test test-survey test-boot
help:
	@printf '%s\n' 'make help         ターゲット一覧' 'make test         通信不要の全テスト(並列)' 'make test-survey  検査スクリプトの試験' 'make test-boot    起動設定の試験'
test:
	@sh tests/run-tests.sh
test-survey:
	@TMPDIR="$(CURDIR)" sh tests/test-survey.sh
test-boot:
	@TMPDIR="$(CURDIR)" sh tests/test-boot-config.sh
