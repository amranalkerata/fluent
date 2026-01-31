# Fluent

**Open-source voice dictation for macOS**

![macOS 14+](https://img.shields.io/badge/macOS-14.0%2B-blue)
![Swift 5.9+](https://img.shields.io/badge/Swift-5.9%2B-orange)
![License](https://img.shields.io/badge/license-MIT-green)

Fluent is a lightweight, native macOS app that turns your voice into text instantly. Press a hotkey, speak, and your words are transcribed and pasted wherever your cursor is. Powered by WhisperKit for accurate on-device transcription with local AI formatting for polished output — no cloud services required.

## Features

- **100% Local Processing** — All transcription happens on your device, no cloud services required
- **Global Hotkeys** — Start recording from anywhere with `Fn` or `Option+Space`
- **AI Transcription** — Accurate speech-to-text using WhisperKit (on-device)
- **Smart Formatting** — Local AI adds punctuation and proper capitalization
- **Privacy-First** — Your voice never leaves your Mac
- **Auto-Paste** — Transcribed text automatically pastes at your cursor
- **Recording History** — Searchable history of all your transcriptions
- **Visual Feedback** — Floating overlay with real-time waveform visualization
- **Menu Bar App** — Runs quietly in your menu bar
- **Customizable Shortcuts** — Configure hotkeys to fit your workflow
- **Multi-Language Support** — Transcribe in 12+ languages

## System Requirements

- **macOS 14.0** (Sonoma) or later
- **Apple Silicon or Intel Mac** — Core ML optimized for best performance
- **~350 MB disk space** — For AI models (downloaded during setup)
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

### 2. Download AI Models

During the onboarding process, Fluent will download the required AI models:

1. **Welcome** — Introduction to Fluent
2. **Permissions** — Grant microphone and input monitoring access
3. **Model Download** — WhisperKit transcription model (~350 MB) downloads automatically
4. **Ready** — You're all set to start dictating

> Models are downloaded once and stored locally. No internet connection is required after initial setup.

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
| **Text Formatting** | Enable AI-powered punctuation and capitalization |
| **List Formatting** | Format spoken lists as bullet points |
| **Auto-Paste** | Automatically paste transcribed text |
| **Audio Quality** | Low / Medium / High recording quality |
| **Launch at Login** | Start Fluent when you log in |

### Recording History

- View all past recordings in the **History** tab
- Search by transcription text
- See recording duration, timestamp, and target app
- Compare original vs. formatted transcriptions

## Technical Details

### Architecture

```
Fluent/
├── App/              # Application core (AppState, AppDelegate)
├── Models/           # Data models (Recording, Settings, Shortcuts)
├── Services/         # Business logic
│   ├── Audio/        # Recording & AudioConverter
│   ├── Transcription/# WhisperKit & Punctuation services
│   ├── Model/        # ModelManager, PunctuationModelManager
│   ├── Hotkey/       # Global shortcut handling
│   ├── Storage/      # SwiftData, Settings
│   └── System/       # Paste, Permissions
├── Views/            # SwiftUI interface
└── Theme/            # Design system components
```

### Technologies

- **SwiftUI** — Native macOS interface
- **SwiftData** — Local recording history storage
- **AVFoundation** — Audio recording
- **CGEvent** — Global keyboard event monitoring
- **WhisperKit** — On-device speech-to-text (Core ML)
- **ONNX Runtime** — Local punctuation model inference
- **SentencePiece** — Text tokenization for punctuation model

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
| WhisperKit models | `~/Library/Application Support/Fluent/WhisperKitModels/` |
| Punctuation model | `~/Library/Application Support/Fluent/PunctuationModel/` |
| Settings | UserDefaults |

## Privacy & Security

- **100% Local Processing** — All transcription and formatting happens on your device
- **No Internet Required** — After initial model download, works completely offline
- **No Cloud Services** — Your voice data never leaves your Mac
- **No Analytics** — No tracking, telemetry, or data collection
- **No Account Required** — No sign-up, no API keys, no subscriptions
- **Minimal Permissions** — Only requests what's necessary

## Troubleshooting

### Hotkeys not working

1. Open **System Settings → Privacy & Security → Input Monitoring**
2. Ensure Fluent is listed and enabled
3. Try removing and re-adding Fluent if issues persist
4. Restart Fluent after granting permissions

### Transcription model not loading

1. Check that models exist in `~/Library/Application Support/Fluent/WhisperKitModels/`
2. Delete the models folder and restart Fluent to re-download
3. Ensure you have at least 500 MB of free disk space
4. Check your internet connection during initial model download

### Model download fails

1. Verify you have an active internet connection
2. Check available disk space (~350 MB required)
3. Try restarting Fluent to resume the download
4. Check Console.app for detailed error messages

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

- [WhisperKit](https://github.com/argmaxinc/WhisperKit) by Argmax for on-device speech recognition
- [ONNX Runtime](https://onnxruntime.ai/) by Microsoft for local model inference
- [SentencePiece](https://github.com/google/sentencepiece) by Google for text tokenization
- Punctuation model based on research in neural text processing
- Built with SwiftUI and SwiftData

---

**Made with love for the macOS community**
