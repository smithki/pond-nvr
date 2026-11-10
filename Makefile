# Pond: build, check and test.   make help
IMAGE := pond-tests
PKG   := src

# Swift Testing and the Swift Build backend need Xcode's toolchain. If xcode-select points at the Command
# Line Tools but Xcode is installed, use Xcode for these commands only (the system setting is not changed).
ifeq ($(shell uname -s),Darwin)
  ifeq ($(DEVELOPER_DIR),)
    ifneq ($(wildcard /Applications/Xcode.app/Contents/Developer),)
      export DEVELOPER_DIR := /Applications/Xcode.app/Contents/Developer
    endif
  endif
endif

# Signs with an Apple Development certificate when there is one (Xcode › Settings › Accounts, with any Apple
# ID): it carries a team ID, so the Keychain trusts every rebuild and asks once. Else with "Pond Local Signing"
# (make signing creates it): the Keychain then knows the program by its certificate, but its partition list
# still holds each build's own hash, so after a rebuild it asks once more per password. Else ad hoc.
APPLE_DEV := $(shell security find-identity -v -p codesigning 2>/dev/null | grep -o '"Apple Development: [^"]*"' | head -1 | tr -d '"')
SIGN := $(or $(APPLE_DEV),$(if $(shell security find-identity -p codesigning 2>/dev/null | grep '"Pond Local Signing"'),Pond Local Signing,-))
# Every build under the hardened runtime, as a notarized release must be: what it stops (and the entitlements that
# allow it again, app/Pond.entitlements) shows in everyday use, not first at release. A secure timestamp only for a
# release (it asks Apple's server; make release sets SIGN_TIMESTAMP=1). Ad hoc signing can't have the runtime.
CODESIGN := codesign --force $(if $(filter -,$(SIGN)),,--options runtime $(if $(SIGN_TIMESTAMP),--timestamp,--timestamp=none))

.PHONY: help build app demo check hooks test test-docker clean install update signing release

help:
	@echo "make build          build the pond command (release) into dist/"
	@echo "make app            build dist/Pond NVR.app (the settings app, with pond inside for the login service);"
	@echo "                    the first time, it also makes search's picture model (a few minutes; SEARCH_MODEL=0 skips)"
	@echo "make check          no footage in the repository; compile everything, tests included, with warnings as errors"
	@echo "make hooks          once per checkout: a commit hook that refuses footage, pictures and databases"
	@echo "make test           run the tests here (they write only temporary files, so a Mac is fine)"
	@echo "make test-docker    run the tests of the modules that build on Linux, in a throwaway container (needs Docker)"
	@echo "make install        build, then copy pond to /usr/local/bin (sudo)"
	@echo "make update         install, then restart the login service if it is installed"
	@echo "make demo [SCENARIO=home] [FRESH=1]  a copy of the app in dist/demo, opened in demo mode (made-up cameras; see"
	@echo "                    pond demo list); quits one already open; FRESH=1 starts the scenario over"
	@echo "make clean          remove dist/ and the Swift build folder"
	@echo "make signing        once per Mac: a local signing certificate, so Keychain access survives rebuilds"
	@echo "make release VERSION=0.1.0  a signed, notarized Pond-0.1.0.dmg in dist/release (docs/release.md)"

build:
	swift build --package-path $(PKG) -c release
	@# A new file rather than overwriting: macOS kills programs started from a file rewritten in place
	@# while another copy of it runs (the HomeKit accessory, the login service).
	@mkdir -p dist && rm -f dist/pond && cp "$$(swift build --package-path $(PKG) -c release --show-bin-path)/pond" dist/pond
	@$(CODESIGN) --sign "$(SIGN)" --identifier pond dist/pond
	@echo "✓ dist/pond$(if $(filter -,$(SIGN)), (signed ad hoc; make signing to stop repeated Keychain prompts))"

