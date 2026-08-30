# Volume Mixer for macOS

An open-source macOS volume mixer with individual controls for active apps.

## What it does

- Per-app volume and mute controls.
- Optional per-app boost up to 200%, off by default, with a **peak limiter** so it stays usable. Boosting a quiet talker normally means they clip the moment they raise their voice; the limiter holds only the peaks at about -1 dBFS and lets quiet speech through at the full boost. See [Boost and the limiter](#boost-and-the-limiter).
- A live meter for each active app, using a perceptual dB scale so normal listening levels remain visible. It turns orange and then red as the app approaches clipping, which matters when boost is on.
- Favorite an app to keep its control visible even when it is not playing audio.
- A custom app icon and a monochrome menu-bar glyph that adapts to light and dark macOS menu bars.
- A per-app **⏻ button** on every row takes that app out of the mixer in one click, which is what stops a Discord screen share from echoing. Discord stays adjustable during calls — including boost for a quiet mic — with a warning on its row while sharing would echo. See [Screen sharing and echo](#screen-sharing-and-echo).
- Core Audio change notifications and a short warm-route cache apply a saved app volume as soon as audio resumes, instead of relying on a periodic app scan.
- A global master volume and one selected physical output.
- Menu bar controls, a full window, remembered app preferences, and an optional login item. The menu bar item is installed by the app itself, so it is present even when the app starts with no window — for example as a login item.
- Automatic fallback to the macOS default output when the selected device disappears. A preferred device that is currently unplugged still appears in the picker as unavailable rather than leaving it blank.
- An app playing at exactly 100% is metered through a tap-only route that carries no output device, so it cannot disturb the physical output. Only an app you actually adjust is rendered by the mixer.

The app uses Apple's public Core Audio Taps API rather than installing a virtual audio driver. It runs only on macOS 14.2 or later and requests **System Audio Recording** permission when the mixer is enabled.
The app and Preferences window always show the current permission check result and provide **Check** and **Open Settings** actions.

## Boost and the limiter

Raising an app to 200% to hear someone with a quiet microphone works until that
person speaks up: 0.85 amplitude at 200% is 1.7, far past full scale, and the
result is the crackling that makes boost unusable.

A peak limiter runs whenever the mixer is amplifying above 100%. It measures the
peak of each buffer *before* rendering it, so it can pull the gain down on the
very buffer that would have clipped, and recovers over about 250 ms so a sentence
does not pump between words. Quiet passages keep the full boost.

Measured on a synthetic quiet-talker signal with a loud burst, at 200%:

| | peak | clipped samples |
| --- | --- | --- |
| Raw boost | 1.700 | 17188 |
| With the limiter | 0.891 | 0 |

Gain still applied to quiet speech shortly after the burst: **1.99×** of the 2×
requested.

It can be turned off in Preferences under **Boost** if you want the raw gain.

## Recovering from a dead route

An adjusted app is muted at the system level and played back by the mixer, so if
that route ever stops rendering the app goes **silent** rather than merely
unadjusted. A Bluetooth output reconnecting, or changing sample rate underneath a
running route, both do this. The mixer now checks each rendering route once a
second and, after three consecutive silent checks, tears it down — which unmutes
the app immediately — and rebuilds it. The same check rebuilds a route whose
device changed format.

Only routes whose app is actually producing audio are checked. A pre-armed route
for an idle app legitimately receives no callbacks.

## Screen sharing and echo

To change an app's volume the mixer has to mute that app and re-render its audio itself. The process emitting the sound therefore becomes **Volume Mixer**, not the original app.

Discord's screen share captures every process except Discord's own. It has no way to know that the Volume Mixer stream it is capturing *is* Discord's audio, so if the mixer is routing Discord while you share your screen, participants hear themselves. Nothing in the app can opt out of another app's capture — the only fix is to keep Discord on its own route while it is capturing.

This is a manual choice, on purpose. Dropping Discord from the mixer automatically would also drop the boost people rely on to hear someone with a quiet microphone — exactly when they need it.

So every row has a **⏻ button** that takes that app out of the mixer instantly. Press it before sharing your screen with sound, press it again afterwards. The app keeps playing normally the whole time; only the mixer stops touching it. The choice is remembered per app.

While an app that captures audio is being rendered by the mixer, its row shows an orange warning so you know a screen share right now would echo. Preferences has an off-by-default toggle to make that bypass automatic instead, if you prefer safety over control.

The automatic option cannot tell a plain voice call apart from a screen share with sound: private Core Audio taps are not visible to other processes, so `kAudioProcessPropertyIsRunningInput` — "this app is capturing audio" — is the most precise signal available.

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
