APP_NAME := Sill
CONFIG   := release
BIN      := .build/$(CONFIG)/$(APP_NAME)
APP      := build/$(APP_NAME).app
SIGN_ID  := Developer ID Application: Keran McKenzie (AUEPCDGA5G)

.PHONY: app run debug clean release

app:
	swift build -c $(CONFIG)
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources $(APP)/Contents/Frameworks
	cp $(BIN) $(APP)/Contents/MacOS/$(APP_NAME)
	install_name_tool -add_rpath @executable_path/../Frameworks $(APP)/Contents/MacOS/$(APP_NAME)
	cp -R .build/$(CONFIG)/$(APP_NAME)_$(APP_NAME).bundle $(APP)/Contents/Resources/
	cp Support/AppIcon.icns $(APP)/Contents/Resources/
	cp Support/Info.plist $(APP)/Contents/Info.plist
	ditto .build/$(CONFIG)/Sparkle.framework $(APP)/Contents/Frameworks/Sparkle.framework
	find $(APP)/Contents/Frameworks/Sparkle.framework -name "*.xpc" -o -name "Autoupdate" -o -name "Updater.app" | while read -r f; do \
		codesign --force --deep --options runtime --timestamp --sign "$(SIGN_ID)" "$$f"; \
	done
	codesign --force --options runtime --timestamp --sign "$(SIGN_ID)" $(APP)/Contents/Frameworks/Sparkle.framework
	codesign --force --options runtime --timestamp \
		--entitlements Support/Sill.entitlements \
		--sign "$(SIGN_ID)" $(APP)

run: app
	open $(APP)

debug:
	$(MAKE) app CONFIG=debug

clean:
	swift package clean
	rm -rf build

release:
	@if [ -z "$(VERSION)" ]; then echo "Usage: make release VERSION=0.2.0"; exit 1; fi
	./scripts/release.sh $(VERSION)
