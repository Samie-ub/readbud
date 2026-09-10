# ReadBud macOS Development Guide

## Overview

ReadBud is a native SwiftUI macOS menu-bar application built with Swift Package Manager. Kokoro speech synthesis runs directly inside the app using Core ML. Development and playback do not require Python or a virtual environment. Optional local AI cleanup uses Ollama; ordinary imports do not require a server.

## Requirements

- macOS 15 or newer
- Xcode with Swift 6.2 support
- Internet access while resolving packages and downloading the Kokoro model for the first time
- An Apple Silicon Mac is recommended for fast neural speech generation

Check the installed toolchain:

```bash
swift --version
xcode-select -p
```

## First Setup

From the repository root, resolve dependencies and build the app:

```bash
swift package resolve
swift build
```

Swift Package Manager downloads the `kokoro-coreml` dependency and records the selected version in `Package.resolved`.

## Run from Terminal

```bash
./scripts/dev.sh
```

The script packages the SwiftPM executable into a local `.app` bundle before launch so development behavior matches a normal macOS app launch.

Stop the development process with `Control-C`.

ReadBud does not open a dashboard at launch. It adds a menu-bar item and a small black drop shelf at the top center of the current display. The shelf is the primary interaction surface.

The first time Kokoro is used, ReadBud downloads its Core ML model. The Play button may show `Preparing neural voice…` during this one-time download and initial model warm-up. The model is cached in the current user's Application Support directory and is reused on later launches.

## Run from Xcode

1. Open Xcode.
2. Select **File > Open** and choose `Package.swift` from this repository.
3. Wait for package resolution to finish.
4. Select the `ReadBudMac` scheme and **My Mac** destination.
5. Press `Command-R` to run.

Use `Command-B` to build without launching. Xcode breakpoints can be placed directly in files under `Sources/ReadBudMac`.

## Development Workflow

For an automatic rebuild-and-relaunch loop, close any separately launched ReadBud instance and run:

```bash
./scripts/dev.sh
```

The script watches Swift source and package files using a native filesystem-event helper; it does not poll in the background. After each save, it rebuilds and relaunches ReadBud; if compilation fails, it keeps watching so the next save can recover. This is process-level live reload, so in-memory UI state resets on each successful rebuild.

After changing Swift code, verify it with:

```bash
swift build
```

Run the app for behavior that requires the macOS interface, audio output, document import, or Core ML inference:

```bash
./scripts/dev.sh
```

To test the primary workflow, drag a PDF, TXT, MD, Markdown file, or public article URL toward the top center of the display. The shelf expands as the drag approaches. Dropping the source imports it and starts playback. The shelf joins all macOS Spaces and remains available while the app is running.

The shelf gear menu controls the optional developer panel and the cleanup route. Automatic mode keeps Markdown/text imports on the fast local path. AI has a configurable total deadline and can be skipped with Read now. See README.md for routing choices and ARCHITECTURE.md for implementation boundaries.

Clean generated Swift build artifacts only when dependency or compiler caches appear stale:

```bash
swift package clean
swift build
```

## Project Structure

```text
Sources/ReadBudMac/
├── ReadBudApp.swift            Application entry point
├── AppCoordinator.swift        Menu-bar lifecycle and import actions
├── DropShelf.swift             Top-center drop target and playback shelf
├── DeveloperToolPanel.swift    Right-side import trace and content inspector
├── ReaderModel.swift           UI state and cancelable import/playback lifecycle
├── ImportPipeline.swift        Extraction, cleanup routing, deadlines, segmentation
├── ReadingTextCleaner.swift    Deterministic formatting cleanup
├── OllamaCleanupClient.swift   Bounded local AI requests
├── WebArticleImporter.swift    Direct extraction, optional WebKit fallback
├── GeminiCleanupClient.swift   Optional post-extraction article cleanup
├── KeychainStore.swift         Gemini API key storage
├── KokoroSpeechEngine.swift    In-process Kokoro Core ML synthesis
├── SystemSpeechEngine.swift    Apple speech fallback
├── SpeechEngine.swift          Shared speech engine contract
├── DocumentImporter.swift      PDF, text, and Markdown import
├── TextSegmenter.swift         Sentence extraction
├── ReaderStore.swift           Reading progress persistence
├── Models.swift                Reader and voice models
└── SettingsView.swift          Voice and speed settings

Package.swift                   Package definition and dependencies
Package.resolved                Resolved dependency versions
```

## How Kokoro Playback Works

1. `ReaderModel` requests only the current sentence (at most 600 characters).
2. `KokoroSpeechEngine` delegates synthesis to a serial worker actor. The model downloads on first use if missing.
3. Preparation completes off the main actor. Canceled or superseded requests cannot start playback.
4. Float PCM samples play through `AVAudioEngine`; there is no speculative prefetch queue.
5. The audio engine stops/pauses when idle, and the worker releases its model after 30 idle seconds.

An in-flight Core ML call cannot be preempted by Swift cancellation; its result is discarded after return. The worker prevents another synthesis call from running concurrently.

If Kokoro cannot initialize or synthesize audio, the reader switches to the Apple system speech engine.

## Window Lifecycle

- The app uses accessory activation, so it can remain available without a permanent Dock icon.
- The top shelf is a non-activating `NSPanel`, allowing file drops, public article URL drops, playback control, and import actions without opening another window.
- The menu-bar menu still offers document import and settings, but the reader itself lives in the shelf.

## Troubleshooting

### Package resolution fails

Confirm internet access and retry:

```bash
swift package resolve
swift build
```

### The first playback takes time

This is expected while the Kokoro model downloads and Core ML warms up. It should not download again after a successful first run. Later starts can still include a short model-loading delay.

### Every playback downloads the model

Check that the app can write to the current user's Application Support directory and that no cleanup utility is deleting application caches between runs.

### Kokoro playback falls back to Apple speech

Run the app from Xcode and inspect the debug console for the underlying Core ML error. Also confirm the Mac is running macOS 15 or newer.

### Audio does not play

Check the current macOS output device and volume. Then stop and restart playback. If the issue persists, relaunch the app from Xcode and inspect AVAudioEngine errors in the debug console.

## Generated Files

The following are local build artifacts and should not be committed:

```text
.build/
.swiftpm/
.DS_Store
```
