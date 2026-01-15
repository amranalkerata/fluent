# Fluent

**Open-source voice dictation for macOS**

![macOS 14+](https://img.shields.io/badge/macOS-14.0%2B-blue)
![Swift 5.9+](https://img.shields.io/badge/Swift-5.9%2B-orange)
![License](https://img.shields.io/badge/license-MIT-green)

Fluent is a lightweight, native macOS app that turns your voice into text instantly. Press a hotkey, speak, and your words are transcribed and pasted wherever your cursor is. Powered by OpenAI's Whisper for accurate transcription and optional GPT-4 enhancement for polished output.

## Features

- **Global Hotkeys** — Start recording from anywhere with `Fn` or `Option+Space`
- **AI Transcription** — Accurate speech-to-text using OpenAI Whisper
- **Smart Enhancement** — Optional GPT-4 mini post-processing for punctuation and clarity
- **Auto-Paste** — Transcribed text automatically pastes at your cursor
- **Recording History** — Searchable history of all your transcriptions
- **Visual Feedback** — Floating overlay with real-time waveform visualization
- **Menu Bar App** — Runs quietly in your menu bar
- **Customizable Shortcuts** — Configure hotkeys to fit your workflow
- **Multi-Language Support** — Transcribe in 12+ languages

## System Requirements

- **macOS 14.0** (Sonoma) or later
- **OpenAI API Key** — Required for transcription ([Get one here](https://platform.openai.com/api-keys))
- **Microphone Permission** — For voice recording
- **Input Monitoring Permission** — For global keyboard shortcuts

## Installation

### Download

1. Download the latest release from the [Releases](../../releases) page
2. Unzip and drag **Fluent.app** to your Applications folder
3. Launch Fluent from Applications

### Build from Source

```bash
# Clone the repository
git clone https://github.com/yourusername/fluent.git
cd fluent

# Open in Xcode
open Fluent.xcodeproj

# Build and run (⌘R)
```

**Requirements:** Xcode 15.0+ with macOS 14.0 SDK

## Setup

### 1. Grant Permissions

On first launch, Fluent will request the following permissions:

| Permission | Purpose | How to Grant |
|------------|---------|--------------|
| **Microphone** | Record your voice | Click "Allow" when prompted |
| **Input Monitoring** | Detect global hotkeys | System Settings → Privacy & Security → Input Monitoring → Enable Fluent |
| **Accessibility** (Optional) | Enhanced paste functionality | System Settings → Privacy & Security → Accessibility → Enable Fluent |

### 2. Add Your OpenAI API Key

1. Get an API key from [OpenAI Platform](https://platform.openai.com/api-keys)
2. Open Fluent and go to **Settings**
3. Paste your API key in the "OpenAI API Key" field
4. Click **Save** — the key is validated and stored securely in your macOS Keychain

> Your API key never leaves your device except for API calls to OpenAI.

## Usage

### Recording

| Action | Default Shortcut |
|--------|-----------------|
| Start/Stop Recording | `Fn` (hold) or `Option + Space` |
| Cancel Recording | `Escape` |
| Open Fluent Window | `Option + Shift + F` |

**Workflow:**
1. Place your cursor where you want the text
2. Press and hold the hotkey
3. Speak clearly
4. Release the hotkey
5. Text is transcribed and pasted automatically

### Customizing Shortcuts

1. Open Fluent → **Shortcuts** tab
2. Click on any shortcut to edit
3. Press your desired key combination
4. Changes are saved automatically

### Settings

| Setting | Description |
|---------|-------------|
| **Language** | Transcription language (or auto-detect) |
| **GPT Enhancement** | Enable AI-powered text cleanup |
| **Auto-Paste** | Automatically paste transcribed text |
| **Audio Quality** | Low / Medium / High recording quality |
| **Launch at Login** | Start Fluent when you log in |

### Recording History

- View all past recordings in the **History** tab
- Search by transcription text
- See recording duration, timestamp, and target app
- Compare original vs. enhanced transcriptions

## Technical Details

### Architecture

```
Fluent/
├── App/              # Application core (AppState, AppDelegate)
├── Models/           # Data models (Recording, Settings, Shortcuts)
├── Services/         # Business logic
│   ├── Audio/        # Recording service
│   ├── Transcription/# Whisper & GPT services
│   ├── Hotkey/       # Global shortcut handling
│   ├── Storage/      # Keychain, SwiftData, Settings
│   └── System/       # Paste, Permissions
├── Views/            # SwiftUI interface
└── Theme/            # Design system components
```

### Technologies

- **SwiftUI** — Native macOS interface
- **SwiftData** — Local recording history storage
- **AVFoundation** — Audio recording
- **CGEvent** — Global keyboard event monitoring
- **OpenAI Whisper API** — Speech-to-text transcription
- **OpenAI GPT-4 mini** — Text enhancement

### Audio Specifications

| Quality | Sample Rate | Bit Rate | Format |
|---------|-------------|----------|--------|
| Low | 16 kHz | 64 kbps | M4A (AAC) |
| Medium | 22 kHz | 128 kbps | M4A (AAC) |
| High | 44.1 kHz | 192 kbps | M4A (AAC) |

### Data Storage

| Data | Location |
|------|----------|
| Recordings database | SwiftData (app container) |
| Audio files | `~/Documents/Fluent/` |
| API key | macOS Keychain |
| Settings | UserDefaults |

## Privacy & Security

- **API Key Security** — Stored in macOS Keychain, never in plain text
- **Local Processing** — Audio files and history stay on your device
- **No Analytics** — No tracking, telemetry, or data collection
- **No Cloud Sync** — All data remains local to your Mac
- **Minimal Permissions** — Only requests what's necessary

## Troubleshooting

### Hotkeys not working

1. Open **System Settings → Privacy & Security → Input Monitoring**
2. Ensure Fluent is listed and enabled
3. Try removing and re-adding Fluent if issues persist
4. Restart Fluent after granting permissions

### Transcription fails

1. Check your API key is valid in **Settings**
2. Verify your OpenAI account has available credits
3. Ensure you have an internet connection
4. Check the audio file was recorded (visible in History)

### Recording not starting

1. Open **System Settings → Privacy & Security → Microphone**
2. Ensure Fluent has microphone access
3. Check that no other app is using the microphone exclusively

### Text not pasting

1. Grant **Accessibility** permission for enhanced paste functionality
2. Ensure the target app accepts text input
3. Try clicking in the text field before recording

## Supported Languages

Fluent supports transcription in:

- English
- Spanish
- French
- German
- Italian
- Portuguese
- Dutch
- Russian
- Chinese
- Japanese
- Korean
- Arabic
- Auto-detect

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## License

This project is licensed under the MIT License — see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- [OpenAI](https://openai.com) for Whisper and GPT APIs
- Built with SwiftUI and SwiftData

---

**Made with ❤️ for the macOS community**
