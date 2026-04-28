# Gelato

Gelato is a native macOS meeting notes app that records your microphone and system audio, transcribes both sides of the conversation in real time, and turns completed sessions into searchable notes.

It is built with SwiftUI and Swift Package Manager. Local transcription is powered by FluidAudio, while optional OpenAI integration can clean up transcripts, generate meeting notes, create short titles, and answer questions about past sessions.

## Features

- Real-time dual-channel transcription for mic audio ("You") and system audio ("Them")
- Local speech recognition with FluidAudio / Parakeet-TDT v2
- Session library with editable titles, transcripts, generated notes, and audio artifacts
- Combined audio export generated after each recording when source audio is available
- Optional OpenAI transcript cleanup and detailed note generation
- Meeting Q&A chat for completed sessions when an OpenAI API key is configured
- Automatic microphone selection with manual device override
- Optional macOS screen sharing and screenshot protection
- Sparkle update support for app bundle builds

## Requirements

- macOS 15 or newer
- Xcode command line tools with Swift 6
- Microphone permission
- Screen and system audio recording permissions for capturing meeting audio
- Internet access on first transcription run so FluidAudio can download its models
- Optional: an OpenAI API key for transcript cleanup, notes, titles, and meeting Q&A

## Quick Start

Clone the repository and build the Swift package:

```sh
git clone git@github.com:changbenjamin/Gelato.git
cd Gelato/Gelato
swift build
swift run Gelato
```

The first transcription run downloads the FluidAudio ASR model, which is roughly 600 MB.

## OpenAI Configuration

OpenAI is optional, but several post-processing features depend on it. Create a `.env` file in one of the locations Gelato checks:

- Repository root: `.env`
- Swift package directory: `Gelato/.env`
- App support path: `~/Library/Application Support/Gelato/.env`
- Home fallback: `~/.gelato.env`

Add:

```sh
OPENAI_API_KEY=your_api_key_here
```

If you are running the packaged app from `/Applications`, the build script can sync the repository `.env` file into `~/Library/Application Support/Gelato/.env`. Relaunch Gelato after changing environment values.

## Build the macOS App

From the repository root:

```sh
./scripts/build_swift_app.sh
```

The script:

- Builds the release Swift executable
- Creates `dist/Gelato.app`
- Embeds Sparkle when available from SwiftPM artifacts
- Signs the app when a suitable signing identity is available
- Installs the app into `/Applications/Gelato.app`
- Relaunches Gelato

To create a DMG after building the app:

```sh
./scripts/make_dmg.sh
```

The DMG script writes `dist/Gelato.dmg`, signs it when a signing identity is available, and notarizes it when the following environment variables are set:

```sh
APPLE_ID=name@example.com
APPLE_TEAM_ID=TEAMID123
APPLE_APP_PASSWORD=xxxx-xxxx-xxxx-xxxx
```

## Development

Useful commands:

```sh
cd Gelato
swift build
swift run Gelato
swift package resolve
```

The app currently logs diagnostics to:

```sh
/tmp/opengranola.log
```

## How Sessions Work

When you start a new note, Gelato captures microphone audio and system audio separately, streams both through local transcription, and labels utterances as "You" or "Them". When you stop the session, Gelato finalizes the transcript, creates combined audio when possible, writes session metadata, and optionally runs OpenAI-powered cleanup and note generation.

Completed sessions appear in the sidebar. Each session can show generated notes, the full transcript, and a chat view for asking questions about the meeting.

## Privacy Notes

Core transcription runs locally through FluidAudio. Audio capture, transcripts, notes, and metadata are stored on your Mac. If `OPENAI_API_KEY` is configured and OpenAI-backed features are enabled, transcript content is sent to OpenAI for cleanup, note generation, title generation, and meeting Q&A.

Gelato also includes an opt-in setting to hide app windows from screen sharing and screenshots using macOS window capture protection.

## Project Structure

```text
Gelato/
  Package.swift
  Sources/Gelato/
    App/              App entry point
    Audio/            Microphone and system audio capture
    Models/           Session, transcript, and chat models
    Settings/         App settings and .env loading
    Storage/          Session library, audio, metadata, and transcripts
    Transcription/    Local transcription and OpenAI services
    Views/            SwiftUI interface
scripts/
  build_swift_app.sh  Build, bundle, sign, install, and relaunch the app
  make_dmg.sh         Create, sign, and optionally notarize a DMG
```

## License

Gelato is released under the MIT License. See [LICENSE](LICENSE) for details.
