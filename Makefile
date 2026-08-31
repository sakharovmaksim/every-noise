# Every Noise — локальная сборка и CI.
# Всю работу по упаковке бандла делает scripts/build-app.sh; здесь — удобные входные точки.

APP_NAME  := Every Noise
BUNDLE    := dist/$(APP_NAME).app
SDK       := $(shell xcrun --show-sdk-path)
TARGET    := arm64-apple-macos15.0
SOURCES   := $(shell find Sources -name '*.swift')
SWIFTC    := xcrun swiftc -parse-as-library -swift-version 6 -default-isolation MainActor

# Версия берётся из git-тега, если не задана явно: make release VERSION=1.0.0
VERSION      ?=
VERSION_FLAG := $(if $(VERSION),--version $(VERSION),)

.DEFAULT_GOAL := help
.PHONY: help check app universal release run install icon log clean

help: ## показать доступные цели
	@grep -E '^[a-z-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  make %-10s %s\n", $$1, $$2}'

check: ## проверить типы без сборки бандла (быстрый гейт для CI)
	$(SWIFTC) -typecheck -target $(TARGET) -sdk $(SDK) $(SOURCES)

app: ## собрать .app под текущую архитектуру
	./scripts/build-app.sh $(VERSION_FLAG)

universal: ## собрать universal binary (arm64 + x86_64)
	./scripts/build-app.sh --universal $(VERSION_FLAG)

release: ## universal + zip для релиза: make release VERSION=1.0.0
	./scripts/build-app.sh --universal --zip $(VERSION_FLAG)

run: app ## собрать и запустить, заменив работающую копию
	@pkill -f "$(BUNDLE)" || true
	@sleep 1
	open "$(BUNDLE)"

install: universal ## установить в /Applications и запустить
	@pkill -f "$(APP_NAME).app" || true
	@sleep 1
	rm -rf "/Applications/$(APP_NAME).app"
	cp -R "$(BUNDLE)" /Applications/
	open -a "$(APP_NAME)"

icon: ## перегенерировать Resources/AppIcon.icns
	xcrun swift scripts/make-icon.swift Resources/AppIcon.icns

log: ## следить за журналом работающего приложения
	tail -f "$$HOME/Library/Logs/EveryNoise/every-noise.log"

clean: ## удалить артефакты сборки
	rm -rf .build dist
