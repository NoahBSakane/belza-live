.DEFAULT_GOAL := help
.PHONY: help test test-survey test-boot ramsel-injection ramsel-trial-iso
help:
	@printf '%s\n' 'make help         ターゲット一覧' 'make test         通信不要の全テスト(並列)' 'make test-survey  検査スクリプトの試験' 'make test-boot    起動設定の試験' 'make ramsel-injection  Ventoy injection のアーカイブを作る' 'make ramsel-trial-iso  試作の統合 ISO を組む(約 11GB、build/)'
test:
	@sh tests/run-tests.sh
test-survey:
	@TMPDIR="$(CURDIR)" sh tests/test-survey.sh
test-boot:
	@TMPDIR="$(CURDIR)" sh tests/test-boot-config.sh
ramsel-injection:
	@sh ventoy/ramsel/make-injection.sh
ramsel-trial-iso:
	@sh ventoy/ramsel/make-trial-iso.sh
