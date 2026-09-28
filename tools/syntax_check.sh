#!/bin/bash
# Syntax check with the flags Makefile.app actually uses, minus -Wno-everything.
cd ~/Projects/FilzaJailedDS/FilzaJailedDS || exit 1
FLAGS="-fobjc-arc -Wno-deprecated-declarations -Wno-unused-function -Wno-unused-variable -Wno-unused-value -Wno-module-import-in-extern-c -Wno-unknown-warning-option -Wno-unguarded-availability-new -Wno-return-type -Wno-macro-redefined -Wno-incompatible-pointer-types-discards-qualifiers -Wno-incompatible-pointer-types -Wno-format -Wno-unused-but-set-variable -Wno-delete-incomplete"
INC="-I. -Iapp -Iapp/sources -Iesp -Iesp/hud -Iesp/esp -Iesp/esp/espdraw -Ikexploit -Iremote -Ikpf -IXPF/src -IXPF/external/ChOma/include -Iutils -Iutils/xpc -Iutils/fileport"
for f in "$@"; do
  echo "=== $f ==="
  # shellcheck disable=SC2086
  clang -fsyntax-only -x objective-c $FLAGS \
    --target=arm64-apple-ios15.0 \
    -isysroot /home/tduck/theos/sdks/iPhoneOS17.5.sdk \
    $INC "$f" 2>&1 \
    | grep -E "error:|warning:" \
    | grep -vE "iPhoneOS17.5.sdk|is deprecated" \
    | head -15
  echo "--- rc=$? ---"
done
echo "CHECK FINISHED"
