APP_NAME   := Parfait
BUNDLE_ID  := io.github.conrad-vanl.Parfait
DIST       := dist
APP        := $(DIST)/$(APP_NAME).app
BINARY     := .build/release/$(APP_NAME)
# Ad-hoc by default. For a stable TCC identity across rebuilds we pin an explicit
# designated requirement. Set SIGN_ID to your "Apple Development: ..." identity
# for the best experience (permissions survive rebuilds without re-prompting).
SIGN_ID    ?= -

.PHONY: build test app run install icon clean

build:
	swift build -c release

test:
	swift test

app: build
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	cp "$(BINARY)" "$(APP)/Contents/MacOS/$(APP_NAME)"
	cp packaging/Info.plist "$(APP)/Contents/Info.plist"
	cp Resources/AppIcon.icns "$(APP)/Contents/Resources/AppIcon.icns"
	@# SwiftPM resource bundle (menu bar icon) must ride along or Bundle.module lookups fail
	@if [ -d ".build/release/$(APP_NAME)_$(APP_NAME).bundle" ]; then \
		cp -R ".build/release/$(APP_NAME)_$(APP_NAME).bundle" "$(APP)/Contents/Resources/"; \
	fi
	codesign --force --sign "$(SIGN_ID)" -r='designated => identifier "$(BUNDLE_ID)"' "$(APP)"
	@echo "Built $(APP)"

run: app
	open "$(APP)"

install: app
	rm -rf "/Applications/$(APP_NAME).app"
	cp -R "$(APP)" "/Applications/$(APP_NAME).app"
	@echo "Installed to /Applications/$(APP_NAME).app"

icon:
	swift scripts/MakeIcon.swift Resources

clean:
	rm -rf .build "$(DIST)"
