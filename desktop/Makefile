.PHONY: all check-xcode build test run

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
