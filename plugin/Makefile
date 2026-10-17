# Insta360 Stitch OpenFX plugin: macOS, Apple Silicon, Metal.
# The OpenFX headers and support library come from the SDK that ships with DaVinci Resolve.
OFX_SDK ?= /Library/Application Support/Blackmagic Design/DaVinci Resolve/Developer/OpenFX
INSTALL_DIR ?= /Library/OFX/Plugins

NAME    = Insta360Stitch
# The version lives in Info.plist only; the plugin is told it at build time.
VERSION := $(shell /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)
BUNDLE  = build/$(NAME).ofx.bundle
ARCH    = -arch arm64
# make cannot handle the spaces in the SDK path, so everything goes through this link.
SDK     = build/ofxsdk
CXXFLAGS = -std=c++17 -O2 -fvisibility=hidden $(ARCH) -mmacosx-version-min=13.0 \
           -I$(SDK)/OpenFX-1.4/include -I$(SDK)/Support/include -Wno-deprecated-declarations \
           -DPLUGIN_VERSION='"$(VERSION)"'
LDFLAGS = -bundle -fvisibility=hidden $(ARCH) -framework Metal -framework Foundation

SUPPORT = ofxsCore ofxsImageEffect ofxsInteract ofxsLog ofxsMultiThread ofxsParams ofxsProperty ofxsPropertyValidation
OBJS    = build/Updater.o build/StitchPlugin.o build/Calibration.o build/Tracker.o build/ProgressWindow.o build/MetalKernel.o $(SUPPORT:%=build/%.o)

all: $(BUNDLE)

$(BUNDLE): $(OBJS) Info.plist build/TrackProgress build/SeamRefine build/MediaTool resources/icon.svg resources/icon.png
	mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	$(CXX) $(OBJS) -o $(BUNDLE)/Contents/MacOS/$(NAME).ofx $(LDFLAGS)
	cp Info.plist $(BUNDLE)/Contents/Info.plist
	cp build/TrackProgress $(BUNDLE)/Contents/Resources/TrackProgress
	cp build/SeamRefine $(BUNDLE)/Contents/Resources/SeamRefine
	cp build/MediaTool $(BUNDLE)/Contents/Resources/MediaTool
	cp resources/icon.svg $(BUNDLE)/Contents/Resources/org.insta360resolve.Stitch.svg
	cp resources/icon.png $(BUNDLE)/Contents/Resources/org.insta360resolve.Stitch.png
	codesign --force --sign - $(BUNDLE)/Contents/Resources/TrackProgress
	codesign --force --sign - $(BUNDLE)/Contents/Resources/SeamRefine
	codesign --force --sign - $(BUNDLE)/Contents/Resources/MediaTool
	codesign --force --sign - $(BUNDLE)

# Progress window shown while tracking; a separate program because Resolve is busy meanwhile.
build/TrackProgress: src/ProgressHelper.mm | $(SDK)
	$(CXX) src/ProgressHelper.mm -o $@ $(ARCH) -mmacosx-version-min=13.0 -fobjc-arc -framework Cocoa

# Fits the seam calibration correction for tools/ingest.py, which must not need numpy or OpenCV.
build/SeamRefine: src/SeamRefine.cpp build/Calibration.o src/Calibration.h
	$(CXX) src/SeamRefine.cpp build/Calibration.o -o $@ $(CXXFLAGS)

# Splits and reads clips for tools/ingest.py with AVFoundation, so importing needs no ffmpeg.
build/MediaTool: src/MediaTool.mm | $(SDK)
	$(CXX) src/MediaTool.mm -o $@ $(ARCH) -mmacosx-version-min=13.0 -fobjc-arc -framework AVFoundation -framework CoreMedia -framework CoreGraphics -framework Foundation

build/%.o: src/%.cpp src/StitchKernel.h src/Calibration.h src/Tracker.h src/ProgressWindow.h | $(SDK)
	$(CXX) -c $< -o $@ $(CXXFLAGS)

build/StitchPlugin.o: Info.plist

build/Updater.o: src/Updater.mm src/Updater.h | $(SDK)
	$(CXX) -c $< -o $@ $(CXXFLAGS) -fobjc-arc

build/%.o: src/%.mm src/StitchKernel.h | $(SDK)
	$(CXX) -c $< -o $@ $(CXXFLAGS) -fno-objc-arc

build/ofxs%.o: | $(SDK)
	$(CXX) -c $(SDK)/Support/Library/ofxs$*.cpp -o $@ $(CXXFLAGS)

$(SDK):
	mkdir -p build
	ln -sfn "$(OFX_SDK)" $(SDK)

# Loads the built bundle the way a host would, and runs the Metal kernel on a test image.
test: $(BUNDLE) build/test_plugin
	build/test_plugin $(BUNDLE)/Contents/MacOS/$(NAME).ofx

build/test_plugin: test/test_plugin.mm build/MetalKernel.o build/Calibration.o build/Tracker.o src/StitchKernel.h src/Tracker.h
	$(CXX) test/test_plugin.mm build/MetalKernel.o build/Calibration.o build/Tracker.o -o $@ $(CXXFLAGS) -fno-objc-arc -Isrc \
	    -framework Metal -framework Foundation

install: $(BUNDLE)
	mkdir -p "$(INSTALL_DIR)"
	rm -rf "$(INSTALL_DIR)/$(NAME).ofx.bundle"
	cp -R $(BUNDLE) "$(INSTALL_DIR)/"

uninstall:
	rm -rf "$(INSTALL_DIR)/$(NAME).ofx.bundle"

clean:
	rm -rf build

.PHONY: all test install uninstall clean
