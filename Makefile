SCRATCH ?= .build
OUT ?= build
SIGN ?= -

APP := $(OUT)/MagpieLite.app
INSTALLED := $(HOME)/Applications/MagpieLite.app

.PHONY: build test check install run clean

build:
	swift build -c release --scratch-path "$(SCRATCH)" --product MagpieLite
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	cp "$$(swift build -c release --scratch-path "$(SCRATCH)" --show-bin-path)/MagpieLite" "$(APP)/Contents/MacOS/MagpieLite"
	cp Resources/AppIcon.icns "$(APP)/Contents/Resources/AppIcon.icns"
	cp Resources/Info.plist "$(APP)/Contents/Info.plist"
	xattr -cr "$(APP)"
	codesign --force --sign "$(SIGN)" "$(APP)"

test:
	swift test

check: build test

install: build
	mkdir -p "$(HOME)/Applications"
	rm -rf "$(INSTALLED)"
	cp -R "$(APP)" "$(INSTALLED)"

run: install
	open "$(INSTALLED)"

clean:
	rm -rf .build .build-bundle-test build
