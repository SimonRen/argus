# Argus — a macOS menubar app for Claude Code, Codex and Antigravity CLI logins and allowances.
#
#   make build                   app bundle in build/, ad-hoc signed (the dev build)
#   make dev                     build, quit a running Argus, open the fresh one
#   make test                    swift test
#   make check                   version check + build + test: the gate CI runs
#   make install                 copy the build to ~/Applications (Launch at login needs it there)
#   make run                     install, then open the installed copy
#   make bump VERSION=x.y.z      set VERSION and roll CHANGELOG.md's [Unreleased] into [x.y.z]
#   make release VERSION=x.y.z   Developer ID signed, notarized, stapled DMG → releases/   (human-run)
#   make publish VERSION=x.y.z   attach that DMG to a GitHub release v<x.y.z>              (human-run)
#   make clean                   delete build products (releases/ is kept)

SCRATCH ?= .build
OUT ?= build
# Signing identity; "-" is ad-hoc. The release passes the Developer ID.
SIGN ?= -
# Extra codesign flags; the release adds the hardened runtime and a secure timestamp.
CODESIGN_FLAGS ?=
# Extra swift build flags; the release pins the Apple-silicon slice.
SWIFT_FLAGS ?=

APP := $(OUT)/Argus.app
INSTALLED := $(HOME)/Applications/Argus.app
PLIST := Resources/Info.plist
# The version lives in VERSION (Semantic Versioning); the build number is the commit count, so it only grows on main.
APP_VERSION := $(shell cat VERSION)
BUILD_NUMBER := $(shell git rev-list --count HEAD 2>/dev/null || echo 0)
BIN = $$(swift build -c release $(SWIFT_FLAGS) --scratch-path "$(SCRATCH)" --show-bin-path)

.PHONY: build dev test check version-check install run bump release publish clean

build:
	swift build -c release $(SWIFT_FLAGS) --scratch-path "$(SCRATCH)" --product Argus
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	cp "$(BIN)/Argus" "$(APP)/Contents/MacOS/Argus"
	cp Resources/AppIcon.icns "$(APP)/Contents/Resources/AppIcon.icns"
	cp Resources/ToolIcons/* "$(APP)/Contents/Resources/"
	cp "$(PLIST)" "$(APP)/Contents/Info.plist"
	plutil -replace CFBundleShortVersionString -string "$(APP_VERSION)" "$(APP)/Contents/Info.plist"
	plutil -replace CFBundleVersion -string "$(BUILD_NUMBER)" "$(APP)/Contents/Info.plist"
	xattr -cr "$(APP)"
	codesign --force --sign "$(SIGN)" $(CODESIGN_FLAGS) "$(APP)"

# The single-instance lock would otherwise keep the stale copy and quit the fresh one.
dev: build
	@killall Argus 2>/dev/null || true
	@open "$(APP)"
	@echo "▶ launched $(APP)"

test:
	swift test

check: version-check build test

version-check:
	@echo "$(APP_VERSION)" | grep -qEx '(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)' || { echo "VERSION must hold one x.y.z version (Semantic Versioning), not \"$(APP_VERSION)\"" >&2; exit 1; }
	@grep -q '^## \[Unreleased\]$$' CHANGELOG.md || { echo "CHANGELOG.md needs a '## [Unreleased]' heading" >&2; exit 1; }

install: build
	mkdir -p "$(HOME)/Applications"
	rm -rf "$(INSTALLED)"
	cp -R "$(APP)" "$(INSTALLED)"

run: install
	@killall Argus 2>/dev/null || true
	open "$(INSTALLED)"

bump:
	scripts/bump.sh $(VERSION)

# HUMAN-RUN ONLY: needs the Developer ID in the login keychain and a notarytool profile (see scripts/release.sh).
release:
	scripts/release.sh $(VERSION)

# HUMAN-RUN ONLY: pushes the release tag and creates the release on GitHub.
publish:
	scripts/publish.sh $(VERSION)

clean:
	rm -rf .build .build-bundle-test build build_release
