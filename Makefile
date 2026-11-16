SHELL := /bin/bash

# xcodebuild needs the full Xcode. If xcode-select points at the Command Line
# Tools, use /Applications/Xcode.app for these commands without changing the
# system setting.
ifeq ($(shell xcode-select -p 2>/dev/null),/Library/Developer/CommandLineTools)
export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
endif

CONFIG  ?= Debug
# Spotlight skips folders named *.noindex, so the copies of Carpe.app in the
# build output don't show up next to the installed one.
DERIVED := build.noindex
DIST    := dist.noindex
APP     := $(DERIVED)/Build/Products/$(CONFIG)/Carpe.app
BIN     := $(APP)/Contents/MacOS/Carpe
XCB     := xcodebuild -project Carpe.xcodeproj -scheme Carpe -configuration $(CONFIG) \
           -derivedDataPath $(DERIVED) -destination 'platform=macOS,arch=$(shell uname -m)'

.PHONY: gen build test run stop verify-signing extract install clean check-secrets release publish

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

# Fails if the app ended up ad-hoc signed or signed with another certificate
# than the released app, either of which would reset its permissions.
verify-signing:
	@codesign -dvv "$(APP)" 2>&1 | grep -q "^Authority=Developer ID Application" \
		|| { echo "error: $(APP) is not signed with the Developer ID Application certificate"; exit 1; }
	@codesign -dvv "$(APP)" 2>&1 | grep -E "^(Identifier|Authority=Developer ID Application|TeamIdentifier)"

stop:
	@pkill -x Carpe || true

run: build stop
	open "$(APP)"

# Stage 2 check without the hotkey: make extract IMG=path/to/screenshot.png
# Add CALENDARS="Work,Home" to also get a suggested calendar.
extract: build
	"$(BIN)" --extract "$(IMG)" $(if $(CALENDARS),--calendars "$(CALENDARS)")

# Puts an optimised build in /Applications and starts it. Use this copy for
# launch at login: the one in build.noindex/ disappears with `make clean`.
INSTALLED := /Applications/Carpe.app
install:
	@$(MAKE) --no-print-directory build CONFIG=Release
	@pkill -x Carpe || true
	rm -rf "$(INSTALLED)"
	ditto "$(DERIVED)/Build/Products/Release/Carpe.app" "$(INSTALLED)"
	open "$(INSTALLED)"

# Looks for API keys, client secrets and tokens in the files and the git history.
check-secrets:
	@scripts/check-secrets.sh

# A notarized Carpe-<version>.dmg in dist.noindex/, for other people's Macs,
# and a copy of it named Carpe.dmg.
release:
	@scripts/release.sh

# The GitHub release for the current version's tag, with Carpe-<version>.dmg
# and Carpe.dmg attached. Optional: make publish NOTES=notes.md
publish:
	@scripts/publish.sh $(NOTES)

clean:
	rm -rf $(DERIVED) $(DIST) Carpe.xcodeproj
