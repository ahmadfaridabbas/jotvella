# OneNote section importer

The small `jotvella-one-importer` executable reads desktop `.one` section files and emits page text, tables, and embedded images as JSON for the Swift app to store in a Jotvella notebook.

Build it for Apple Silicon with Rust 1.85 or newer. From the repository root the
`Makefile` builds the helper and refreshes the copy bundled as an app resource,
then `swift build` picks it up:

```sh
make importer        # rebuild only the Rust helper + refresh Resources/
make build           # make importer, then swift build
```

`swift build` on its own does not rebuild this helper — it only bundles the
binary already present at `Sources/Jotvella/Resources/jotvella-one-importer`, so
run `make importer` after changing anything under `Tools/OneNoteImporter/src`.

The equivalent manual steps:

```sh
cargo build --release --manifest-path Tools/OneNoteImporter/Cargo.toml
cp Tools/OneNoteImporter/target/release/jotvella-one-importer Sources/Jotvella/Resources/
```

The parser dependency is `onenote_parser` from [onenote.rs](https://github.com/msiemens/onenote.rs), licensed under MPL-2.0. Its license is in `ThirdPartyLicenses/onenote.rs-MPL-2.0.txt`.
