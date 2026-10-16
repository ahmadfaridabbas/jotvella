# Jotvella — Architecture & Design Reference

> **Working product name:** Jotvella. The name and `.jotpkg` / `.jottoc` / `.jotdoc` extensions are provisional pending domain and trademark clearance.

A personal knowledge-base / note-taking app for macOS & iOS.
Clean-room design: built from scratch using public Apple frameworks and public
Microsoft OneNote file-format specifications. **No code, assets, or UI are copied
from any existing product.** The structure below is a target design derived from
publicly observable metadata and open specifications, used only as a feature and
data-model reference.

---

## 1. Goals

- Hierarchical notebooks (notebook → section group → section → page).
- Free-canvas, "type anywhere" page content (block-based, not a linear document).
- Rich text, tables, images, attachments, drawings (ink), tags, inter-page links.
- Per-section AES-256 encryption with Touch ID / passcode unlock.
- Local-first storage with optional cloud sync (iCloud; optionally Dropbox/WebDAV).
- OneNote interoperability (read/write `.one`, `.onetoc2`, `.onepkg`) via public specs.
- Fast full-text search (background indexing).

---

## 2. Target Tech Stack (Apple public frameworks)

| Layer | Technology |
|---|---|
| UI | SwiftUI (primary) + AppKit/UIKit where needed |
| Persistence / index | SwiftData or Core Data over SQLite |
| Document format | File package via `FileWrapper` (source of truth); DB is a cache/index |
| Rich text / rendering | TextKit 2 or WebKit-based editor; PDFKit; Quartz/CoreGraphics |
| Drawing / ink | PencilKit |
| Encryption | CryptoKit (AES-256-GCM) |
| Auth | LocalAuthentication (Touch ID / passcode) |
| Cloud sync | CloudKit (iCloud); optional Dropbox / WebDAV providers |
| Search | Background indexer + CoreSpotlight; dedicated XPC/helper for heavy indexing |
| OCR / NLP | Vision + NaturalLanguage (searchable images/handwriting) |

Design note: keep the **file package as the source of truth** and treat the
database purely as a rebuildable cache/search index keyed by `pathRoot` +
`relativePath`. This makes sync, backup, and portability straightforward.

---

## 3. Document Formats

Native file-package format (a bundle/folder, not a monolithic DB):

| Extension | Role | Meaning |
|---|---|---|
| `.jotpkg` | Package | The whole notebook (bundle containing sections + resources) |
| `.jottoc` | Table of Contents | Notebook hierarchy / ordering index |
| `.jotdoc` | Section | A single section with its pages |

Interop (import/export) via public Microsoft specs:

- `.one`, `.onetoc2`, `.onepkg` — OneNote formats.
- Specs: `[MS-ONE]` OneNote File Format and `[MS-ONESTORE]` Revision Store
  (openly published by Microsoft; no reverse engineering required).

---

## 4. Data Model

The persistent store is a **cache/search index** over the file packages. Every
entity carries `pathRoot` + `relativePath` so any row can be traced back to its
file-package origin, and the index can be fully rebuilt from disk.

### Hierarchy

```
Notebook (storageType, notebookFormat, localPath, externalPath, syncState, isReadonly)
  └─ SectionGroup   (nestable: parentSectionGroup → self; colorHex)
       └─ Section   (name, colorHex, iconName, encrypted, orderInParent,
       │            hasFile, pageListSortBy, pageListSortAsc)
       │    └─ Page (name, level, index, dateCreated, dateLastModified,
       │            authorOriginal, authorMostRecent, objectGuid, colorHex,
       │            systemPage)
       │         ├─ ContentObject  (objectType, plainText, structuredText)
       │         └─ Tag            (tagLabel, tagShapeIndex)
       └─ Hyperlink  (pageFromId → pageToId, metadata)   // inter-page / wiki links
```

### Entities & key fields

**Notebook**
- `storageType` — local / iCloud / external provider
- `notebookFormat` — native vs OneNote (and version)
- `localPathRoot`, `localPathRelative`, `externalPath`
- `syncState`, `lastSynced`, `lastSyncError`, `isReadonly`, `orderNum`, `username`

**SectionGroup** (recursively nestable)
- `parentSectionGroup` (self relationship)
- `colorHex`, `pathRoot`, `relativePath`, `lastModified`, `childsCached`

**Section**
- `name`, `colorHex`, `iconName`
- `encrypted` (per-section AES-256)
- `orderInParent`, `hasFile`, `childsCached`
- `pageListSortBy`, `pageListSortAsc`
- `pathRoot`, `relativePath`, `objectGuid`, `lastModified`, `metadata`

**Page**
- `name`, `level`, `index` (ordering within section)
- `dateCreated`, `dateLastModified`
- `authorOriginal`, `authorMostRecent`
- `objectGuid`, `colorHex`, `systemPage`, `contentIndexed`
- `pathRoot`, `relativePath`

**ContentObject** (one row per block on a page — the "type anywhere" model)
- `objectType` — text / image / table / drawing / attachment / etc.
- `plainText` — flattened text for search
- `structuredText` — rich formatting payload
- `objectIdStr`, position/geometry metadata, `pagePathRoot`, `pageRelativePath`

**Tag**
- `tagLabel`, `tagShapeIndex`, bound to a page via `pagePathRoot` + `pageRelativePath`

**Hyperlink** (page-to-page link graph)
- `pageFromId`, `pageToId`, `metadata`

### Design principles

- **GUID-based identity** (`objectGuid` / `objectIdStr`) so items survive renames and sync.
- **Block/positioned content** per page (free canvas), not a linear text stream.
- **Per-section encryption** flag; encrypted sections unlock via LocalAuthentication.
- **Separate hyperlink graph** powers wiki-style inter-page linking.
- **Index is disposable**: rebuildable from the authoritative file packages.

---

## 5. Feature Difficulty Map

| Feature | Difficulty | Approach |
|---|---|---|
| Notebooks / sections / pages hierarchy | Moderate | SwiftData model + file-package I/O |
| Rich-text editor + tables | Moderate | TextKit 2 or WebKit editor |
| Images / attachments / drawings | Low–Moderate | PencilKit, ImageIO, PDFKit |
| Tags, inter-page links, search | Moderate | Index tables + CoreSpotlight |
| AES-256 per-section encryption | Low | CryptoKit + LocalAuthentication |
| iCloud sync | Moderate | CloudKit mirroring of file packages |
| OneNote `.one` read/write | **Hard** | Implement from `[MS-ONE]` / `[MS-ONESTORE]` specs |

---

## 6. Suggested Build Order (MVP → full)

1. **MVP:** Notebook → Section → Page model, file-package document, basic rich-text editor, local storage.
2. SwiftData index + full-text search.
3. Section groups (nesting), tags, inter-page links.
4. Per-section encryption + Touch ID.
5. iCloud (CloudKit) sync.
6. Images, attachments, PencilKit drawings, tables.
7. OneNote import, then export (the long pole).

---

## 7. References

- `[MS-ONE]` OneNote File Format — https://learn.microsoft.com/en-us/openspecs/office_file_formats/ms-one/
- `[MS-ONESTORE]` OneNote Revision Store File Format — https://learn.microsoft.com/en-us/openspecs/office_file_formats/ms-onestore/
- Apple: SwiftData, SwiftUI, CloudKit, CryptoKit, LocalAuthentication, PencilKit, TextKit, PDFKit, Vision, NaturalLanguage.

---

*This document is a clean-room design reference. Build Jotvella from original code
using the public frameworks and open specifications listed above.*
