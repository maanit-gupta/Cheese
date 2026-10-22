PROJECT    := Cheese.xcodeproj
SCHEME     := Cheese
DERIVED    := build/DerivedData
APP        := $(DERIVED)/Build/Products/Debug/Cheese.app
XCODEBUILD := xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination 'platform=macOS' -derivedDataPath $(DERIVED)

.PHONY: generate build test test-integration run release clean

# The .xcodeproj is generated and gitignored, so every target regenerates it first.
generate:
	xcodegen generate

build: generate
	$(XCODEBUILD) -configuration Debug build

# Unit tests, then the app size budget (Release build ≤ the v2.5 baseline + 2 MB).
test: generate
	$(XCODEBUILD) test
	scripts/check-size.sh

# Also runs the slower Files tests that render through WebKit and the vendored Office renderers.
test-integration: generate
	TEST_RUNNER_FILES_INTEGRATION=1 $(XCODEBUILD) test

run: build
	-pkill -x Cheese
	open $(APP)

# Release build zipped for GitHub Releases: dist/Cheese.zip + dist/Cheese.zip.sha256
release:
	scripts/package.sh

clean:
	rm -rf build dist
