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
10. **Discord stream protection** — Leave “Proteger Discord em chamadas e streams” enabled in Preferences. Confirm that Discord shows “Protegido de streams” and cannot be routed by the mixer. Start a screen share with sound and confirm participants do not hear an extra copy of the call produced by the mixer's Discord route. To control Discord itself, turn that protection off first.
11. **Retomada rápida** — Ajuste o volume de um player, pause-o por menos de 20 segundos e retome. O primeiro som retomado já deve usar o ganho salvo; não deve aguardar a atualização periódica da lista de apps.
12. **Status item** — Confirm the custom fader icon is present in the menu bar and opens the quick mixer. If macOS has no physical room for another status item, remove or hide another menu-bar item; macOS controls overflow placement. The Volume Mixer remains available from the Dock.
