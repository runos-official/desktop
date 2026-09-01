DEVELOPER_DIR := /Applications/Xcode.app/Contents/Developer
PROJECT := RunOSDesktop.xcodeproj
SCHEME := RunOSDesktop
CONFIGURATION ?= Debug
BUILD_ROOT := $(CURDIR)/build

.PHONY: build test run install verify release clean hooks leakcheck leakcheck-staged leakcheck-update leakcheck-test unscannable help

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

release:
	@test -n "$(VERSION)" || (echo "VERSION is required, for example v1.0.0-rc.1" >&2; exit 1)
	@scripts/release.sh "$(VERSION)" $(if $(CHECK),--check,)

clean:
	@DEVELOPER_DIR=$(DEVELOPER_DIR) xcodebuild -project $(PROJECT) -scheme $(SCHEME) -derivedDataPath $(BUILD_ROOT)/DerivedData clean >/dev/null 2>&1 || true
	@rm -rf "$(BUILD_ROOT)"

# ============================================================================
# Leak gate (PUBLIC repo)
# ============================================================================

# Install the tracked git hooks for this clone. .git/hooks is not tracked, so
# every clone must do this once. Run it right after you clone.
hooks:
	@git config core.hooksPath .githooks
	@echo "core.hooksPath = .githooks (pre-commit now runs leakcheck on the staged diff)"

# Scan every tracked file for credentials and un-baselined internal identifiers.
leakcheck:
	@python3 scripts/leakcheck.py

# Scan only the staged diff, the same way the pre-commit hook does.
leakcheck-staged:
	@python3 scripts/leakcheck.py --staged

# Ratchet the baseline down after you REMOVE an identifier from the source.
# Never run this to get a new identifier past the gate.
leakcheck-update:
	@python3 scripts/leakcheck.py --update

# Test the checker itself: what it must catch and what it must not.
leakcheck-test:
	@python3 scripts/leakcheck_test.py

# Fail on a tracked file leakcheck cannot READ. leakcheck reads UTF-8 text; a
# file holding a NUL byte or other bytes is read best effort at most, and some
# encodings escape it entirely (measured on checker 1.2.0: a token in a UTF-32
# file, and a token broken up by NUL bytes, both pass with exit 0). This target
# turns such a file into a decision somebody records, not a silent gap.
unscannable:
	@python3 scripts/unscannable_check.py

help:
	@echo "RunOS Desktop"
	@echo ""
	@echo "  make build            Build the application"
	@echo "  make test             Run the test suite"
	@echo "  make run              Build and open the application"
	@echo "  make install          Build and install into ~/Applications"
	@echo "  make verify           Clean, build, test and check the signature"
	@echo "  make clean            Remove build artifacts"
	@echo ""
	@echo "  make hooks            Install the tracked git hooks (run once per clone)"
	@echo "  make leakcheck        Scan every tracked file for leaks (PUBLIC repo gate)"
	@echo "  make leakcheck-staged Scan only the staged diff"
	@echo "  make leakcheck-update Ratchet the baseline down after removing an identifier"
	@echo "  make leakcheck-test   Test the leak checker itself"
	@echo "  make unscannable      Fail on a tracked file leakcheck cannot read"
	@echo ""
	@echo "  make release VERSION=vX.Y.Z          Cut a release"
	@echo "  make release VERSION=vX.Y.Z CHECK=1  Run the release gates only"
