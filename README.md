# Jotvella

A personal knowledge-base / note-taking app for **macOS** (iOS planned). Notes, at home.

Jotvella organizes your thinking into a familiar hierarchy — notebook → section group → section → page — on a free-canvas, "type anywhere" page model. It is a clean-room design built from scratch using public Apple frameworks and the openly published Microsoft OneNote file-format specifications. **No code, assets, or UI are copied from any existing product.**

**[Website & download →](https://ahmadfaridabbas.github.io/jotvella/)**

macOS 13+ · Apple Silicon + Intel

---

## Features

- Hierarchical notebooks (notebook → section group → section → page)
- Free-canvas, block-based "type anywhere" pages
- Rich text, tables, images, attachments, drawings (ink), tags, inter-page links
- Per-section AES-256 encryption with Touch ID / passcode unlock
- Local-first storage with optional iCloud sync
- OneNote interoperability (read `.one` / `.onetoc2` / `.onepkg`) via public specs
- Fast full-text search with background indexing

## Tech stack

| Layer | Technology |
|---|---|
| UI | SwiftUI + AppKit where needed |
| Persistence / index | SwiftData / Core Data over SQLite |
| Document format | File package via `FileWrapper` (source of truth) |
| Rich text / rendering | TextKit 2 / WebKit; PDFKit; CoreGraphics |
| Drawing / ink | PencilKit |
| Encryption | CryptoKit (AES-256-GCM) |
| Auth | LocalAuthentication (Touch ID / passcode) |
| Cloud sync | CloudKit (iCloud) |
| Search | Background indexer + CoreSpotlight |
| OCR / NLP | Vision + NaturalLanguage |

## Building

Requires Xcode / Swift toolchain (Swift 5.9+) and, to rebuild the OneNote importer, a Rust toolchain.

```sh
# Build and run via SwiftPM
make run

# Assemble a double-clickable Jotvella.app
make app
open Jotvella.app
```

`swift build` alone bundles the prebuilt Rust OneNote importer committed at
`Sources/Jotvella/Resources/jotvella-one-importer`. Run `make importer` to rebuild
it from `Tools/OneNoteImporter`.

## Download

Grab the latest built `Jotvella.app` from the [Releases](https://github.com/ahmadfaridabbas/jotvella/releases) page.

> This build is locally signed and not Apple-notarized. macOS may ask you to approve it in **System Settings → Privacy & Security**.

## Project layout

```
Sources/Jotvella/        Swift app source (SwiftUI)
Tools/OneNoteImporter/   Rust OneNote importer (uses onenote.rs, MPL-2.0)
Packaging/Info.plist     App bundle metadata
Assets/                  App icon (iconset + 1024px PNG)
Makefile                 Build orchestration
docs/                    GitHub Pages website
```

## Third-party

The OneNote importer vendors [onenote.rs](https://github.com/msiemens/onenote.rs)
under the MPL-2.0 license. See [`ThirdPartyLicenses/`](ThirdPartyLicenses/).

## License

See repository for license details.

---

*Jotvella is a clean-room design reference and implementation. The name and
`.jotpkg` / `.jottoc` / `.jotdoc` extensions are provisional.*
