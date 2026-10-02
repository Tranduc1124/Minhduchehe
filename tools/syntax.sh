#!/bin/bash
# Syntax-only check for the app's UI sources. Theos cannot link in this WSL
# environment (the SDK module maps are broken), so this is the gate.
#   usage: tools/syntax.sh app/sources/Foo.mm ...
set -u
cd "$(dirname "$0")/.." || exit 1
SDK=/home/tduck/theos/sdks/iPhoneOS17.5.sdk
PWD_ABS=$(pwd)
fail=0
for f in "$@"; do
  out=$(clang -fsyntax-only -x objective-c++ -fobjc-arc \
      --target=arm64-apple-ios15.0 -isysroot "$SDK" \
      -I. -Iapp -Iapp/sources -Iesp -Iesp/esp -Iesp/esp/espdraw -Iesp/hud \
      -Iapp/oxorany -I"$PWD_ABS" -I"$PWD_ABS/remote" \
      -DNOTIFY_DESTROY_HUD='"vn.vng.freefireth.hud.destroy"' \
      -DPID_PATH='"/var/mobile/Library/Caches/vn.vng.freefireth.pid"' \
      -Wno-everything "$f" 2>&1)
  if [ -n "$out" ]; then
    echo "=== $f"
    echo "$out"
    fail=1
  else
    echo "ok  $f"
  fi
done
exit $fail