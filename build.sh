#!/bin/bash
# Build MacTemp.app and (optionally) install to /Applications.
# Usage:
#   ./build.sh            # build MacTemp.app in this dir
#   ./build.sh install    # build, then copy to /Applications/MacTemp.app (replaces any old TempMeter.app)
#   ./build.sh run        # build, then launch the local copy
#   ./build.sh quit       # stop the running MacTemp
set -euo pipefail
cd "$(dirname "$0")"

BUILD="MacTemp.app"

build() {
  rm -rf "$BUILD"
  mkdir -p "$BUILD/Contents/MacOS" "$BUILD/Contents/Frameworks"
  echo ">> building dylib"
  clang -dynamiclib -o libhidtemp.dylib hid_temp.c \
        -framework IOKit -framework CoreFoundation
  install_name_tool -id @rpath/libhidtemp.dylib libhidtemp.dylib
  echo ">> building app binary"
  swiftc -O -o "$BUILD/Contents/MacOS/MacTemp" main.swift metrics.swift ui.swift \
    -import-objc-header hidtemp.h \
    -I . -L . -lhidtemp \
    -framework AppKit -framework IOKit -framework CoreFoundation \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks
  echo ">> building fanctl helper (bundled; fan writes need admin)"
  swiftc -O -o "$BUILD/Contents/MacOS/fanctl" tools/fanctl.swift -framework IOKit

  # privileged fan helper (SMJobBless): bare tool named exactly the launchd label,
  # with Info.plist (__info_plist) and launchd plist (__launchd_plist) embedded in __TEXT.
  HELPER_LABEL="local.mactemp.helper"
  mkdir -p "$BUILD/Contents/Library/LaunchServices"
  swiftc -O -o "$BUILD/Contents/Library/LaunchServices/$HELPER_LABEL" tools/fanhelper.swift \
      -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker tools/helper_Info.plist \
      -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __launchd_plist -Xlinker tools/helper_launchd.plist \
      -framework IOKit
  codesign --force -s - --identifier "$HELPER_LABEL" "$BUILD/Contents/Library/LaunchServices/$HELPER_LABEL"

  # dev/verification CLIs (inside the bundle so they share its code-signing identity)
  swiftc -O -o "$BUILD/Contents/MacOS/helper_install" tools/helper_install.swift -framework ServiceManagement -framework Security
  swiftc -O -o "$BUILD/Contents/MacOS/fanprobe" tools/fanprobe.swift
  codesign --force -s - --identifier local.mactemp "$BUILD/Contents/MacOS/helper_install"
  codesign --force -s - --identifier local.mactemp "$BUILD/Contents/MacOS/fanprobe"

  cp Info.plist "$BUILD/Contents/"
  mkdir -p "$BUILD/Contents/Resources"
  cp MacTemp.icns "$BUILD/Contents/Resources/"
  cp libhidtemp.dylib "$BUILD/Contents/Frameworks/"
  codesign --force -s - "$BUILD"
  echo ">> built $BUILD"
}

build
case "${1:-}" in
  install)
    pkill -x MacTemp 2>/dev/null || true
    rm -rf /Applications/MacTemp.app /Applications/TempMeter.app
    cp -R "$BUILD" /Applications/MacTemp.app
    codesign --force -s - /Applications/MacTemp.app
    echo ">> installed /Applications/MacTemp.app"
    ;;
  run)
    open "$BUILD"
    echo ">> launched $BUILD"
    ;;
  quit)
    pkill -x MacTemp 2>/dev/null && echo ">> quit" || echo ">> not running"
    ;;
  *)
    echo ">> done. Use: ./build.sh [install|run|quit]"
    ;;
esac
