#!/usr/bin/env bash
set -e

# Choose Flutter channel/version (adjust if you need a specific release)
FLUTTER_CHANNEL=stable
FLUTTER_DIR="$HOME/flutter"

if [ ! -d "$FLUTTER_DIR" ]; then
  git clone --depth 1 -b "$FLUTTER_CHANNEL" https://github.com/flutter/flutter.git "$FLUTTER_DIR"
fi

export PATH="$FLUTTER_DIR/bin:$PATH"

flutter --version
flutter config --enable-web
flutter pub get
flutter build web --release