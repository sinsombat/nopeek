# NoPeek — top-level build entry points (spec §9).
#
#   make test     run the PWCore unit test suite (swift-testing)
#   make build    debug build (compile check, no bundle)
#   make app      assemble + ad-hoc sign build/NoPeek.app
#   make install  build, copy to ~/Applications/NoPeek.app, (re)load the LaunchAgent
#   make clean    remove build artefacts
#
# `make uninstall` arrives with the packaging task (T22).

SHELL := /bin/bash

XCODE_PATH := $(shell xcode-select -p)

ifeq ($(XCODE_PATH),/Library/Developer/CommandLineTools)
# CLT-only toolchain: on a clean build SwiftPM fails to find the swift-testing
# macro plugin and the suite silently fails to compile. Point the compiler at the
# dylib that ships with the Command Line Tools (R2). Full Xcode finds it itself.
TEST_FLAGS := -Xswiftc -load-plugin-library -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
else
TEST_FLAGS :=
endif

.PHONY: all test build app install clean

all: app

test:
	swift test $(TEST_FLAGS)

build:
	swift build

app:
	./scripts/build-app.sh

install:
	./scripts/install.sh

clean:
	rm -rf .build .build-release build
