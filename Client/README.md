# SewnDemo

<p align="center">
  <img src="../README_Assets/1.png" alt="SewnDemo — Library and Search" width="720" />
</p>

A macOS demo app for [SewnMini](../README.md). Drag-and-drop or select files from your filesystem, embed them into the local vector index via the SewnMini server, then search across them with a semantic query — all from a single split-view window.

## Requirements

- macOS 14+
- SewnMini server running locally (see [setup](../README.md#build--run))

## Running

Open `Package.swift` in Xcode, select the **SewnDemo** scheme, and press Run. Or from the terminal:

```bash
cd SewnMini/Demo
swift run SewnDemo
```

The app connects to `http://127.0.0.1:8081` by default. Click the gear icon in the Library toolbar to change the server URL or owner ID.

## How it works

| Panel | What it does |
|---|---|
| **Library** (left) | Drop or pick files — txt, md, pdf, rtf, rtfd, json, csv, source code. Each file is extracted, sanitized, and sent to `POST /v1/batch/embeddings`. |
| **Search** (right) | Type a natural-language query and press Return. Results come back from `POST /v1/search` as ranked cards with a distance score. |

Text is cleaned by `TextSanitizer` before embedding: PDF ligatures, soft hyphens, end-of-line word splits, non-standard spaces, and stray control characters are all resolved first.
