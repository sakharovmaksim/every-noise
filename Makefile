# Every Noise — local builds and CI.
# All bundling work is done by scripts/build-app.sh; this file is the convenient entry point.

APP_NAME  := Every Noise
BUNDLE    := dist/$(APP_NAME).app
SDK       := $(shell xcrun --show-sdk-path)
TARGET    := arm64-apple-macos15.0
SOURCES   := $(shell find Sources -name '*.swift')
SWIFTC    := xcrun swiftc -parse-as-library -swift-version 6 -default-isolation MainActor

# Version comes from the latest git tag unless set explicitly: make release VERSION=1.0.0
VERSION      ?=
VERSION_FLAG := $(if $(VERSION),--version $(VERSION),)

.DEFAULT_GOAL := help
.PHONY: help check app universal release run install icon log clean

help: ## show the available targets
	@grep -E '^[a-z-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  make %-10s %s\n", $$1, $$2}'

check: ## type-check without building a bundle (fast gate for CI)
	$(SWIFTC) -typecheck -target $(TARGET) -sdk $(SDK) $(SOURCES)

app: ## build the .app for the current architecture
	./scripts/build-app.sh $(VERSION_FLAG)

universal: ## build a universal binary (arm64 + x86_64)
	./scripts/build-app.sh --universal $(VERSION_FLAG)

release: ## universal + zip for a release: make release VERSION=1.0.0
	./scripts/build-app.sh --universal --zip $(VERSION_FLAG)

run: app ## build and restart the local copy
	@pkill -f "$(BUNDLE)" || true
	@sleep 1
	open "$(BUNDLE)"

install: universal ## install into /Applications and launch
	@pkill -f "$(APP_NAME).app" || true
	@sleep 1
	rm -rf "/Applications/$(APP_NAME).app"
	cp -R "$(BUNDLE)" /Applications/
	open -a "$(APP_NAME)"

icon: ## regenerate Resources/AppIcon.icns
	xcrun swift scripts/make-icon.swift Resources/AppIcon.icns

log: ## follow the running app's log
	tail -f "$$HOME/Library/Logs/EveryNoise/every-noise.log"

clean: ## remove build artefacts
	rm -rf .build dist
