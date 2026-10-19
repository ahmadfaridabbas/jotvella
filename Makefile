# Jotvella build orchestration.
#
# `swift build` on its own does NOT rebuild the Rust OneNote importer; it only
# bundles the prebuilt binary already committed at
# Sources/Jotvella/Resources/jotvella-one-importer. These targets keep that
# binary reproducible and in sync with Tools/OneNoteImporter/src.

CARGO ?= cargo
IMPORTER_MANIFEST := Tools/OneNoteImporter/Cargo.toml
IMPORTER_BIN := Tools/OneNoteImporter/target/release/jotvella-one-importer
IMPORTER_DEST := Sources/Jotvella/Resources/jotvella-one-importer
IMPORTER_SRC := $(wildcard Tools/OneNoteImporter/src/*.rs) $(IMPORTER_MANIFEST)

# App bundle layout.
CONFIG ?= release
BIN_DIR := $(shell swift build -c $(CONFIG) --show-bin-path 2>/dev/null)
APP := Jotvella.app
APP_CONTENTS := $(APP)/Contents
APP_MACOS := $(APP_CONTENTS)/MacOS
APP_RESOURCES := $(APP_CONTENTS)/Resources
RESOURCE_BUNDLE := Jotvella_Jotvella.bundle
ICONSET := Assets/Jotvella.iconset

.PHONY: all build run importer clean-importer app open clean-app

# Build the full app, refreshing the bundled importer first.
all: build

build: importer
	swift build

run: importer
	swift run

# Rebuild the Rust helper and refresh the copy bundled as an app resource.
# Only re-links when the Rust sources or manifest change.
importer: $(IMPORTER_DEST)

$(IMPORTER_DEST): $(IMPORTER_SRC)
	$(CARGO) build --release --manifest-path $(IMPORTER_MANIFEST)
	cp $(IMPORTER_BIN) $(IMPORTER_DEST)

clean-importer:
	$(CARGO) clean --manifest-path $(IMPORTER_MANIFEST)

# Assemble a double-clickable Jotvella.app bundle (Dock icon, Finder launch).
# Builds in release, compiles the icon from the iconset, and copies the
# SwiftPM resource bundle next to the executable so Bundle.module resolves
# the OneNote importer inside the app.
app: importer
	swift build -c $(CONFIG)
	rm -rf "$(APP)"
	mkdir -p "$(APP_MACOS)" "$(APP_RESOURCES)"
	cp "$(BIN_DIR)/Jotvella" "$(APP_MACOS)/Jotvella"
	cp -R "$(BIN_DIR)/$(RESOURCE_BUNDLE)" "$(APP_MACOS)/$(RESOURCE_BUNDLE)"
	cp Packaging/Info.plist "$(APP_CONTENTS)/Info.plist"
	iconutil -c icns "$(ICONSET)" -o "$(APP_RESOURCES)/JotvellaAppIcon.icns"
	printf 'APPL????' > "$(APP_CONTENTS)/PkgInfo"
	codesign --force --deep --sign - "$(APP)" 2>/dev/null || true
	@echo "Built $(APP)"

# Build the bundle and launch it in the foreground.
open: app
	open "$(APP)"

clean-app:
	rm -rf "$(APP)"

