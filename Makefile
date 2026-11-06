APP_NAME = Ollie Dev
DEV_APP_NAME = Ollie Dev
REAL_APP_NAME = Ollie
BINARY = LarkMini
DEV_APP = dist/$(DEV_APP_NAME).app
REAL_APP = dist/$(REAL_APP_NAME).app
BIN = .build/release/$(BINARY)
APP = $(DEV_APP)

.PHONY: build app real-app check-dev run demo dmg clean icon install

build:
	swift build -c release

icon:
	@test -f Support/AppIcon.icns || (echo "Support/AppIcon.icns is missing" >&2; exit 1)

app: build icon
	rm -rf "$(DEV_APP)"
	mkdir -p "$(DEV_APP)/Contents/MacOS" "$(DEV_APP)/Contents/Resources"
	cp $(BIN) "$(DEV_APP)/Contents/MacOS/$(DEV_APP_NAME)"
	cp Support/Info.plist "$(DEV_APP)/Contents/Info.plist"
	@if [ -f Support/AppIcon.icns ]; then cp Support/AppIcon.icns "$(DEV_APP)/Contents/Resources/AppIcon.icns"; fi
	@if [ -f Support/OllieHead.png ]; then cp Support/OllieHead.png "$(DEV_APP)/Contents/Resources/OllieHead.png"; fi
	/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.outlandish.ollie.dev" "$(DEV_APP)/Contents/Info.plist"
	/usr/libexec/PlistBuddy -c "Set :CFBundleName Ollie Dev" "$(DEV_APP)/Contents/Info.plist"
	/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Ollie Dev" "$(DEV_APP)/Contents/Info.plist"
	/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable Ollie Dev" "$(DEV_APP)/Contents/Info.plist"
	/usr/libexec/PlistBuddy -c "Set :CFBundleURLTypes:0:CFBundleURLName com.outlandish.ollie.dev" "$(DEV_APP)/Contents/Info.plist"
	/usr/libexec/PlistBuddy -c "Set :CFBundleURLTypes:0:CFBundleURLSchemes:0 ollie-dev" "$(DEV_APP)/Contents/Info.plist"
	codesign --force --deep --sign - "$(DEV_APP)"
	@echo "Built $(DEV_APP)"

check-dev: app
	@id=$$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$(DEV_APP)/Contents/Info.plist"); \
	case "$$id" in *.dev) echo "dev bundle id ok: $$id";; *) echo "dist app is not a dev identity: $$id" >&2; exit 1;; esac

real-app: build icon
	rm -rf "$(REAL_APP)"
	mkdir -p "$(REAL_APP)/Contents/MacOS" "$(REAL_APP)/Contents/Resources"
	cp $(BIN) "$(REAL_APP)/Contents/MacOS/$(REAL_APP_NAME)"
	cp Support/Info.plist "$(REAL_APP)/Contents/Info.plist"
	@if [ -f Support/AppIcon.icns ]; then cp Support/AppIcon.icns "$(REAL_APP)/Contents/Resources/AppIcon.icns"; fi
	@if [ -f Support/OllieHead.png ]; then cp Support/OllieHead.png "$(REAL_APP)/Contents/Resources/OllieHead.png"; fi
	codesign --force --deep --sign - "$(REAL_APP)"
	@echo "Built $(REAL_APP)"

install: real-app
	mkdir -p "$(HOME)/Applications" "$(HOME)/.local/bin"
	rm -rf "$(HOME)/Applications/Ollie.app"
	cp -R "$(REAL_APP)" "$(HOME)/Applications/Ollie.app"
	printf '#!/bin/sh\nexec "$(HOME)/Applications/Ollie.app/Contents/MacOS/Ollie" --cli "$$@"\n' > "$(HOME)/.local/bin/ollie"
	chmod +x "$(HOME)/.local/bin/ollie"
	@echo "Installed $(HOME)/Applications/Ollie.app and $(HOME)/.local/bin/ollie"

run: app
	open "$(DEV_APP)"

demo: app
	open "$(DEV_APP)" --args --demo

dmg: app
	rm -rf dist/dmg "dist/$(DEV_APP_NAME).dmg"
	mkdir -p dist/dmg
	cp -R "$(DEV_APP)" dist/dmg/
	ln -s /Applications dist/dmg/Applications
	hdiutil create -volname "$(DEV_APP_NAME)" -srcfolder dist/dmg -ov -format UDZO "dist/$(DEV_APP_NAME).dmg"
	@echo "dist/$(DEV_APP_NAME).dmg"

clean:
	swift package clean
	rm -rf dist Support/AppIcon.iconset
