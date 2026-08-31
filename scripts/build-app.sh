#!/usr/bin/env bash
# Собирает Every Noise.app без Xcode: только swiftc из Command Line Tools.
#
#   ./scripts/build-app.sh                 сборка под текущую архитектуру
#   ./scripts/build-app.sh --universal     universal binary (arm64 + x86_64)
#   ./scripts/build-app.sh --version 1.2.0 --universal --zip
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"

APP_NAME="Every Noise"
BINARY_NAME="EveryNoise"
BUNDLE_ID="com.sakharovmaksim.every-noise"
DEPLOYMENT_TARGET="15.0"

VERSION=""
UNIVERSAL=0
MAKE_ZIP=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="$2"; shift 2 ;;
    --universal) UNIVERSAL=1; shift ;;
    --zip) MAKE_ZIP=1; shift ;;
    -h|--help) sed -n '2,7p' "$0"; exit 0 ;;
    *) echo "Неизвестный аргумент: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$VERSION" ]]; then
  VERSION="$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)"
  VERSION="${VERSION:-0.1.0}"
fi
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

SDK="$(xcrun --show-sdk-path)"
SOURCES=()
while IFS= read -r file; do SOURCES+=("$file"); done < <(find Sources -name '*.swift' | sort)

if [[ $UNIVERSAL -eq 1 ]]; then
  ARCHS=(arm64 x86_64)
else
  ARCHS=("$(uname -m)")
fi

BUILD_DIR="$ROOT/.build/release"
DIST_DIR="$ROOT/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"

rm -rf "$APP_DIR"
mkdir -p "$BUILD_DIR" "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

SLICES=()
for arch in "${ARCHS[@]}"; do
  echo "==> Компиляция $arch (macOS $DEPLOYMENT_TARGET)"
  slice="$BUILD_DIR/$BINARY_NAME-$arch"
  xcrun swiftc \
    -parse-as-library \
    -swift-version 6 \
    -default-isolation MainActor \
    -O -whole-module-optimization \
    -target "${arch}-apple-macos${DEPLOYMENT_TARGET}" \
    -sdk "$SDK" \
    "${SOURCES[@]}" \
    -o "$slice"
  SLICES+=("$slice")
done

echo "==> Сборка бандла"
if [[ ${#SLICES[@]} -gt 1 ]]; then
  xcrun lipo -create -output "$APP_DIR/Contents/MacOS/$BINARY_NAME" "${SLICES[@]}"
else
  cp "${SLICES[0]}" "$APP_DIR/Contents/MacOS/$BINARY_NAME"
fi
chmod +x "$APP_DIR/Contents/MacOS/$BINARY_NAME"

if [[ ! -f Resources/AppIcon.icns ]]; then
  echo "==> Генерация иконки"
  xcrun swift scripts/make-icon.swift Resources/AppIcon.icns
fi
cp Resources/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"

sed -e "s/__VERSION__/$VERSION/" \
    -e "s/__BUILD__/$BUILD_NUMBER/" \
    -e "s/__BUNDLE_ID__/$BUNDLE_ID/" \
    Resources/Info.plist > "$APP_DIR/Contents/Info.plist"
printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"

echo "==> Подпись (ad-hoc)"
codesign --force --sign - --identifier "$BUNDLE_ID" --timestamp=none "$APP_DIR"
codesign --verify --strict "$APP_DIR"

echo "==> Готово: $APP_DIR (версия $VERSION, сборка $BUILD_NUMBER)"

if [[ $MAKE_ZIP -eq 1 ]]; then
  ZIP="$DIST_DIR/$BINARY_NAME-$VERSION.zip"
  rm -f "$ZIP"
  ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP"
  echo "==> Архив: $ZIP"
fi
