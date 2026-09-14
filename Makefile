APP      = ClaudeSwitcher
BIN      = .build/release/$(APP)
APP_DIR  = build/$(APP).app
DEST    ?= /Applications

VERSION  = $(shell sed -n 's/.*static let version = "\(.*\)".*/\1/p' Sources/ClaudeSwitcherCore/Models.swift)
DIST     = dist/$(APP)-$(VERSION).zip
DMG      = dist/$(APP)-$(VERSION).dmg

.PHONY: all build test app icon install run status doctor clean universal dist dmg uninstall release publish-file

all: app

build:
	swift build -c release

test:
	swift run ClaudeSwitcherChecks

icon: build/AppIcon.icns

build/AppIcon.icns: scripts/make-icon.swift
	mkdir -p build
	swift scripts/make-icon.swift build/AppIcon.iconset
	iconutil -c icns build/AppIcon.iconset -o $@

app: build icon
	bash scripts/make-app.sh

install: app
	-pkill -x $(APP); while pgrep -x $(APP) >/dev/null; do sleep 0.3; done; sleep 1
	rm -rf "$(DEST)/$(APP).app"
	cp -R "$(APP_DIR)" "$(DEST)/"
	open "$(DEST)/$(APP).app" || (sleep 2 && open "$(DEST)/$(APP).app")

run: app
	open "$(APP_DIR)"

status: build
	$(BIN) --status

doctor: build
	$(BIN) --doctor

# Universal binary without Xcode: SwiftPM's multi --arch needs xcbuild, so build each slice with --triple and lipo them.
# The x86_64 slice gets its own scratch path: sharing .build/ with the host build confuses SwiftPM's build description.
universal: build icon
	swift build -c release --triple x86_64-apple-macosx14.0 --scratch-path .build-x86_64
	mkdir -p build
	lipo -create -output build/$(APP)-universal .build/arm64-apple-macosx/release/$(APP) .build-x86_64/x86_64-apple-macosx/release/$(APP)
	BIN=build/$(APP)-universal bash scripts/make-app.sh

# Zip to hand to someone else (ditto keeps the bundle intact). Ad-hoc signed: the recipient must allow it once
# in System Settings > Privacy & Security, or run: xattr -dr com.apple.quarantine /Applications/$(APP).app
dist: universal
	mkdir -p dist
	rm -f "$(DIST)"
	ditto -c -k --keepParent "$(APP_DIR)" "$(DIST)"
	shasum -a 256 "$(DIST)" | tee "$(DIST).sha256"
	@echo "dist   $(DIST)"

# Drag-to-Applications disk image. Same Gatekeeper caveat as the zip: without Developer ID + notarization the
# recipient allows the app once (Privacy & Security > Open Anyway). The image carries the instructions.
dmg: universal
	-hdiutil info | grep -o '/Volumes/Claude Switcher[^\t]*' | while read -r v; do hdiutil detach "$$v" -quiet; done
	rm -rf dist/dmg "$(DMG)"
	mkdir -p dist/dmg
	cp -R "$(APP_DIR)" dist/dmg/
	ln -s /Applications dist/dmg/Applications
	cp Resources/dmg-README.txt "dist/dmg/DOC TRUOC KHI MO - README.txt"
	cp scripts/uninstall.sh dist/dmg/Uninstall.command
	chmod +x dist/dmg/Uninstall.command
	hdiutil create -quiet -volname "Claude Switcher $(VERSION)" -srcfolder dist/dmg -ov -format UDZO "$(DMG)"
	rm -rf dist/dmg
	shasum -a 256 "$(DMG)" | tee "$(DMG).sha256"
	@echo "dmg    $(DMG)"

uninstall:
	bash scripts/uninstall.sh

# Copy the dmg into releases/ (tracked): scripts/install.sh falls back to this when no GitHub Release exists.
publish-file: dmg
	mkdir -p releases
	cp "$(DMG)" "$(DMG).sha256" releases/
	printf '%s\n' "$(VERSION)" > releases/latest
	@echo "now: git add releases && git commit -m 'Release $(VERSION) dmg' && git push"

# Publish a GitHub release with the dmg; scripts/install.sh downloads from here.
release: dmg
	gh release create "v$(VERSION)" "$(DMG)" "$(DMG).sha256" --title "Claude Switcher $(VERSION)" --generate-notes \
	  --notes "Install: \`curl -fsSL https://raw.githubusercontent.com/pein1625/claude-account-switcher/main/scripts/install.sh | bash\`  (sha256 of the dmg in the .sha256 asset)"

clean:
	rm -rf .build .build-x86_64 build dist
