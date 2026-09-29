export THEOS ?= /home/tduck/theos

ARCHS := arm64 arm64e
TARGET := iphone:clang:18.6:15.0
DEBUG = 0
FINALPACKAGE = 1

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME := MINHDUC
$(APPLICATION_NAME)_USE_MODULES := 0

# --- app UI sources ---
$(APPLICATION_NAME)_FILES += $(wildcard app/main.m)
$(APPLICATION_NAME)_FILES += $(wildcard app/sources/*.mm app/sources/*.m app/sources/*.c)
$(APPLICATION_NAME)_FILES += $(wildcard app/sources/roothide/*.mm app/sources/roothide/*.m)
$(APPLICATION_NAME)_FILES += $(wildcard app/sources/KIF/*.mm app/sources/KIF/*.m)
$(APPLICATION_NAME)_FILES += $(wildcard app/sources/HomeViewController/*.mm app/sources/HomeViewController/*.m app/sources/HomeViewController/*.cpp)

$(APPLICATION_NAME)_FILES += $(wildcard app/oxorany/*.cpp)

# --- KeepAlive ---
$(APPLICATION_NAME)_FILES += app/KeepAlive.m

# --- ESP stack (vẽ overlay + menu in-app) ---
$(APPLICATION_NAME)_FILES += $(wildcard esp/esp/*.mm esp/esp/*.cpp)
$(APPLICATION_NAME)_FILES += $(wildcard esp/esp/espdraw/*)
$(APPLICATION_NAME)_FILES += esp/DSMemory.m

# --- HUD overlay process (SpringBoard-hosted) ---
$(APPLICATION_NAME)_FILES += $(wildcard esp/hud/*.mm esp/hud/*.m)
$(APPLICATION_NAME)_FILES += app/KernelBoot.m app/BootLogPopup.m

# --- kernel exploit ---
$(APPLICATION_NAME)_FILES += kexploit/kexploit_opa334.m kexploit/krw.m kexploit/kutils.m kexploit/offsets.m kexploit/vnode.m
$(APPLICATION_NAME)_FILES += remote/RemoteCall.m remote/Thread.m remote/VM.m remote/PAC.m remote/MigFilterBypassThread.m remote/Exception.m remote/remote_objc.m remote/SpringBoardOverlay.m
$(APPLICATION_NAME)_FILES += sandbox_escape.m platformize.m
$(APPLICATION_NAME)_FILES += utils/file.c utils/hexdump.c utils/process.c
$(APPLICATION_NAME)_FILES += kpf/patchfinder.m
$(APPLICATION_NAME)_FILES += XPF/src/xpf.c XPF/src/common.c XPF/src/decompress.c XPF/src/bad_recovery.c XPF/src/non_ppl.c XPF/src/ppl.c
$(APPLICATION_NAME)_FILES += XPF/external/ChOma/src/arm64.c XPF/external/ChOma/src/Base64.c XPF/external/ChOma/src/BufferedStream.c XPF/external/ChOma/src/CodeDirectory.c XPF/external/ChOma/src/CSBlob.c XPF/external/ChOma/src/DER.c XPF/external/ChOma/src/DyldSharedCache.c XPF/external/ChOma/src/Entitlements.c XPF/external/ChOma/src/Fat.c XPF/external/ChOma/src/FileStream.c XPF/external/ChOma/src/Host.c XPF/external/ChOma/src/MachO.c XPF/external/ChOma/src/MachOLoadCommand.c XPF/external/ChOma/src/MemoryStream.c XPF/external/ChOma/src/PatchFinder.c XPF/external/ChOma/src/PatchFinder_arm64.c XPF/external/ChOma/src/Util.c

# --- Flags ---
$(APPLICATION_NAME)_CFLAGS += -fobjc-arc -Wno-deprecated-declarations -Wno-unused-function -Wno-unused-variable -Wno-unused-value -Wno-module-import-in-extern-c -Wno-unknown-warning-option -Wno-unguarded-availability-new -Wno-return-type -Wno-macro-redefined -Wno-incompatible-pointer-types-discards-qualifiers -Wno-incompatible-pointer-types -Wno-format -Wno-unused-but-set-variable -Wno-delete-incomplete
$(APPLICATION_NAME)_CFLAGS += -I. -Iapp -Iapp/sources -Iesp/hud -Iapp/sources/KIF -Iapp/oxorany
$(APPLICATION_NAME)_CFLAGS += -Iesp -Iesp/esp -Iesp/esp/espdraw
$(APPLICATION_NAME)_CFLAGS += -I$(PWD) -I$(PWD)/remote -I$(PWD)/XPF/src -I$(PWD)/XPF/external/ChOma/include
UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Linux)
$(APPLICATION_NAME)_CFLAGS += -I$(PWD)/utils/xpc -I$(PWD)/utils/fileport
else
# macOS: use real SDK headers if present; otherwise our minimal stubs
$(APPLICATION_NAME)_CFLAGS += -I$(PWD)/utils/xpc -I$(PWD)/utils/fileport
endif
$(APPLICATION_NAME)_CFLAGS += -DNOTIFY_DESTROY_HUD="\"vn.vng.freefireth.hud.destroy\""
$(APPLICATION_NAME)_CFLAGS += -DPID_PATH="@\"/var/mobile/Library/Caches/vn.vng.freefireth.pid\""
$(APPLICATION_NAME)_CCFLAGS += -std=c++17
$(APPLICATION_NAME)_OBJCFLAGS += -fobjc-arc

$(APPLICATION_NAME)_FRAMEWORKS += CoreGraphics CoreServices QuartzCore IOKit UIKit CoreText AVFoundation AVKit CoreMedia CFNetwork Security SystemConfiguration MobileCoreServices UniformTypeIdentifiers SafariServices
$(APPLICATION_NAME)_PRIVATE_FRAMEWORKS += BackBoardServices GraphicsServices SpringBoardServices IOSurface
$(APPLICATION_NAME)_LIBRARIES += z compression


$(APPLICATION_NAME)_CODESIGN_FLAGS += -Sapp/layout/entitlements.plist
$(APPLICATION_NAME)_RESOURCE_DIRS = ./app/layout/Resources ./app/Font

include $(THEOS_MAKE_PATH)/application.mk
include $(THEOS_MAKE_PATH)/aggregate.mk

before-package::
	@chmod 755 $(THEOS_STAGING_DIR)/DEBIAN

after-package::
	@rm -rf Payload
	@mkdir -p Payload
	@cp -r .theos/_/Applications/$(APPLICATION_NAME).app Payload/
	@chmod 755 Payload/$(APPLICATION_NAME).app/$(APPLICATION_NAME)
	@rm -f $(APPLICATION_NAME).ipa
	@zip -rq $(APPLICATION_NAME).ipa Payload
	@unzip -tq $(APPLICATION_NAME).ipa >/dev/null
	@rm -rf Payload
	@mkdir -p packages
	@rm -f packages/$(APPLICATION_NAME).tipa packages/*.deb
	@mv -f $(APPLICATION_NAME).ipa packages/
	@echo "[*] Success: packages/$(APPLICATION_NAME).ipa"
