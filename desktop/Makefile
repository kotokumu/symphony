.PHONY: all check-xcode build test run package validate-package

all: build test

check-xcode:
	@test -x "$$(xcode-select -p)/usr/bin/xcodebuild" || { \
		echo "error: full Xcode is required; Xcode Command Line Tools alone are unsupported" >&2; \
		exit 1; \
	}

build: check-xcode
	swift build

test: check-xcode
	swift test

run: check-xcode
	@test -n "$(SYMPHONY_CODE_SIGN_IDENTITY)" || { \
		echo "error: set SYMPHONY_CODE_SIGN_IDENTITY to an Apple Development signing identity" >&2; \
		exit 1; \
	}
	./scripts/run-signed-dev-app.sh "$(SYMPHONY_CODE_SIGN_IDENTITY)"

package: check-xcode
	@test -n "$(SYMPHONY_VERSION)" || { echo "error: set SYMPHONY_VERSION" >&2; exit 1; }
	@test -n "$(SYMPHONY_CODE_SIGN_IDENTITY)" || { echo "error: set SYMPHONY_CODE_SIGN_IDENTITY" >&2; exit 1; }
	@test -n "$(SYMPHONY_NOTARY_PROFILE)" || { echo "error: set SYMPHONY_NOTARY_PROFILE for a notarized release" >&2; exit 1; }
	./scripts/package-macos.sh --identity "$(SYMPHONY_CODE_SIGN_IDENTITY)" \
	  --version "$(SYMPHONY_VERSION)" --output "$(SYMPHONY_OUTPUT_DIR)" \
	  $(if $(SYMPHONY_NOTARY_PROFILE),--notary-profile "$(SYMPHONY_NOTARY_PROFILE)",)

validate-package: check-xcode
	@test -n "$(SYMPHONY_VERSION)" || { echo "error: set SYMPHONY_VERSION" >&2; exit 1; }
	./scripts/package-macos.sh --unsigned --version "$(SYMPHONY_VERSION)" \
	  --output "$(SYMPHONY_OUTPUT_DIR)"
	version="$(SYMPHONY_VERSION)"; case "$$version" in desktop-v*) version="$${version#desktop-v}";; esac; \
	archive="$(SYMPHONY_OUTPUT_DIR)/Symphony-$$version-macos.zip"; test -f "$$archive"; \
	SYMPHONY_ALLOW_UNSIGNED=1 SYMPHONY_PACKAGE_ARCHIVE="$$archive" \
	  ./scripts/validate-macos-mvp.sh "$(SYMPHONY_OUTPUT_DIR)/Symphony.app"
	./scripts/test-macos-package-validation.sh
