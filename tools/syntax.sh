#!/bin/bash
# Syntax-only check for the app's sources. Theos cannot link in this WSL
# environment (the SDK module maps are broken — a clean HEAD fails to compile
# app/main.m), so this is the gate.
#   usage: tools/syntax.sh app/sources/Foo.mm ...
#
# The warning set matters. Theos builds with -Werror and without
# -Wno-everything, so a plain -Wno-everything here would pass files that CI then
# rejects. The flags below are exactly Makefile.app's own suppressions, with
# nothing added: a suppression here that CI does not have makes this gate
# weaker than the build it stands in for, which is how DNSProfile.h once
# reached CI with five -Wnullability-completeness errors and failed there
# while this script called it ok. Every new suppression here has to be one
# Makefile.app also carries.
#
# Deliberately not -Wextra: the real build does not use it, and it flags
# untouched code such as ModMenuViewController.mm, so it would only send you
# chasing warnings CI never reports.
#
# This checks declarations, not symbols. A missing extern "C" still compiles
# here and only fails at the link step, so read a green run as "this file is
# well-formed", never as "this builds".
#
# The language follows the file extension, because that is what Theos does and
# because getting it wrong makes this gate worse than useless -- it reports green
# for code the build rejects. It used to hardcode -x objective-c++ for every
# file, so a .m file was never checked as the C it is actually compiled as, and a
# change that put extern "C", noexcept and a C++ header into esp/DSMemory.m
# passed here and then failed the real build with eleven errors. Anything written
# in C++ inside a .m file is a build break, and this gate has to be able to see
# that now.
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
  # Mirror the extension rather than the content: Theos compiles .m as
  # Objective-C and .mm as Objective-C++, and the gap is not cosmetic.
  case "$f" in
    *.mm)             LANG="-x objective-c++"; STD="-std=c++17" ;;
    *.cpp|*.cc|*.cxx) LANG="-x c++";           STD="-std=c++17" ;;
    *.c)              LANG="-x c";             STD="-std=gnu11" ;;
    *)                LANG="-x objective-c";   STD="-std=gnu11" ;;
  esac
  out=$(clang -fsyntax-only $LANG $STD -fobjc-arc \
      --target=arm64-apple-ios15.0 -isysroot "$SDK" \
      -I. -Iapp -Iapp/sources -Iesp -Iesp/esp -Iesp/esp/espdraw -Iesp/hud \
      -Iapp/oxorany -I"$PWD_ABS" -I"$PWD_ABS/remote" \
      -DNOTIFY_DESTROY_HUD='"vn.vng.freefireth.hud.destroy"' \
      -DPID_PATH='"/var/mobile/Library/Caches/vn.vng.freefireth.pid"' \
      -Wall \
      -Wno-deprecated-declarations -Wno-unused-function -Wno-unused-variable \
      -Wno-unused-parameter -Wno-unused-value -Wno-module-import-in-extern-c \
      -Wno-unknown-warning-option -Wno-unguarded-availability-new \
      -Wno-return-type -Wno-macro-redefined -Wno-sign-compare \
      -Wno-incompatible-pointer-types-discards-qualifiers \
      -Wno-incompatible-pointer-types -Wno-format \
      -Wno-unused-but-set-variable -Wno-delete-incomplete \
      -Werror \
      "$f" 2>&1)
  if [ -n "$out" ]; then
    echo "=== $f  [$LANG]"
    echo "$out"
    fail=1
  else
    echo "ok  $f"
  fi
done
exit $fail