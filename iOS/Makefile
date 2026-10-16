PROJECT := MacParakeetiOS.xcodeproj
SCHEME := MacParakeetiOS
BUILD_DESTINATION ?= generic/platform=iOS Simulator
TEST_DESTINATION ?= platform=iOS Simulator,name=iPhone 15
DERIVED := build/DerivedData

.PHONY: project build test clean

project:
	xcodegen generate --spec project.yml

build: project
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination '$(BUILD_DESTINATION)' \
		-derivedDataPath $(DERIVED) build

test: project
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination '$(TEST_DESTINATION)' \
		-derivedDataPath $(DERIVED) test

clean:
	rm -rf $(PROJECT) build
