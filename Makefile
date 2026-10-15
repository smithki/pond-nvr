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

.PHONY: help build app check test test-docker clean install update signing

help:
	@echo "make build          build the pond command (release) into dist/"
	@echo "make app            build dist/Pond.app (the settings app, with pond inside for the login service)"
	@echo "make check          compile everything, tests included, with warnings as errors"
	@echo "make test           run the tests here (they write only temporary files, so a Mac is fine)"
	@echo "make test-docker    run the tests of the modules that build on Linux, in a throwaway container (needs Docker)"
	@echo "make install        build, then copy pond to /usr/local/bin (sudo)"
	@echo "make update         install, then restart the login service if it is installed"
	@echo "make clean          remove dist/ and the Swift build folder"
	@echo "make signing        once per Mac: a local signing certificate, so Keychain access survives rebuilds"

build:
	swift build --package-path $(PKG) -c release
	@# A new file rather than overwriting: macOS kills programs started from a file rewritten in place
	@# while another copy of it runs (the HomeKit accessory, the login service).
	@mkdir -p dist && rm -f dist/pond && cp "$$(swift build --package-path $(PKG) -c release --show-bin-path)/pond" dist/pond
	@codesign --force --sign "$(SIGN)" --identifier pond dist/pond
	@echo "✓ dist/pond$(if $(filter -,$(SIGN)), (signed ad hoc; make signing to stop repeated Keychain prompts))"

# Pond.app: the app's executable plus pond itself (Contents/MacOS/pond), which the login service runs when it is
# installed from the app. Signed as make build signs.
APP := dist/Pond.app
app: build
	swift build --package-path $(PKG) -c release --product NVRApp
	@rm -rf $(APP) && mkdir -p $(APP)/Contents/MacOS
	@cp "$$(swift build --package-path $(PKG) -c release --show-bin-path)/NVRApp" $(APP)/Contents/MacOS/PondApp
	@cp dist/pond $(APP)/Contents/MacOS/pond
	@cp app/Info.plist $(APP)/Contents/Info.plist
	@codesign --force --sign "$(SIGN)" --identifier pond $(APP)/Contents/MacOS/pond
	@codesign --force --sign "$(SIGN)" $(APP)
	@echo "✓ $(APP)"
	@# A setup from before the rename (nvr) moves over once: its service, settings, log and Keychain items.
	@if /bin/launchctl print gui/$$(id -u)/com.local.nvr >/dev/null 2>&1 || [ -e "$$HOME/Library/LaunchAgents/com.local.nvr.plist" ] \
	  || [ -e "$$HOME/Library/Application Support/nvr" ] || [ -e "$$HOME/Library/Logs/nvr" ]; then \
	  $(APP)/Contents/MacOS/pond migrate && rm -rf dist/NVR.app dist/nvr; \
	fi
	@# The login service may run the pond just replaced: macOS then stops letting the running copy reach the
	@# network ("No route to host"), so it is restarted on the new one.
	@if /bin/launchctl print gui/$$(id -u)/camera.pond.recorder 2>/dev/null | grep -q "program = $(CURDIR)/$(APP)/"; then \
	  $(APP)/Contents/MacOS/pond service restart; \
	fi

check:
	swift build --package-path $(PKG) --build-tests -Xswiftc -warnings-as-errors

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

signing:
	@scripts/setup-signing.sh

clean:
	rm -rf dist $(PKG)/.build
