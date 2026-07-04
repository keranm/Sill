APP_NAME := Sill
CONFIG   := release
BIN      := .build/$(CONFIG)/$(APP_NAME)
APP      := build/$(APP_NAME).app
SIGN_ID  := Developer ID Application: Keran McKenzie (AUEPCDGA5G)

.PHONY: app run debug clean

app:
	swift build -c $(CONFIG)
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp $(BIN) $(APP)/Contents/MacOS/$(APP_NAME)
	cp -R .build/$(CONFIG)/$(APP_NAME)_$(APP_NAME).bundle $(APP)/Contents/Resources/
	cp Support/AppIcon.icns $(APP)/Contents/Resources/
	cp Support/Info.plist $(APP)/Contents/Info.plist
	codesign --force --deep --options runtime --timestamp \
		--entitlements Support/Sill.entitlements \
		--sign "$(SIGN_ID)" $(APP)

run: app
	open $(APP)

debug:
	$(MAKE) app CONFIG=debug

clean:
	swift package clean
	rm -rf build
