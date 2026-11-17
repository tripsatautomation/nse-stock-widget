#!/bin/bash
# Rebuild the app after editing anything in src/
cd "$(dirname "$0")" || exit 1
APP="Stock Widget.app"
mkdir -p "$APP/Contents/MacOS"
swiftc -swift-version 5 -O src/Data.swift src/main.swift -o "$APP/Contents/MacOS/StockWidget" || exit 1
codesign --force --deep -s - "$APP" >/dev/null 2>&1
echo "Built $APP"
