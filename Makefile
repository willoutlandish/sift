APP_NAME = Ollie
BINARY = LarkMini
APP = dist/$(APP_NAME).app
BIN = .build/release/$(BINARY)

.PHONY: build app run demo dmg clean icon install

build:
	swift build -c release

app: build icon
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp $(BIN) $(APP)/Contents/MacOS/$(APP_NAME)
	cp Support/Info.plist $(APP)/Contents/Info.plist
	@if [ -f Support/AppIcon.icns ]; then cp Support/AppIcon.icns $(APP)/Contents/Resources/AppIcon.icns; fi
	@if [ -f Support/OllieHead.png ]; then cp Support/OllieHead.png $(APP)/Contents/Resources/OllieHead.png; fi
	codesign --force --deep --sign - $(APP)
	@echo "Built $(APP)"

install: app
	mkdir -p "$(HOME)/Applications" "$(HOME)/.local/bin"
	rm -rf "$(HOME)/Applications/Ollie.app"
	cp -R $(APP) "$(HOME)/Applications/Ollie.app"
	printf '#!/bin/sh\nexec "$(HOME)/Applications/Ollie.app/Contents/MacOS/Ollie" --cli "$$@"\n' > "$(HOME)/.local/bin/ollie"
	chmod +x "$(HOME)/.local/bin/ollie"
	@echo "Installed $(HOME)/Applications/Ollie.app and $(HOME)/.local/bin/ollie"

icon:
	@test -f Support/AppIcon.icns || (echo "Support/AppIcon.icns is missing" >&2; exit 1)

run: app
	open $(APP)

demo: app
	open $(APP) --args --demo

dmg: app
	rm -rf dist/dmg dist/$(APP_NAME).dmg
	mkdir -p dist/dmg
	cp -R $(APP) dist/dmg/
	ln -s /Applications dist/dmg/Applications
	hdiutil create -volname "Ollie" -srcfolder dist/dmg -ov -format UDZO dist/$(APP_NAME).dmg
	@echo "dist/$(APP_NAME).dmg"

clean:
	swift package clean
	rm -rf dist Support/AppIcon.iconset
