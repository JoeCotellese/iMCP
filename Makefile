# iMCP Makefile

PROJECT    := iMCP.xcodeproj
SCHEME     := iMCP
APP_NAME   := iMCP.app
INSTALL_DIR := /Applications

# Resolve DerivedData build products directory
BUILD_DIR = $(shell xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release -showBuildSettings 2>/dev/null | grep '^\s*BUILT_PRODUCTS_DIR' | head -1 | awk '{print $$3}')

.PHONY: help build debug install uninstall clean resolve open run

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

build: ## Build the app (Release)
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release build 2>&1 | xcsift

debug: ## Build the app (Debug)
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug build 2>&1 | xcsift

install: build ## Build and install to /Applications
	@echo "Installing $(APP_NAME) to $(INSTALL_DIR)..."
	@rm -rf "$(INSTALL_DIR)/$(APP_NAME)"
	@cp -R "$(BUILD_DIR)/$(APP_NAME)" "$(INSTALL_DIR)/$(APP_NAME)"
	@echo "Installed. You may need to restart the app."

uninstall: ## Remove from /Applications
	@echo "Removing $(APP_NAME) from $(INSTALL_DIR)..."
	@rm -rf "$(INSTALL_DIR)/$(APP_NAME)"
	@echo "Removed."

clean: ## Clean build artifacts and DerivedData
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) clean 2>&1 | xcsift
	@rm -rf ~/Library/Developer/Xcode/DerivedData/iMCP-*
	@echo "Clean complete."

resolve: ## Resolve Swift package dependencies
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -resolvePackageDependencies 2>&1 | xcsift

open: ## Open project in Xcode
	open $(PROJECT)

run: build ## Build and launch the app
	@open "$(BUILD_DIR)/$(APP_NAME)"
