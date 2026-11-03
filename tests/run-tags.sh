#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/Integration
xcrun swiftc -swift-version 6 -parse-as-library \
  Ignition/Models/*.swift Ignition/Services/*.swift \
  tests/TagIntegration.swift -lsqlite3 -o build/Integration/tags
build/Integration/tags
