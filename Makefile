DEVELOPER_DIR := /Applications/Xcode.app/Contents/Developer
PROJECT := RunOSDesktop.xcodeproj
SCHEME := RunOSDesktop
CONFIGURATION ?= Debug
BUILD_ROOT := $(CURDIR)/build

.PHONY: build test run install verify clean

build:
	@DEVELOPER_DIR=$(DEVELOPER_DIR) xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIGURATION) -derivedDataPath $(BUILD_ROOT)/DerivedData build

test:
	@DEVELOPER_DIR=$(DEVELOPER_DIR) xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug -derivedDataPath $(BUILD_ROOT)/DerivedData test

run: build
	@open "$(BUILD_ROOT)/DerivedData/Build/Products/$(CONFIGURATION)/RunOS Desktop.app"

install: build
	@mkdir -p "$(HOME)/Applications"
	@ditto "$(BUILD_ROOT)/DerivedData/Build/Products/$(CONFIGURATION)/RunOS Desktop.app" "$(HOME)/Applications/RunOS Desktop.app"

verify: clean build test
	@codesign --verify --deep --strict "$(BUILD_ROOT)/DerivedData/Build/Products/$(CONFIGURATION)/RunOS Desktop.app"

clean:
	@DEVELOPER_DIR=$(DEVELOPER_DIR) xcodebuild -project $(PROJECT) -scheme $(SCHEME) -derivedDataPath $(BUILD_ROOT)/DerivedData clean >/dev/null 2>&1 || true
	@rm -rf "$(BUILD_ROOT)"
