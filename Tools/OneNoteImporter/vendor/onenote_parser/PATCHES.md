# Local recovery patch

This vendored crate is `onenote_parser` 2.0.0, distributed under MPL-2.0 (see `ThirdPartyLicenses/onenote.rs-MPL-2.0.txt`).

Jotvella's importer applies a narrow recovery patch for OneNote section files that contain malformed or stale embedded attachment references. The upstream parser treated these references as fatal errors and rejected the entire section. The local changes skip unreadable attachment reference nodes and represent missing attachment blobs as empty/missing file data, allowing readable pages and text to import. A warning is emitted for each skipped reference so the app can report affected sections. Page content is preserved; the affected embedded attachment itself may be unavailable.

The changes are in `src/onestore/desktop/file_node/mod.rs`, `src/onestore/desktop/objects/file_data_store.rs`, and `src/onestore/desktop/objects/parse_context.rs`.
