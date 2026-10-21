PROJECT    := Cheese.xcodeproj
SCHEME     := Cheese
DERIVED    := build/DerivedData
APP        := $(DERIVED)/Build/Products/Debug/Cheese.app
XCODEBUILD := xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination 'platform=macOS' -derivedDataPath $(DERIVED)

.PHONY: generate build test run clean

# The .xcodeproj is generated and gitignored, so every target regenerates it first.
generate:
	xcodegen generate

build: generate
	$(XCODEBUILD) -configuration Debug build

test: generate
	$(XCODEBUILD) test

run: build
	-pkill -x Cheese
	open $(APP)

clean:
	rm -rf build
