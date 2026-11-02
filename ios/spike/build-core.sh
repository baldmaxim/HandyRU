#!/usr/bin/env bash
# Сборка Rust-ядра под iPhone (aarch64-apple-ios, Metal) и генерация проекта Xcode.
# Запускать на Mac из любой папки:  bash ios/spike/build-core.sh
set -euo pipefail

SPIKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$SPIKE_DIR/core"
LIB_DIR="$SPIKE_DIR/lib"
TARGET="aarch64-apple-ios"

fail() {
  echo "" >&2
  echo "ОШИБКА: $*" >&2
  exit 1
}

step() {
  echo ""
  echo "==> $*"
}

# rustup ставит cargo в ~/.cargo/bin, которого может не быть в PATH не-login оболочки.
export PATH="$HOME/.cargo/bin:$PATH"

step "Проверка окружения"

[[ "$(uname -s)" == "Darwin" ]] || fail "скрипт работает только на macOS (сейчас: $(uname -s))."

need() {
  # $1 — команда, $2 — подсказка по установке
  command -v "$1" >/dev/null 2>&1 || fail "не найдена команда '$1'. Установите: $2"
}

need rustup "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh  (затем откройте новый терминал)"
need cargo "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh  (затем откройте новый терминал)"
need cmake "brew install cmake"
need xcodegen "brew install xcodegen"
need xcrun "xcode-select --install  (а лучше поставьте Xcode из App Store и запустите его один раз)"

xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1 \
  || fail "не найден iOS SDK. Нужен полный Xcode (не только Command Line Tools): поставьте его из App Store, затем: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"

step "Цель Rust: $TARGET"
rustup target add "$TARGET"

# Минимальная iOS для самого ядра и для C++-части (cc/cmake).
export IPHONEOS_DEPLOYMENT_TARGET="17.0"
# Аргументы передаются в cmake сборки transcribe-cpp-sys (см. его build.rs, TRANSCRIBE_CMAKE_ARGS):
#   CMAKE_OSX_DEPLOYMENT_TARGET   -- минимальная iOS для C++-части
#   GGML_NATIVE=OFF               -- без настройки под CPU машины сборки
#   GGML_OPENMP=OFF               -- на iOS OpenMP нет
# Шейдеры встраиваются исходниками (GGML_METAL_EMBED_LIBRARY в build.rs) и компилируются
# на телефоне при загрузке модели, поэтому компилятор Metal для сборки не нужен.
export TRANSCRIBE_CMAKE_ARGS="-DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 -DGGML_NATIVE=OFF -DGGML_OPENMP=OFF"

step "Сборка ядра (первый раз долго: компилируется ggml)"
LOG_FILE="$(mktemp -t spike-core-build)"
(
  cd "$CORE_DIR"
  # cargo rustc вместо cargo build только ради строки native-static-libs:
  # она нужна, если линковка в Xcode потребует системные библиотеки.
  cargo rustc --lib --release --target "$TARGET" --features metal \
    -- --print native-static-libs 2>&1 | tee "$LOG_FILE"
) || fail "сборка ядра не удалась. Пришлите последние ~80 строк вывода выше (и версию: xcodebuild -version)."

LIB_SRC="$CORE_DIR/target/$TARGET/release/libhandy_spike_core.a"
[[ -f "$LIB_SRC" ]] || fail "после сборки не найден $LIB_SRC"

step "Копирование библиотеки"
mkdir -p "$LIB_DIR"
cp "$LIB_SRC" "$LIB_DIR/libhandy_spike_core.a"
ls -lh "$LIB_DIR/libhandy_spike_core.a"

NATIVE_LIBS="$(grep 'native-static-libs' "$LOG_FILE" | tail -1 || true)"
if [[ -n "$NATIVE_LIBS" ]]; then
  echo "Системные библиотеки Rust (нужны только если Xcode ругается на неопределённые символы):"
  echo "  $NATIVE_LIBS"
fi
rm -f "$LOG_FILE"

step "Генерация проекта Xcode"
(cd "$SPIKE_DIR" && xcodegen generate) || fail "xcodegen generate не удался. Пришлите его вывод."

echo ""
echo "Готово. Откройте проект:  open \"$SPIKE_DIR/HandySpike.xcodeproj\""
