# Insta360 Stitch OpenFX plugin: macOS, Apple Silicon, Metal.
# The OpenFX headers and support library come from the SDK that ships with DaVinci Resolve.
OFX_SDK ?= /Library/Application Support/Blackmagic Design/DaVinci Resolve/Developer/OpenFX
INSTALL_DIR ?= /Library/OFX/Plugins
# Build output: /Volumes/Code/.derived/insta360-resolve when that folder exists (the author's Mac keeps
# build files out of the source folder), else build/ here. Override with: make BUILD=<dir>
BUILD ?= $(if $(wildcard /Volumes/Code/.derived),/Volumes/Code/.derived/insta360-resolve,build)


NAME    = Insta360Stitch
# The version lives in Info.plist only; the plugin is told it at build time.
VERSION := $(shell /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)
BUNDLE  = $(BUILD)/$(NAME).ofx.bundle
ARCH    = -arch arm64
# make cannot handle the spaces in the SDK path, so everything goes through this link.
SDK     = $(BUILD)/ofxsdk
CXXFLAGS = -std=c++17 -O2 -fvisibility=hidden $(ARCH) -mmacosx-version-min=13.0 \
           -I$(SDK)/OpenFX-1.4/include -I$(SDK)/Support/include -Wno-deprecated-declarations \
           -DPLUGIN_VERSION='"$(VERSION)"'
LDFLAGS = -bundle -fvisibility=hidden $(ARCH) -framework Metal -framework Foundation \
          -framework AVFoundation -framework CoreMedia -framework CoreVideo -framework Vision

SUPPORT = ofxsCore ofxsImageEffect ofxsInteract ofxsLog ofxsMultiThread ofxsParams ofxsProperty ofxsPropertyValidation
OBJS    = $(BUILD)/Updater.o $(BUILD)/StitchPlugin.o $(BUILD)/Calibration.o $(BUILD)/Tracker.o $(BUILD)/Registry.o $(BUILD)/Motion.o $(BUILD)/ProgressWindow.o $(BUILD)/MetalKernel.o $(BUILD)/LensDecoder.o $(BUILD)/MotionBlur.o $(SUPPORT:%=$(BUILD)/%.o)

all: $(BUNDLE)

$(BUNDLE): $(OBJS) Info.plist $(BUILD)/TrackProgress $(BUILD)/SeamRefine $(BUILD)/MediaTool resources/icon.svg resources/icon.png
	mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	$(CXX) $(OBJS) -o $(BUNDLE)/Contents/MacOS/$(NAME).ofx $(LDFLAGS)
	cp Info.plist $(BUNDLE)/Contents/Info.plist
	cp $(BUILD)/TrackProgress $(BUNDLE)/Contents/Resources/TrackProgress
	cp $(BUILD)/SeamRefine $(BUNDLE)/Contents/Resources/SeamRefine
	cp $(BUILD)/MediaTool $(BUNDLE)/Contents/Resources/MediaTool
	cp resources/icon.svg $(BUNDLE)/Contents/Resources/org.insta360resolve.Stitch.svg
	cp resources/icon.png $(BUNDLE)/Contents/Resources/org.insta360resolve.Stitch.png
	codesign --force --sign - $(BUNDLE)/Contents/Resources/TrackProgress
	codesign --force --sign - $(BUNDLE)/Contents/Resources/SeamRefine
	codesign --force --sign - $(BUNDLE)/Contents/Resources/MediaTool
	codesign --force --sign - $(BUNDLE)

# Progress window shown while tracking; a separate program because Resolve is busy meanwhile.
$(BUILD)/TrackProgress: src/ProgressHelper.mm | $(SDK)
	$(CXX) src/ProgressHelper.mm -o $@ $(ARCH) -mmacosx-version-min=13.0 -fobjc-arc -framework Cocoa

# Fits the seam calibration correction for tools/ingest.py, which must not need numpy or OpenCV.
$(BUILD)/SeamRefine: src/SeamRefine.cpp $(BUILD)/Calibration.o src/Calibration.h
	$(CXX) src/SeamRefine.cpp $(BUILD)/Calibration.o -o $@ $(CXXFLAGS)

# Splits and reads clips for tools/ingest.py with AVFoundation, so importing needs no ffmpeg.
$(BUILD)/MediaTool: src/MediaTool.mm | $(SDK)
	$(CXX) src/MediaTool.mm -o $@ $(ARCH) -mmacosx-version-min=13.0 -fobjc-arc -framework AVFoundation -framework CoreMedia -framework CoreGraphics -framework CoreVideo -framework ImageIO -framework Foundation

$(BUILD)/%.o: src/%.cpp src/StitchKernel.h src/Calibration.h src/Tracker.h src/ProgressWindow.h src/ClipTag.h src/Registry.h src/Motion.h src/MotionBlur.h src/LensDecoder.h | $(SDK)
	$(CXX) -c $< -o $@ $(CXXFLAGS)

$(BUILD)/StitchPlugin.o: Info.plist

$(BUILD)/Updater.o: src/Updater.mm src/Updater.h | $(SDK)
	$(CXX) -c $< -o $@ $(CXXFLAGS) -fobjc-arc

# Decodes the lens files at full resolution; ARC, unlike the Metal kernel.
$(BUILD)/LensDecoder.o: src/LensDecoder.mm src/LensDecoder.h | $(SDK)
	$(CXX) -c $< -o $@ $(CXXFLAGS) -fobjc-arc

$(BUILD)/%.o: src/%.mm src/StitchKernel.h src/LensDecoder.h src/MotionBlur.h | $(SDK)
	$(CXX) -c $< -o $@ $(CXXFLAGS) -fno-objc-arc

$(BUILD)/ofxs%.o: | $(SDK)
	$(CXX) -c $(SDK)/Support/Library/ofxs$*.cpp -o $@ $(CXXFLAGS)

$(SDK):
	mkdir -p $(BUILD)
	ln -sfn "$(OFX_SDK)" $(SDK)

# Loads the built bundle the way a host would, and runs the Metal kernel on a test image.
test: $(BUNDLE) $(BUILD)/test_plugin
	$(BUILD)/test_plugin $(BUNDLE)/Contents/MacOS/$(NAME).ofx

$(BUILD)/test_plugin: test/test_plugin.mm $(BUILD)/MetalKernel.o $(BUILD)/Calibration.o $(BUILD)/Tracker.o $(BUILD)/LensDecoder.o $(BUILD)/MotionBlur.o $(BUILD)/Motion.o src/StitchKernel.h src/Tracker.h src/LensDecoder.h
	$(CXX) test/test_plugin.mm $(BUILD)/MetalKernel.o $(BUILD)/Calibration.o $(BUILD)/Tracker.o $(BUILD)/LensDecoder.o $(BUILD)/MotionBlur.o $(BUILD)/Motion.o -o $@ $(CXXFLAGS) -fno-objc-arc -Isrc \
	    -framework Metal -framework Foundation -framework AVFoundation -framework CoreMedia -framework CoreVideo -framework Vision -framework Accelerate

install: $(BUNDLE)
	mkdir -p "$(INSTALL_DIR)"
	rm -rf "$(INSTALL_DIR)/$(NAME).ofx.bundle"
	cp -R $(BUNDLE) "$(INSTALL_DIR)/"

uninstall:
	rm -rf "$(INSTALL_DIR)/$(NAME).ofx.bundle"

clean:
	rm -rf $(BUILD)

.PHONY: all test install uninstall clean

# Prints the build folder (used by the installer scripts).
print-build:
	@echo $(BUILD)
.PHONY: print-build
