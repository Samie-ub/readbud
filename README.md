# ReadBud for macOS

ReadBud is a native SwiftUI reader that turns documents and web articles into a focused listening experience. Drop in a PDF, text file, Markdown file, or public article URL; ReadBud extracts the readable text, speaks it with a macOS system voice, highlights the active sentence, and remembers your progress.

![ReadBud importing and reading a web article](assets/readbud-demo.gif)

## Features

- A compact menu-bar app with a top-center drop shelf that follows you across macOS Spaces
- PDF, TXT, Markdown, and public web article imports
- Built-in macOS voices with selectable voice and playback speeds from 0.75× to 2×
- Sentence highlighting, click-to-seek, skip controls, and saved reading progress
- Direct web extraction with a private WebKit and Mozilla Readability fallback for JavaScript-rendered pages
- Local-first text cleanup, with optional Ollama and Gemini cleanup routes
- Cancelable imports, configurable AI time limits, and a **Read now** option that skips AI
- An optional developer panel for inspecting import routing, timing, and cleaned text

## Requirements

- macOS 15 or newer
- Xcode with Swift 6.2 support

ReadBud uses voices installed in macOS and does not download a speech model. Ollama and Gemini are optional and only needed when you explicitly choose their cleanup routes.

## Run

Clone the repository, then launch an optimized local app bundle:

```bash
./scripts/run.sh
```

The first release build may take a little longer. ReadBud appears in the menu bar rather than opening a permanent app window.

You can also open `Package.swift` in Xcode, select the `ReadBudMac` scheme, and press Run.

For automatic rebuild and relaunch while editing, use:

```bash
./scripts/dev.sh
```

Stop the watcher with `Control-C`.

## Usage

1. Leave ReadBud running in the menu bar.
2. Drag a PDF, TXT, MD, Markdown file, or public article URL toward the top center of the screen.
3. Drop it on the expanded shelf.
4. Use the shelf or menu-bar controls to play, pause, skip, change speed, or select a voice.

URL imports try direct article extraction first. Pages that require JavaScript fall back to a private WebKit view with Mozilla Readability. The renderer does not share Safari login sessions. Scanned PDFs must already contain a text layer; OCR is not included.

## Cleanup modes

**Automatic · local first** is the default. Markdown and text files use fast formatting cleanup without loading an AI model. Clean PDF and article text also stays on the deterministic path, while short extractions with obvious debris may use Ollama when it is available.

The shelf gear menu and Settings provide four routes:

- **Automatic · local first** — use deterministic cleanup whenever it is sufficient.
- **Fast · no AI** — never invoke a cleanup model.
- **Local AI · Ollama** — explicitly request local AI cleanup for an imported file or article.
- **Cloud AI · Gemini (articles)** — explicitly send extracted article text to Gemini; local files are not sent to Gemini.

For Ollama, start the local service and refresh the model list in Settings. Select an installed text model such as `llama3.2:latest`; embedding and cloud models are excluded. ReadBud never falls back to a cloud provider automatically.

AI cleanup has one total time budget—15 seconds by default, configurable to 30 or 60 seconds. A failed, timed-out, empty, or truncated response leaves the complete basic-cleaned document intact; partial rewrites are discarded. **Read now** skips AI, and **Cancel import** keeps the previous document.

## Privacy

- Source files are read locally and are never modified.
- Document playback uses the selected macOS system voice.
- Ollama cleanup stays on the local Ollama service.
- Gemini receives extracted article text only when **Cloud AI** is explicitly selected.
- The private article renderer does not use your Safari cookies or signed-in sessions.

## Build and test

```bash
swift build
swift test
```

An opt-in provider smoke test is available when Ollama and `llama3.2:latest` are installed:

```bash
READBUD_LIVE_OLLAMA=1 swift test --filter LiveCleanupTests
```

## Project structure

```text
Sources/ReadBudMac/    SwiftUI application, import pipeline, and speech playback
Tests/ReadBudMacTests/ Unit and integration tests
assets/                README media
scripts/               Build, launch, and development helpers
Package.swift          Swift package definition
ARCHITECTURE.md        Component boundaries and resource limits
doc.md                 Development and troubleshooting guide
```

All runtime code is Swift. See [ARCHITECTURE.md](ARCHITECTURE.md) for implementation details.

Mozilla Readability 0.6.0 is bundled under the Apache License 2.0; its license is included with the app resources.

## License

ReadBud is open source under the [MIT License](LICENSE).
