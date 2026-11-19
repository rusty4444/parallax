#!/bin/bash
# Compile the production source and native tests, without invoking Flutter.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"

if [[ -z "${FLUTTER_MACOS_FRAMEWORK_DIR:-}" ]]; then
  if [[ -z "${FLUTTER_ROOT:-}" ]]; then
    flutter_bin="$(command -v flutter || true)"
    if [[ -z "$flutter_bin" ]]; then
      printf '%s\n' 'Set FLUTTER_ROOT or FLUTTER_MACOS_FRAMEWORK_DIR to a cached Flutter SDK.' >&2
      exit 1
    fi
    # Resolve the command path only: do not run Flutter or mutate its cache.
    while [[ -L "$flutter_bin" ]]; do
      link="$(readlink "$flutter_bin")"
      if [[ "$link" = /* ]]; then
        flutter_bin="$link"
      else
        flutter_bin="$(dirname "$flutter_bin")/$link"
      fi
    done
    FLUTTER_ROOT="$(cd "$(dirname "$flutter_bin")/.." && pwd)"
  fi
  FLUTTER_MACOS_FRAMEWORK_DIR="$FLUTTER_ROOT/bin/cache/artifacts/engine/darwin-x64/FlutterMacOS.xcframework/macos-arm64_x86_64"
fi
if [[ ! -d "$FLUTTER_MACOS_FRAMEWORK_DIR/FlutterMacOS.framework" ]]; then
  printf 'No cached FlutterMacOS.framework in %s\n' "$FLUTTER_MACOS_FRAMEWORK_DIR" >&2
  exit 1
fi

scratch_root="$HOME/.hermes/cache/scratch"
mkdir -p "$scratch_root"
scratch="$(mktemp -d "$scratch_root/parallax-clipboard-native.XXXXXX")"
export TMPDIR="$scratch"
printf 'Native logs and executable: %s\n' "$scratch"
xcrun swiftc -O -swift-version 5 -target "$(uname -m)-apple-macosx13.0" \
  -module-cache-path "$scratch/ModuleCache" \
  -F "$FLUTTER_MACOS_FRAMEWORK_DIR" -framework FlutterMacOS \
  -Xlinker -rpath -Xlinker "$FLUTTER_MACOS_FRAMEWORK_DIR" \
  "$repo_root/apple/ParallaxApple.swift" \
  "$repo_root/apple/tests/ClipboardImageTests.swift" \
  -o "$scratch/clipboard-tests" > "$scratch/compile.log" 2>&1 || {
    printf 'swiftc failed; compiler output:\n' >&2
    while IFS= read -r line; do printf '%s\n' "$line" >&2; done < "$scratch/compile.log"
    exit 1
  }
"$scratch/clipboard-tests" 2>&1 | tee "$scratch/test.log"
