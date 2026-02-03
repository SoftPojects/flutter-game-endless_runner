#!/usr/bin/env bash
set -euo pipefail

# Fetch a lightweight Flutter SDK (stable channel)
git clone --depth 1 https://github.com/flutter/flutter.git -b stable flutter-sdk

# Add flutter to PATH for this build
export PATH="$PWD/flutter-sdk/bin:$PATH"

# Confirm flutter is available
flutter --version

# Enable web support and download web artifacts
flutter config --enable-web
flutter precache --web

# Build web release
flutter build web --release
