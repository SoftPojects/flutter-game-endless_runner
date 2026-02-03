#!/usr/bin/env bash
set -e

FLUTTER_DIR="flutter-sdk"
FLUTTER_REPO="https://github.com/flutter/flutter.git"
FLUTTER_BRANCH="stable"

if [ -d "$FLUTTER_DIR" ]; then
  echo "flutter-sdk directory already exists — skipping clone. Attempting to update..."
  # If it's a git checkout, fetch latest; otherwise skip
  if [ -d "$FLUTTER_DIR/.git" ]; then
    git -C "$FLUTTER_DIR" fetch --depth=1 origin "$FLUTTER_BRANCH" || true
    git -C "$FLUTTER_DIR" reset --hard "origin/$FLUTTER_BRANCH" || true
  else
    echo "$FLUTTER_DIR exists and is not a git repo — leaving as-is"
  fi
else
  git clone --depth 1 "$FLUTTER_REPO" -b "$FLUTTER_BRANCH" "$FLUTTER_DIR"
fi

# continue with the rest of your build (example)
# ./flutter-sdk/bin/flutter --version
# ./flutter-sdk/bin/flutter build web --release