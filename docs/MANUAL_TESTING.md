# Manual test checklist

Run these checks on macOS 14.2 or later with a stereo output device.

1. **Permission denial** — Start with a clean privacy state, enable the mixer, deny system-audio recording access, and confirm that apps continue to play normally. The app must show the privacy-settings action and must not mute any app.
2. **Independent volume** — Play audio in two different apps. Enable the mixer, lower one app to 25%, mute the other, and confirm the controls are independent. Restore both to 100% and confirm they return to the normal system route.
3. **Live meter** — Play an audible source and confirm that its green meter moves. Lower the app's slider and confirm the meter decreases; mute it and confirm the meter falls to zero.
4. **Master volume** — Keep two active apps at different volumes, then lower the master slider. Both should scale down while preserving their relative levels.
5. **Boost** — Enable Boost for one app, set it to 150%, and confirm that another app at 100% is not raised. Disable Boost and confirm the app returns to a maximum of 100%.
6. **Output selection and fallback** — Choose a USB, Bluetooth, or HDMI output; confirm adjusted apps route there. Disconnect it and confirm the mixer uses the macOS default output. Reconnect it and confirm the preferred route returns.
7. **Persistence** — Set an app to a non-default volume and mute state, quit the app and the mixer, then reopen both. The setting must be restored by bundle ID.
8. **Login item** — Enable “Iniciar ao entrar no Mac,” log out and back in, then verify the app is running and restores a previously enabled mixer after permission has already been granted.
9. **Chromium helpers** — Play audio in Google Chrome, then open or close tabs that use audio. Confirm the mixer continues to show a single “Google Chrome” control rather than separate Chrome Helper controls, and that its volume setting remains in effect.
10. **Discord adjustable during a call** — Join a Discord call. Discord's row must stay fully adjustable, boost included, so a quiet microphone can still be raised. Its row must show an orange warning and “Em chamada — risco de eco no stream”.
11. **One-click bypass** — Press the **⏻** button on Discord's row. Its status must change to “Fora do mixer”, its slider, boost and mute must go inactive, and Discord must keep playing at its own volume. Start a full-screen share with sound and confirm participants do **not** hear themselves. Press ⏻ again and confirm Discord returns to the mixer at its saved volume and boost. The choice must survive a restart of the app.
    Verify from the outside with `/usr/bin/log show --last 2m --predicate 'subsystem == "com.ydps915.VolumeMixer"' --style compact`: the reconcile line's `targets` count must drop by one while Discord is bypassed.
12. **Automatic bypass (optional)** — Turn on “Tirar o Discord do mixer automaticamente em chamadas” in Preferences and confirm Discord leaves the mixer within about a second of joining a call, and returns after leaving it.
13. **Retomada rápida** — Ajuste o volume de um player, pause-o por menos de 20 segundos e retome. O primeiro som retomado já deve usar o ganho salvo; não deve aguardar a atualização periódica da lista de apps.
14. **Status item** — Confirm the custom fader icon is present in the menu bar and opens the quick mixer. If macOS has no physical room for another status item, remove or hide another menu-bar item; macOS controls overflow placement. The Volume Mixer remains available from the Dock.
15. **Status item without a window** — Close every Volume Mixer window and confirm the app keeps running and the menu-bar item still opens the quick mixer. Quit and relaunch; the item must appear before any window is opened.
16. **Idle CPU** — With the mixer active and audio playing, leave the main window open and watch the app in Activity Monitor for a minute. It should sit in the low single digits, not tens of percent.
17. **Slider crossing 100%** — Drag an app's slider slowly from 50% up past 100% and back down several times. The audio must not pop, cut out, or jump to full volume at the crossing.
18. **Muted app retiring** — Mute an app, pause it for more than 20 seconds so its route is retired, then resume it. It must not play a burst at full volume when the route is torn down or rebuilt.
19. **Packaged app on another Mac** — Copy `dist/Volume Mixer.app` to a machine that has never built this project, or run `swift package clean` first, and launch it. It must start and show its menu-bar glyph rather than crashing on a missing resource bundle.
20. **Menu bar overflow** — With more than eight apps playing, open the quick mixer and confirm the list scrolls and every app is reachable.
