# Volume Mixer for macOS

An open-source macOS volume mixer with individual controls for active apps.

## What it does

- Per-app volume and mute controls.
- Optional per-app boost up to 200%; it is off by default and may cause distortion.
- A live meter for each active app, using a perceptual dB scale so normal listening levels remain visible. It turns orange and then red as the app approaches clipping, which matters when boost is on.
- Favorite an app to keep its control visible even when it is not playing audio.
- A custom app icon and a monochrome menu-bar glyph that adapts to light and dark macOS menu bars.
- Discord is automatically left out of the mixer while it is capturing audio — a call or a screen share with sound — so a shared screen never feeds Discord's own audio back to the call. The rest of the time you control its volume normally. See [Screen sharing and echo](#screen-sharing-and-echo).
- Core Audio change notifications and a short warm-route cache apply a saved app volume as soon as audio resumes, instead of relying on a periodic app scan.
- A global master volume and one selected physical output.
- Menu bar controls, a full window, remembered app preferences, and an optional login item. The menu bar item is installed by the app itself, so it is present even when the app starts with no window — for example as a login item.
- Automatic fallback to the macOS default output when the selected device disappears. A preferred device that is currently unplugged still appears in the picker as unavailable rather than leaving it blank.
- An app playing at exactly 100% is metered through a tap-only route that carries no output device, so it cannot disturb the physical output. Only an app you actually adjust is rendered by the mixer.

The app uses Apple's public Core Audio Taps API rather than installing a virtual audio driver. It runs only on macOS 14.2 or later and requests **System Audio Recording** permission when the mixer is enabled.
The app and Preferences window always show the current permission check result and provide **Check** and **Open Settings** actions.

## Screen sharing and echo

To change an app's volume the mixer has to mute that app and re-render its audio itself. The process emitting the sound therefore becomes **Volume Mixer**, not the original app.

Discord's screen share captures every process except Discord's own. It has no way to know that the Volume Mixer stream it is capturing *is* Discord's audio, so if the mixer is routing Discord while you share your screen, participants hear themselves. Nothing in the app can opt out of another app's capture — the only fix is to keep Discord on its own route while it is capturing.

Preferences offers three modes:

| Mode | Behaviour |
| --- | --- |
| **Durante chamadas e streams** (default) | Discord leaves the mixer only while `kAudioProcessPropertyIsRunningInput` is true for it. You keep volume control the rest of the time. |
| **Sempre** | Discord is never routed through the mixer. |
| **Nunca** | Discord is always routed. Only safe if you never share your screen with sound. |

The automatic mode cannot tell a plain voice call apart from a screen share with sound: private Core Audio taps are not visible to other processes, so "Discord is capturing audio" is the most precise signal available. It errs toward protecting the call.

Other apps are unaffected: while sharing, participants still hear them at the levels the mixer is applying, which is what you hear too.

## Privacy

Audio is processed locally in memory while the mixer is active. The app does not record audio, create audio files, or send data to a service.

## Install

Download the latest `.zip` from [Releases](https://github.com/ydps915/volume-mixer-mac/releases), unzip it, and move **Volume Mixer.app** to your Applications folder.

The app is **ad-hoc signed, not notarized by Apple**, so macOS blocks the first launch. Clear the download quarantine flag once:

```bash
xattr -dr com.apple.quarantine "/Applications/Volume Mixer.app"
```

Then open the app and turn on **Mixer ativo**. macOS asks for **System Audio Recording** permission — that is what lets the mixer adjust per-app volume. Audio is processed locally and never recorded.

Keeping the app in `/Applications` also matters for the login item: `SMAppService` refuses to register an app from a temporary location.

## Requirements

- macOS 14.2+
- A stereo output device for the apps you adjust — metering works on any output
- To build from source: Xcode 16+ or the matching Swift toolchain

## Build and run

Open `Package.swift` in Xcode, or run:

```bash
./script/build_and_run.sh
```

The script builds the Swift package in **release** configuration (the audio DSP runs in the render callback, so an unoptimized build is not worth testing with), stages `dist/Volume Mixer.app`, signs it, and launches it. The first activation prompts for the system-audio permission. If permission was denied, open System Settings from the app and allow Volume Mixer under the audio-capture privacy control.

By default the app is **ad-hoc signed**, which pins its code hash. macOS therefore treats every rebuild as a different app and asks for System Audio Recording again. To keep the grant across builds, sign with a stable identity — a self-signed code-signing certificate created in Keychain Access is enough:

```bash
CODESIGN_IDENTITY="Volume Mixer Dev" ./script/build_and_run.sh
```

Use `VOLUME_MIXER_CONFIGURATION=debug` when you need an unoptimized build with symbols.

## Current limitations

- One global output device; routing different apps to different devices is not in v1.
- Adjusted apps require a **stereo** output device. On a non-stereo output the mixer reports it and leaves those apps on the normal system route; meters still work.
- No equalizer or recording; per-app boost is capped at 200%.
- Changing an app's volume causes it to use a private Core Audio tap route. Once an app has been adjusted it keeps that route for the rest of the session, even if you return it to 100% — rebuilding the tap every time the slider crosses 100% was audible.
- The master slider scales the apps the mixer can see. It does not change the macOS system volume, and it does not affect an app excluded by the Discord stream protection.

## Contributing

Please open an issue or pull request with a focused description and include the output of `swift test`.
Use the [manual test checklist](docs/MANUAL_TESTING.md) for changes that affect audio routing or permissions.

## License

[MIT](LICENSE)
