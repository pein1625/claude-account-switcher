APP      = ClaudeSwitcher
BIN      = .build/release/$(APP)
APP_DIR  = build/$(APP).app
DEST    ?= /Applications

VERSION  = $(shell sed -n 's/.*static let version = "\(.*\)".*/\1/p' Sources/ClaudeSwitcherCore/Models.swift)
DIST     = dist/$(APP)-$(VERSION).zip
DMG      = dist/$(APP)-$(VERSION).dmg

.PHONY: all build test app icon install run status doctor clean universal dist dmg dmg-plain uninstall release publish-file ship

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

# Drag-to-Applications disk image with background + icon layout (dmgbuild writes the .DS_Store; no Finder
# scripting). dmgbuild lives in a repo-local venv created on first use. Same Gatekeeper caveat as the zip:
# without Developer ID + notarization the recipient allows the app once (Privacy & Security > Open Anyway).
DMGBUILD = .venv-dmg/bin/dmgbuild

$(DMGBUILD):
	python3 -m venv .venv-dmg
	.venv-dmg/bin/pip install --quiet dmgbuild

build/dmg-bg.tiff: scripts/make-dmg-bg.swift
	mkdir -p build
	swift scripts/make-dmg-bg.swift build/dmg-bg
	tiffutil -cathidpicheck build/dmg-bg.png build/dmg-bg@2x.png -out $@

dmg: universal $(DMGBUILD) build/dmg-bg.tiff
	-hdiutil info | grep -o '/Volumes/Claude Switcher[^\t]*' | while read -r v; do hdiutil detach "$$v" -quiet; done
	rm -rf dist/dmg "$(DMG)"
	mkdir -p dist/dmg
	cp -R "$(APP_DIR)" dist/dmg/
	cp Resources/dmg-README.txt "dist/dmg/DOC TRUOC KHI MO - README.txt"
	cp scripts/uninstall.sh dist/dmg/Uninstall.command
	chmod +x dist/dmg/Uninstall.command
	$(DMGBUILD) -s scripts/dmg-settings.py -D stage=dist/dmg -D background=build/dmg-bg.tiff -D icon=build/AppIcon.icns "Claude Switcher" "$(DMG)"
	rm -rf dist/dmg
	shasum -a 256 "$(DMG)" | tee "$(DMG).sha256"
	@echo "dmg    $(DMG)"

# Plain image without layout (no Python needed).
dmg-plain: universal
	rm -rf dist/dmg "$(DMG)"
	mkdir -p dist/dmg
	cp -R "$(APP_DIR)" dist/dmg/
	ln -s /Applications dist/dmg/Applications
	cp Resources/dmg-README.txt "dist/dmg/DOC TRUOC KHI MO - README.txt"
	cp scripts/uninstall.sh dist/dmg/Uninstall.command
	chmod +x dist/dmg/Uninstall.command
	hdiutil create -quiet -volname "Claude Switcher" -srcfolder dist/dmg -ov -format UDZO "$(DMG)"
	rm -rf dist/dmg
	shasum -a 256 "$(DMG)" | tee "$(DMG).sha256"

uninstall:
	bash scripts/uninstall.sh

# Copy the dmg into releases/ (tracked): scripts/install.sh falls back to this when no GitHub Release exists.
publish-file: dmg
	mkdir -p releases
	cp "$(DMG)" "$(DMG).sha256" releases/
	printf '%s\n' "$(VERSION)" > releases/latest
	@echo "now: git add releases && git commit -m 'Release $(VERSION) dmg' && git push"

# From a committed app change to every install path in one step: checks, the dmg, releases/ (the in-app updater's
# second source and install.sh's fallback), the README download link, a release commit pushed to main, and the
# GitHub Release that install.sh and the updater read first. Refuses a dirty tree, another branch, and a version
# that is already out (bump AppInfo.version in Sources/ClaudeSwitcherCore/Models.swift).
ship: test
	@[ "$$(git rev-parse --abbrev-ref HEAD)" = main ] || { echo "ship: not on main"; exit 1; }
	@git diff --quiet HEAD -- . || { echo "ship: commit the app change first"; exit 1; }
	@[ "$$(cat releases/latest 2>/dev/null)" != "$(VERSION)" ] || { echo "ship: $(VERSION) is already published - bump AppInfo.version"; exit 1; }
	@! gh release view "v$(VERSION)" >/dev/null 2>&1 || { echo "ship: GitHub Release v$(VERSION) already exists"; exit 1; }
	$(MAKE) publish-file
	sed -i '' -E 's#releases/ClaudeSwitcher-[0-9.]+\.dmg#releases/ClaudeSwitcher-$(VERSION).dmg#; s#Phiên bản [0-9.]+ #Phiên bản $(VERSION) #' README.md
	git add releases README.md
	git commit -q -m "Release $(VERSION) dmg"
	git push -q origin main
	gh release create "v$(VERSION)" "$(DMG)" "$(DMG).sha256" --title "Claude Switcher $(VERSION)" --latest --generate-notes \
	  --notes "Install: \`curl -fsSL https://raw.githubusercontent.com/pein1625/claude-account-switcher/main/scripts/install.sh | bash\`  (sha256 of the dmg in the .sha256 asset). Already installed: menu › Cập nhật."
	@echo "shipped $(VERSION): releases/, README link, GitHub Release v$(VERSION)"

# Publish a GitHub release with the dmg; scripts/install.sh downloads from here.
release: dmg
	gh release create "v$(VERSION)" "$(DMG)" "$(DMG).sha256" --title "Claude Switcher $(VERSION)" --generate-notes \
	  --notes "Install: \`curl -fsSL https://raw.githubusercontent.com/pein1625/claude-account-switcher/main/scripts/install.sh | bash\`  (sha256 of the dmg in the .sha256 asset)"

clean:
	rm -rf .build .build-x86_64 build dist

distclean: clean
	rm -rf .venv-dmg
