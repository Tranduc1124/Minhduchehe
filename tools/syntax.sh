#!/bin/bash
# Syntax-only check for the app's sources. Theos cannot link in this WSL
# environment (the SDK module maps are broken — a clean HEAD fails to compile
# app/main.m), so this is the gate.
#   usage: tools/syntax.sh app/sources/Foo.mm ...
#
# The warning set matters. Theos builds with -Werror and without
# -Wno-everything, so a plain -Wno-everything here would pass files that CI then
# rejects. The flags below keep the project's own suppressions (Makefile.app
# CFLAGS) and add -Wno-nullability-completeness, which is the one the new UI
# headers trip over. Deliberately not -Wextra: the real build does not use it,
# and it flags untouched code such as ModMenuViewController.mm, so it would
# only send you chasing warnings CI never reports.
#
# This checks declarations, not symbols. A missing extern "C" still compiles
# here and only fails at the link step, so read a green run as "this file is
# well-formed", never as "this builds".
#
# PID_PATH carries no @ prefix. HUDHelper.mm wraps it in ROOT_PATH_NS, which
# adds the @ itself, and Makefile.app's copy has its @ stripped by the shell
# before clang sees it. Passing it with the @ here gives @@ and every use fails.
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
      -std=c++17 \
      -Wall \
      -Wno-deprecated-declarations -Wno-unused-function -Wno-unused-variable \
      -Wno-unused-parameter -Wno-unused-value -Wno-module-import-in-extern-c \
      -Wno-unknown-warning-option -Wno-unguarded-availability-new \
      -Wno-return-type -Wno-macro-redefined -Wno-sign-compare \
      -Wno-incompatible-pointer-types-discards-qualifiers \
      -Wno-incompatible-pointer-types -Wno-format \
      -Wno-unused-but-set-variable -Wno-delete-incomplete \
      -Wno-nullability-completeness -Werror \
      "$f" 2>&1)
  if [ -n "$out" ]; then
    echo "=== $f"
    echo "$out"
    fail=1
  else
    echo "ok  $f"
  fi
done
exit $fail