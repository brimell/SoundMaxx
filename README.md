# SoundMaxx

A free, open-source macOS system-wide 10-band parametric equalizer.

SoundMaxx sits in your menu bar and applies real-time EQ processing to all system audio, letting you fine-tune your listening experience across any app.

Project website: [https://brimell.github.io/SoundMaxx/](https://brimell.github.io/SoundMaxx/)

## Screenshots

Tray Menu:
<br />
<img src="docs/Screenshot%202026-04-17%20at%2020.26.21.png" alt="SoundMaxx screenshot 1" width="500" />

Main Menu:
<br />
<img src="docs/Screenshot%202026-04-17%20at%2020.26.42.png" alt="SoundMaxx screenshot 2" width="500" />

## Features

- **10-Band Parametric EQ (Expandable)** - Starts at 10 bands (32Hz to 16kHz) and supports adding/removing bands in Advanced Options
- **7 Filter Types Per Band** - Peak, Low Shelf, High Shelf, Low Pass, High Pass, Notch, and Band Pass
- **±12dB Slider Range** - Fast musical shaping with real-time visual feedback
- **Real-time Response + Spectrum Views** - See both the computed EQ response and live post-EQ spectrum activity
- **Dual Bypass Controls** - Separate "Audio" (full processing) and "EQ" (filters only) toggles for fast A/B checks
- **Built-in Presets** - Flat, Bass Boost, Treble Boost, Vocal, Rock, Electronic, Acoustic
- **Custom Presets** - Save and load your own EQ configurations
- **A/B Compare Snapshots** - Save two temporary EQ states and switch between them instantly
- **Per-Device Profiles** - Save EQ per output device, auto-restore on switch, and auto-save ongoing tweaks (with auto-save toggle)
- **Proper Gain Staging** - Separate headroom (-12 to 0 dB) and post-EQ volume (-40 to +40 dB)
- **Limiter / Clip Guard** - Final output safety stage with configurable ceiling (default: -1 dBFS)
- **Auto-Stop EQ Clipping** - Optional safeguard that automatically trims headroom if the EQ stage clips
- **Output Safety Status** - Separate EQ-stage clipping and post-EQ output status (limited/clipping)
- **Peak-Hold Safety Meters** - Live EQ/output dBFS with held peaks and one-click meter reset
- **HDMI Volume Control** - Software volume slider for HDMI outputs (macOS disables hardware control)
- **Global Output Switch Shortcut** - Press Control+Option+Command+O to cycle to the next output device instantly
- **Shortcut Target Selection** - Choose exactly which output devices are included in shortcut cycling
- **AutoEQ Integration** - Search and apply headphone correction curves from [AutoEQ](https://github.com/jaakkopasanen/AutoEq), including manual catalog refresh
- **AutoEQ Quick Filters** - Narrow catalog by headphone type and favorites for faster selection
- **AutoEQ Favorites Priority** - Optionally keep starred headphones pinned at the top of results
- **AutoEQ Text Import** - Import AutoEQ `ParametricEQ.txt` or `GraphicEQ.txt` files directly
- **Quick Help Popover** - Built-in in-app guidance for setup and controls
- **Menu Bar App** - Always accessible, no dock icon clutter
- **Launch at Login** - Optional auto-start with your Mac
- **Sample Rate Handling** - Attempts automatic sample-rate matching across input/output devices

## Requirements

- macOS 13.0 (Ventura) or later
- [BlackHole 2ch](https://github.com/ExistentialAudio/BlackHole) virtual audio driver

## Installation

### Step 1: Install BlackHole

BlackHole is a free virtual audio driver that routes system audio through SoundMaxx.

```bash
brew install blackhole-2ch
```

Or download directly from [BlackHole Releases](https://github.com/ExistentialAudio/BlackHole/releases).

### Step 2: Install SoundMaxx

Visit the website for screenshots and a quick feature overview:

- [https://brimell.github.io/SoundMax/](https://brimell.github.io/SoundMax/)

**Option A: Download Release (Recommended)**

1. Download the latest DMG from [Releases](https://github.com/brimell/SoundMax/releases)
2. Open the DMG and drag SoundMaxx to Applications
3. If macOS blocks the app: Right-click → Open → Open

**Option B: Build from Source**

```bash
# Install Xcode Command Line Tools
xcode-select --install

# Install XcodeGen
brew install xcodegen

# Clone and build
git clone https://github.com/brimell/SoundMax.git
cd SoundMax
xcodegen generate
xcodebuild -project SoundMaxx.xcodeproj -scheme SoundMaxx -configuration Release build
```

## Setup Guide

### Initial Configuration

1. **Set BlackHole as System Output**
   - Open **System Settings → Sound → Output**
   - Select **BlackHole 2ch**
   - This routes all system audio through BlackHole

2. **Launch SoundMaxx**
   - Open from Applications or Spotlight
   - Look for the slider icon (☰) in the menu bar
   - Grant microphone access when prompted (required to capture audio from BlackHole)

3. **Configure Audio Routing**
   - **Input**: Should auto-select "BlackHole 2ch"
   - **Output**: Select your actual speakers or headphones (e.g., MacBook Speakers, AirPods, Scarlett 2i2)

4. **Start Processing**
   - Click the **Start** button
   - Status indicator turns green when running

### Audio Signal Flow

```
┌─────────────┐    ┌───────────┐    ┌──────────────────────────────────────┐    ┌─────────────┐
│  Your Apps  │ →  │ BlackHole │ →  │               SoundMaxx              │ →  │  Speakers   │
│ (Spotify,   │    │   (2ch)   │    │ Headroom → EQ → Volume → Limiter    │    │ (Real Audio │
│  YouTube)   │    │           │    │                                      │    │   Output)   │
└─────────────┘    └───────────┘    └──────────────────────────────────────┘    └─────────────┘
```

## Usage

### EQ Controls

| Action | Effect |
|--------|--------|
| Drag slider **up** | Boost frequency (orange, up to +12dB) |
| Drag slider **down** | Cut frequency (blue, down to -12dB) |
| Center position | No change (0dB) |
| Toggle switch | Enable/disable EQ processing |

### Audio vs EQ Toggles

- **Audio toggle**: Enables or bypasses the entire chain (headroom + EQ + output stages)
- **EQ toggle**: Bypasses only EQ filters while keeping the rest of the chain active

This makes it easier to run quick A/B checks without losing gain staging.

### Real-time Visual Monitoring

- **Response graph**: Shows the computed frequency response of your active band/filter setup
- **Spectrum analyzer**: Shows live post-EQ spectrum activity in real time

Use both together to correlate what you hear with what the processing is doing.

### Advanced Parametric Controls

Each band includes additional controls under the slider:

- **Filter type menu**: Peak, LS, HS, LP, HP, Notch, BP
- **Frequency field**: Set exact center/cutoff frequency (20Hz to 20kHz)
- **Q field**: Set bandwidth/resonance for precise shaping
- **Band add/remove controls**: Add a new band, remove the last band, or remove an individual band

### Presets

- **Select Preset**: Use the dropdown menu to choose built-in or custom presets
- **Save Custom**: Click **+** to save current EQ settings
- **Delete Custom**: Click trash icon (only available for custom presets)
- **Reset**: Click Reset button to return all bands to 0dB

### Launch at Login

Check the "Launch at Login" box to have SoundMaxx start automatically when you log in. This setting is managed through macOS Login Items.

### Per-Device Profiles

SoundMaxx automatically remembers your EQ settings for each output device:

1. **First time with a device**: Adjust your EQ settings and click "Save Profile"
2. **Returning to a device**: Your saved EQ enabled state, bands, and volume are automatically restored
3. **After saving once**: Further changes are auto-saved to that device profile
4. **HDMI displays**: A software volume slider appears since macOS disables hardware volume control for HDMI

This is perfect for users who switch between headphones, speakers, and HDMI displays with different audio characteristics.

You can delete a saved device profile at any time from the profile controls row.

### Quick Output Device Shortcut

Use the global shortcut **Control+Option+Command+O** to jump to the next available output device without opening the app UI.

- By default, it cycles through all outputs
- In the **Targets** menu, you can limit cycling to specific outputs (for example: speakers + headphones only)
- Shortcut switches also update your saved output device selection

### Import AutoEQ Text Files

In addition to browsing AutoEQ inside the app, you can import downloaded AutoEQ text files:

1. Click the **import icon** next to the preset and AutoEQ buttons
2. Select an AutoEQ `ParametricEQ.txt` file (or `GraphicEQ.txt`)
3. SoundMaxx parses and applies the curve to your current EQ

This is useful when sharing tuned files or testing custom AutoEQ exports.

### AutoEQ Headphone Correction

SoundMaxx integrates with the [AutoEQ](https://github.com/jaakkopasanen/AutoEq) project to provide scientifically-measured frequency response corrections for popular headphones.

1. Click the **headphones icon** (🎧) next to the preset menu
2. Search for your headphones or browse the list
3. Click to apply the correction curve
4. Your EQ is automatically adjusted to flatten your headphone's frequency response

**Included headphones (150+):**
- Over-ear: Sennheiser HD 560S/600/650/800, Beyerdynamic DT 770/880/990, Sony WH-1000XM4/XM5, Audio-Technica ATH-M50x, HiFiMAN Sundara/Ananda/Edition XS, Focal Utopia/Clear, AKG, Meze, Audeze
- In-ear: Apple AirPods Pro/Pro 2, Sony WF-1000XM4/XM5, Samsung Galaxy Buds, Shure SE series, Moondrop (Aria/Chu/Kato/KXXS), Etymotic ER2/ER4, 7Hz, Tin HiFi, KZ, Truthear, FiiO
- Gaming: HyperX Cloud II, SteelSeries Arctis, Razer BlackShark, Logitech G Pro
- On-ear: Koss Porta Pro/KPH40, Grado SR series

The correction curves are fetched from the AutoEQ database and converted to our 10-band format.

## Troubleshooting

### No Audio Output

1. Verify BlackHole is set as system output in System Settings → Sound
2. Check SoundMaxx shows "Running" status (green indicator)
3. Ensure the correct output device is selected in SoundMaxx
4. Try clicking Stop, then Start again

### No Sound from Specific Apps

Some apps have their own audio output settings. Check the app's preferences and ensure it's using "System Default" or "BlackHole 2ch" as output.

### "Microphone Access" Prompt

SoundMaxx requires microphone permission to capture audio from BlackHole. This is a macOS security requirement for any app that reads audio input.

- Click **Allow** when prompted
- If previously denied: System Settings → Privacy & Security → Microphone → Enable SoundMaxx

### App Won't Open (Blocked by macOS)

For unsigned builds, macOS Gatekeeper may block the app:

1. Right-click the app → **Open** → **Open**
2. Or: System Settings → Privacy & Security → Click **Open Anyway**

### Audio Crackling or Dropouts

- Close other audio-intensive applications
- Try a different output device
- Check Audio MIDI Setup to ensure sample rates match (44.1kHz or 48kHz)

### Sample Rate Mismatch Errors

SoundMaxx attempts to match sample rates automatically. If issues persist:

1. Open **Audio MIDI Setup** (in /Applications/Utilities)
2. Set both BlackHole and your output device to the same sample rate
3. Restart SoundMaxx

## Project Structure

```
SoundMaxx/
├── SoundMaxx/
│   ├── SoundMaxxApp.swift           # App entry, menu bar setup
│   ├── ContentView.swift            # Main UI
│   ├── Audio/
│   │   ├── AudioEngine.swift        # Core Audio routing (AUHAL)
│   │   └── BiquadFilter.swift       # Parametric EQ DSP
│   ├── Models/
│   │   ├── EQModel.swift            # EQ state management
│   │   ├── EQPreset.swift           # Preset definitions
│   │   ├── AudioDeviceManager.swift # Device enumeration
│   │   ├── AutoEQManager.swift      # AutoEQ catalog/search/fetch
│   │   ├── DeviceProfile.swift      # Per-device profile persistence
│   │   └── LaunchAtLogin.swift      # Login item management
│   └── Views/
│       ├── EQSliderView.swift       # Custom EQ slider
│       └── AutoEQView.swift         # AutoEQ search/apply UI
├── scripts/
│   └── build-release.sh             # DMG build script
├── project.yml                      # XcodeGen configuration
└── README.md
```

## Technical Details

- **Audio Framework**: Core Audio with AudioToolbox AUHAL units
- **DSP**: Biquad filters implementing peak, shelf, pass, notch, and band-pass EQ (Audio EQ Cookbook)
- **UI**: SwiftUI with MenuBarExtra
- **Audio Format**: 32-bit float, non-interleaved stereo
- **Latency**: Minimal (256-512 sample buffer)

## Building a Release

```bash
./scripts/build-release.sh
```

This creates a DMG installer in the `build/` directory.

## Publishing to GitHub Releases

Use the publish script to build and upload the latest DMG to GitHub Releases.

Prerequisites:

```bash
brew install gh
```

### Configure with `.env` (Recommended)

Copy the example file and fill in your values:

```bash
cp .env.example .env
```

Common fields:

- `GITHUB_REPOSITORY` (for example `brimell/SoundMax`)
- `GH_TOKEN` or `GITHUB_TOKEN` (optional if `gh auth login` is already set up)
- `RELEASE_TAG`, `RELEASE_TITLE`, `RELEASE_NOTES`
- `RELEASE_SKIP_BUILD=true` if you want upload-only by default

Then run:

```bash
./scripts/publish-release.sh
```

Optional: use a different env file:

```bash
./scripts/publish-release.sh --env-file .env.release
```

### CLI + Auth Notes

You can authenticate either by:

- Running `gh auth login`, or
- Providing `GH_TOKEN` / `GITHUB_TOKEN` in your `.env`

Default usage (build + upload):

```bash
./scripts/publish-release.sh
```

Useful options:

```bash
# Upload an already-built DMG
./scripts/publish-release.sh --skip-build

# Override release metadata
./scripts/publish-release.sh --tag v1.0.1 --title "SoundMaxx v1.0.1" --notes "Release notes here"

# Publish to a specific repository
./scripts/publish-release.sh --repo brimell/SoundMax
```

Behavior:

- Uses `v<CFBundleShortVersionString>` as the default tag
- Creates the release if it does not exist
- Uploads/replaces the DMG asset if the release already exists

For signed distribution:
```bash
# Sign the app
codesign --deep --force --verify --verbose --sign "Developer ID Application: Your Name" build/DerivedData/Build/Products/Release/SoundMaxx.app

# Notarize
xcrun notarytool submit build/SoundMaxx-Installer.dmg --apple-id your@email.com --team-id TEAMID --password app-specific-password
```

## License

MIT License - See [LICENSE](LICENSE) file for details.

## Acknowledgments

- [BlackHole](https://github.com/ExistentialAudio/BlackHole) by Existential Audio - Virtual audio driver
- [Audio EQ Cookbook](https://www.w3.org/2011/audio/audio-eq-cookbook.html) by Robert Bristow-Johnson - Biquad filter coefficients
- Built with SwiftUI and Core Audio
