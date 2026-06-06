# Makefile — local mirror of CI. See plans/06-testing-ci.md.
PROJECT := Shoo.xcodeproj
SCHEME  := Shoo
DEST    := platform=macOS
NOSIGN  := CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""
RESULTS := TestResults.xcresult

.PHONY: bootstrap generate build test lint format coverage ci hooks clean help

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

bootstrap: ## Install tooling + generate project
	bash scripts/bootstrap.sh

generate: ## Regenerate Shoo.xcodeproj from project.yml
	xcodegen generate

build: generate ## Build the app (no signing)
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination '$(DEST)' $(NOSIGN) build

test: generate ## Run unit/integration tests with coverage
	rm -rf $(RESULTS)
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination '$(DEST)' \
		-enableCodeCoverage YES -resultBundlePath $(RESULTS) $(NOSIGN) test

lint: ## Run SwiftLint (strict)
	swiftlint lint --strict

format: ## Apply swift-format (optional; needs Swift 5.9+ `swift format`)
	swift format --in-place --recursive Shoo ShooTests

coverage: ## Print coverage from the last test run
	bash scripts/coverage.sh $(RESULTS)

hooks: ## Install opt-in git pre-commit hook
	bash scripts/install-git-hooks.sh

ci: generate lint build test coverage ## Full local CI mirror

clean: ## Remove build/test artifacts
	rm -rf $(RESULTS) build DerivedData
