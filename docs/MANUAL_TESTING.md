# Manual test checklist

Run these checks on macOS 14.2 or later with a stereo output device.

1. **Permission denial** — Start with a clean privacy state, enable the mixer, deny system-audio recording access, and confirm that apps continue to play normally. The app must show the privacy-settings action and must not mute any app.
2. **Independent volume** — Play audio in two different apps. Enable the mixer, lower one app to 25%, mute the other, and confirm the controls are independent. Restore both to 100% and confirm they return to the normal system route.
3. **Master volume** — Keep two active apps at different volumes, then lower the master slider. Both should scale down while preserving their relative levels.
4. **Output selection and fallback** — Choose a USB, Bluetooth, or HDMI output; confirm adjusted apps route there. Disconnect it and confirm the mixer uses the macOS default output. Reconnect it and confirm the preferred route returns.
5. **Persistence** — Set an app to a non-default volume and mute state, quit the app and the mixer, then reopen both. The setting must be restored by bundle ID.
6. **Login item** — Enable “Iniciar ao entrar no Mac,” log out and back in, then verify the app is running and restores a previously enabled mixer after permission has already been granted.
