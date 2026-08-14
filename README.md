# Volume Mixer for macOS

An open-source macOS volume mixer with individual controls for active apps.

## What it does

- Per-app volume and mute controls.
- Optional per-app boost up to 200%; it is off by default and may cause distortion.
- A live green meter for each active app, reflecting its effective mixer level.
- Favorite an app to keep its control visible even when it is not playing audio.
- A global master volume and one selected physical output.
- Menu bar controls, a full window, remembered app preferences, and an optional login item.
- Automatic fallback to the macOS default output when the selected device disappears.

The app uses Apple's public Core Audio Taps API rather than installing a virtual audio driver. It runs only on macOS 14.2 or later and requests **System Audio Recording** permission when the mixer is enabled.
The app and Preferences window always show the current permission check result and provide **Check** and **Open Settings** actions.

## Privacy

Audio is processed locally in memory while the mixer is active. The app does not record audio, create audio files, or send data to a service.

## Requirements

- macOS 14.2+
- Xcode 16+ or the matching Swift toolchain
- A stereo output device for adjusted audio routes in this first release

## Build and run

Open `Package.swift` in Xcode, or run:

```bash
./script/build_and_run.sh
```

The script builds the Swift package, stages `dist/Volume Mixer.app`, ad-hoc signs it for local testing, and launches it. The first activation prompts for the system-audio permission. If permission was denied, open System Settings from the app and allow Volume Mixer under the audio-capture privacy control.

## Current limitations

- One global output device; routing different apps to different devices is not in v1.
- No equalizer or recording; per-app boost is capped at 200%.
- Changing an app's volume causes it to use a private Core Audio tap route. Apps left at 100% remain on the normal system route.

## Contributing

Please open an issue or pull request with a focused description and include the output of `swift test`.
Use the [manual test checklist](docs/MANUAL_TESTING.md) for changes that affect audio routing or permissions.

## License

[MIT](LICENSE)
