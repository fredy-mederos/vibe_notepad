# Vibe Notepad — common tasks. Requires Xcode 26+ and XcodeGen (brew install xcodegen).
APP_NAME  := Vibe Notepad
DERIVED   := build/DerivedData
XCB       := xcodebuild -project VibeNotepad.xcodeproj -scheme VibeNotepad -derivedDataPath $(DERIVED) -destination 'platform=macOS'

.PHONY: project build release run test install cli icon clean

project:   ## Regenerate VibeNotepad.xcodeproj from project.yml
	xcodegen generate

build: project   ## Debug build
	$(XCB) -configuration Debug build

release: project   ## Release build
	$(XCB) -configuration Release build

run: build   ## Build and launch the debug app
	open "$(DERIVED)/Build/Products/Debug/$(APP_NAME).app"

test:   ## Run the VibeCore unit tests
	swift test --package-path Packages/VibeCore

install:   ## Build Release, install to /Applications and install the vibeNotePad command
	scripts/install.sh

cli:   ## Install only the vibeNotePad command
	scripts/install-cli.sh

icon:   ## Re-render the app icon
	swift scripts/generate_icon.swift VibeNotepad/Resources/Assets.xcassets/AppIcon.appiconset

clean:
	rm -rf build