# Pond NVR.app: the app's executable plus pond itself (Contents/MacOS/pond), which the login service runs when it is
# installed from the app. Signed as make build signs.
APP := dist/Pond NVR.app
app: build
	swift build --package-path $(PKG) -c release --product PondApp
	@rm -rf "$(APP)" && mkdir -p "$(APP)/Contents/MacOS"
	@cp "$$(swift build --package-path $(PKG) -c release --show-bin-path)/PondApp" "$(APP)/Contents/MacOS/PondApp"
	@cp dist/pond "$(APP)/Contents/MacOS/pond"
	@# The signaling service, for a demo's Ponds to meet through (on this Mac, for them alone).
	swift build --package-path $(PKG) -c release --product pond-signal
	@cp "$$(swift build --package-path $(PKG) -c release --show-bin-path)/pond-signal" "$(APP)/Contents/MacOS/pond-signal"
	@cp app/Info.plist "$(APP)/Contents/Info.plist"
	@# The icon, from Icon Composer (app/AppIcon.icon): compiled into Assets.car (its Liquid Glass looks) and an
	@# AppIcon.icns, as Xcode would.
	@mkdir -p "$(APP)/Contents/Resources"
	@# The icon's own mark, for the menu bar (cropped to it and drawn as a template image by the app, so it follows
	@# the icon when that changes).
	@cp app/AppIcon.icon/Assets/mark.svg "$(APP)/Contents/Resources/Mark.svg"
	@# Pond's licence and notices, and the licences of what's built in (the models), with every copy of the app.
	@cp LICENSE NOTICE "$(APP)/Contents/Resources/" && rm -rf "$(APP)/Contents/Resources/Licenses" && \
	  cp -R licenses "$(APP)/Contents/Resources/Licenses"
	@# (Every path whole: actool's helper can resolve a relative one against a folder of its own, and fail.)
	@out="$$(cd "$(APP)/Contents/Resources" && pwd)" && \
	  xcrun actool "$(CURDIR)/app/AppIcon.icon" --compile "$$out" --platform macosx --minimum-deployment-target 27.0 \
	  --app-icon AppIcon --output-partial-info-plist "$$out/.icon-info.plist" \
	  --output-format human-readable-text >/dev/null
	@rm -f "$(APP)/Contents/Resources/.icon-info.plist"
	@# The detection model built in (models/detection/: a Core ML package and its manifest), downloaded as
	@# models/detection.lock names it (once; scripts/model-fetch.sh), and compiled now so it loads at once. Pond finds
	@# events with it, so a build without it fails.
	@scripts/model-fetch.sh models/detection.lock models/detection
	@rm -rf "$(APP)/Contents/Resources/Models" && mkdir -p "$(APP)/Contents/Resources/Models"
	@for m in models/detection/*.mlpackage; do \
	  xcrun coremlcompiler compile "$$m" "$(APP)/Contents/Resources/Models" >/dev/null && \
	  cp "$${m%.mlpackage}.json" "$(APP)/Contents/Resources/Models/"; \
	done
	@# Search's model (models/search/): the published one, downloaded on the first make app (scripts/search-model.sh:
	@# once, about 350 MB; SEARCH_MODEL=0 skips it), then built in, compiled already (or compiled now, if converted on
	@# this Mac). Without it (offline, or skipped), search works on what was found and the descriptions alone.
	@scripts/search-model.sh
	@rm -rf "$(APP)/Contents/Resources/Search"
	@if [ -e models/search/siglip2.json ]; then \
	  mkdir -p "$(APP)/Contents/Resources/Search" && \
	  if ls models/search/*.mlpackage >/dev/null 2>&1; then \
	    for m in models/search/*.mlpackage; do xcrun coremlcompiler compile "$$m" "$(APP)/Contents/Resources/Search" >/dev/null; done; \
	  else cp -R models/search/*.mlmodelc "$(APP)/Contents/Resources/Search/"; fi && \
	  cp models/search/siglip2.json models/search/siglip2-tokenizer.json "$(APP)/Contents/Resources/Search/"; \
	fi
	@$(CODESIGN) --sign "$(SIGN)" --identifier pond "$(APP)/Contents/MacOS/pond"
	@$(CODESIGN) --sign "$(SIGN)" --identifier pond-signal "$(APP)/Contents/MacOS/pond-signal"
	@$(CODESIGN) --sign "$(SIGN)" --entitlements app/Pond.entitlements "$(APP)"
	@echo "✓ $(APP)"
	@# The login service may run the pond just replaced: macOS then stops letting the running copy reach the
	@# network ("No route to host"), so it is restarted on the new one.
	@if /bin/launchctl print gui/$$(id -u)/camera.pond.recorder 2>/dev/null | grep -q "program = $(CURDIR)/$(APP)/"; then \
	  "$(APP)/Contents/MacOS/pond" service restart; \
	fi

check:
	@scripts/check-private.sh
	swift build --package-path $(PKG) --build-tests -Xswiftc -warnings-as-errors

# A pre-commit hook of this checkout's own: what's staged is checked for footage, pictures and databases.
hooks:
	@printf '#!/bin/sh\nexec scripts/check-private.sh --staged\n' > .git/hooks/pre-commit && chmod +x .git/hooks/pre-commit
	@echo "✓ .git/hooks/pre-commit: no footage, pictures or databases in a commit"

test:
	swift test --package-path $(PKG)

# The source is mounted read-only and copied inside, so the container never writes into your checkout.
# Only the modules without Apple frameworks are built there; Package.swift leaves the others out on Linux.
test-docker:
	docker build -t $(IMAGE) tests
	docker run --rm -v "$(CURDIR)":/src:ro $(IMAGE) sh -c 'cp -R /src /work && rm -rf /work/src/.build && cd /work && swift test --package-path src'

# install copies pond to /usr/local/bin (asks for your password). update does the same, then restarts the
# login service if it is installed, so it runs the new version.
MACOS_ONLY = @[ "$$(uname -s)" = Darwin ] || { echo "pond runs on macOS; this is $$(uname -s). Nothing was installed."; exit 1; }
install: build
	$(MACOS_ONLY)
	sudo install -d /usr/local/bin
	sudo install -m 0755 dist/pond /usr/local/bin/pond
	@echo "✓ /usr/local/bin/pond"
	@echo "Next: pond init, pond storage recordings PATH, pond camera add ..., then pond service install"

update: install
	@if /usr/local/bin/pond service status >/dev/null 2>&1 && /bin/launchctl print gui/$$(id -u)/camera.pond.recorder >/dev/null 2>&1; then \
	  /usr/local/bin/pond service restart; \
	fi

# A release: signed with a Developer ID, notarized and stapled, in a disk image (scripts/release.sh, docs/release.md).
release:
	@scripts/release.sh "$(VERSION)"

signing:
	@scripts/setup-signing.sh

# Demo mode, in a copy of the app of its own (dist/demo): building it never restarts the real login service, and the
# demo runs its own services, apart from the real ones. (The real app opens one too: Settings › General.)
SCENARIO ?= home
demo:
	@# A demo already open is quit first (its services stop with it), so the new build is the one that opens.
	@# (A bracket in the pattern, so it doesn't match this shell's own command line, which holds it too.)
	@pkill -f "dist/demo/Pond NVR.app/Contents/MacOS/PondAp[p]" && sleep 1 || true
	@$(MAKE) app APP="dist/demo/Pond NVR.app"
	@# FRESH=1: the scenario's world started over (its settings, recordings and events), as on its first run.
	@$(if $(FRESH),"dist/demo/Pond NVR.app/Contents/MacOS/pond" demo prepare $(SCENARIO) --fresh >/dev/null,true)
	@# Opened as any app is (by Launch Services), so it comes to the front with its window; -n: a copy of its own,
	@# not the real Pond (the same bundle identifier) brought forward.
	open -n "dist/demo/Pond NVR.app" --args --demo $(SCENARIO)

clean:
	rm -rf dist $(PKG)/.build
