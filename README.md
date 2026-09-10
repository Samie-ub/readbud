# ReadBud for macOS

ReadBud is a native SwiftUI document reader for macOS. It imports PDF, TXT, and Markdown files, reads them with an on-device Kokoro Core ML voice, highlights the active sentence, and saves reading progress.

ReadBud runs as a menu-bar utility. Drag a supported document or a public article URL to the black shelf at the top center of the screen to start listening, or use the menu-bar menu to open a document.

## Requirements

- macOS 15 or newer
- Xcode with Swift 6.2 support
- Internet access for the initial package and Kokoro model downloads

## Run

```bash
./scripts/run.sh
```

The script builds and launches an optimized local `.app` bundle without a background watcher. Use this for everyday reading. The first release build may take longer while dependencies compile.

The first Kokoro playback downloads the Core ML model once. Later launches reuse the model stored in your user Application Support directory.

For Xcode development, open `Package.swift`, select the `ReadBudMac` scheme, and press Run.

For automatic rebuild and relaunch while editing, use:

```bash
./scripts/dev.sh
```

The watcher rebuilds whenever a Swift source or package file changes, then replaces the app instance it launched. Stop it with `Control-C`.

## Using the Drop Shelf

1. Leave ReadBud running in the menu bar.
2. Drag a PDF, TXT, MD, Markdown file, or public article URL toward the top center of the screen.
3. Drop it on the expanded black shelf.
4. ReadBud imports the file or fetches the article and begins playback automatically.

URL imports try direct article extraction first. Pages requiring JavaScript fall back to a private WebKit view with Mozilla Readability. The renderer does not share Safari login sessions. Scanned PDFs require a text layer; OCR is not included.

### Cleanup and AI routing

**Automatic** is the default, including migration from the old cleanup toggles. Markdown and text use fast formatting cleanup without loading an LLM. Clean PDF/article text also stays local; short extractions with obvious debris may use Ollama.

Settings and the shelf gear menu offer four routes:

- **Automatic · local first**: use deterministic cleanup where sufficient.
- **Fast · no AI**: never invoke a cleanup model.
- **Local AI · Ollama**: explicitly request AI cleanup for the imported file or article.
- **Cloud AI · Gemini (articles)**: explicitly send extracted article text to Gemini; files stay local.

For Ollama, start the local service, open Settings, and refresh models. Select an installed local text model such as `llama3.2:latest`. Embedding and cloud models are excluded. There is no automatic cloud fallback.

AI has one total time budget (15 seconds by default, configurable to 30 or 60), covering discovery and all sections. **Read now** skips AI and starts listening to the complete basic-cleaned document. **Cancel import** keeps the previous document. Dropping a new source cancels the prior import.

A failed, timed-out, empty, or truncated AI response leaves the entire basic-cleaned document intact; partial AI rewrites are discarded. The shelf shows a notice and the optional developer panel records routing and timing. Source files are never changed. Re-import a document to apply new cleanup settings.

The developer panel is hidden by default; enable it from the shelf gear menu to inspect text and diagnostics.

## Build

```bash
swift build
swift test
```

An opt-in local provider smoke test is available with `READBUD_LIVE_OLLAMA=1 swift test --filter LiveCleanupTests`. It uses the installed `llama3.2:latest` model.

## Structure

```text
Sources/ReadBudMac/   SwiftUI application and local speech engines
Package.swift         Swift package definition
Package.resolved      Pinned package versions
doc.md                Development and troubleshooting guide
```

See [ARCHITECTURE.md](ARCHITECTURE.md) for component boundaries, resource limits, and validation.

All app runtime code is Swift. Kokoro inference runs in-process through Core ML; no Python environment is required. Optional AI import cleanup connects to the local Ollama service.

Mozilla Readability 0.6.0 is bundled under the Apache License 2.0; its license is included with the app resources.
