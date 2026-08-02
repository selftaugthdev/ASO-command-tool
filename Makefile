# The Command Line Tools toolchain has no XCTest, so the build is pinned to the
# Xcode toolchain. Mixing the two corrupts .build with "module compiled with
# Swift 6.2 cannot be imported by the Swift 6.3.3 compiler" errors.
DEVELOPER_DIR := /Applications/Xcode kopie.app/Contents/Developer
export DEVELOPER_DIR

APP_NAME  := ASO Command Center
BUILD_DIR := .build
CONFIG    := debug

.PHONY: build test release run app clean

build:
	swift build

test:
	swift test

release:
	swift build -c release

run: build
	swift run ASOCommandCenter

## Wraps the built binary in a .app bundle so it launches as a real windowed
## macOS app rather than a console process.
app: release
	./Tools/bundle.sh

clean:
	rm -rf $(BUILD_DIR) "dist"
