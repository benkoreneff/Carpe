SHELL := /bin/bash

# xcodebuild needs the full Xcode. If xcode-select points at the Command Line
# Tools, use /Applications/Xcode.app for these commands without changing the
# system setting.
ifeq ($(shell xcode-select -p 2>/dev/null),/Library/Developer/CommandLineTools)
export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
endif

CONFIG  ?= Debug
DERIVED := build
APP     := $(DERIVED)/Build/Products/$(CONFIG)/ShotCal.app
BIN     := $(APP)/Contents/MacOS/ShotCal
XCB     := xcodebuild -project ShotCal.xcodeproj -scheme ShotCal -configuration $(CONFIG) \
           -derivedDataPath $(DERIVED) -destination 'platform=macOS,arch=$(shell uname -m)'

.PHONY: gen build test run stop verify-signing extract install clean

gen:
	xcodegen generate --quiet

build: gen
	$(XCB) -quiet build
	@$(MAKE) --no-print-directory verify-signing

# Prints failures and the summary line; exits with xcodebuild's status.
test: gen
	@set -o pipefail; $(XCB) test 2>&1 \
		| grep -E "error:|✘|recorded an issue|Test run with|\*\* TEST" || true; \
		exit $${PIPESTATUS[0]}

# Fails if the app ended up ad-hoc signed, which would reset Screen Recording.
verify-signing:
	@codesign -dvv "$(APP)" 2>&1 | grep -q "^Authority=Apple Development" \
		|| { echo "error: $(APP) is not signed with an Apple Development identity"; exit 1; }
	@codesign -dvv "$(APP)" 2>&1 | grep -E "^(Identifier|Authority=Apple Development|TeamIdentifier)"

stop:
	@pkill -x ShotCal || true

run: build stop
	open "$(APP)"

# Stage 2 check without the hotkey: make extract IMG=path/to/screenshot.png
extract: build
	"$(BIN)" --extract "$(IMG)"

# Puts an optimised build in /Applications and starts it. Use this copy for
# launch at login: the one in build/ disappears with `make clean`.
INSTALLED := /Applications/ShotCal.app
install:
	@$(MAKE) --no-print-directory build CONFIG=Release
	@pkill -x ShotCal || true
	rm -rf "$(INSTALLED)"
	ditto "$(DERIVED)/Build/Products/Release/ShotCal.app" "$(INSTALLED)"
	open "$(INSTALLED)"

clean:
	rm -rf $(DERIVED) ShotCal.xcodeproj
