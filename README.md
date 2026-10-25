# Voice Clicker

A small macOS menu bar app that turns a **Logitech Spotlight** presentation clicker into a voice remote for the **Claude desktop app**:

| Clicker button | What happens |
| --- | --- |
| **Next** (the big middle button) | Sends **⌘D** to start dictation. Press again to stop it. |
| **Back** (the bottom button) | Presses **Enter**, exactly like the key on your keyboard. |

The buttons only do this while the Claude desktop app is the frontmost app. With anything else in front, the clicker sends its normal arrow keys, so it still works as a presenter remote.

A small remote icon in the menu bar shows the app's state:

| Icon | Meaning |
| --- | --- |
| Remote | On, Spotlight connected, ready |
| Remote with `80%` beside it | The Spotlight's battery level, shown while it's connected |
| Dimmed remote | Off, the Spotlight isn't connected, or a permission is missing (open the menu to see which) |
| Remote with a red dot | The microphone is recording (Claude is listening) |
| 🟢 return arrow (flash) | You pressed Back |
| 🔵 hand | Waiting for you to press a new dictation shortcut |

The menu stays minimal: whether the app is running, the Spotlight's battery, **Turn Off / Turn On**, **Check for Updates…**, **Launch at Login** and **Quit**. Hold **Option** while you click the icon to see **Advanced** settings.

If the icon vanishes when the menu bar gets crowded (on a MacBook with a notch, macOS hides the leftmost icons), hold **⌘** and drag the remote further right. The app remembers where you put it.

## Requirements

- macOS 13 Ventura or later
- Xcode or the Xcode Command Line Tools (`xcode-select --install`), for Swift 5.9+
- A Logitech Spotlight, paired over its USB receiver or Bluetooth (below)

## 1. Connect the Spotlight to your Mac

Charge it first if it's been sitting in a drawer: plug its USB-C cable into the bottom of the clicker. One minute of charging gives about three hours of use.

Pick **one** of these:

**Option A: USB receiver (no pairing needed).** The receiver is stored inside the bottom end of the Spotlight; pull it out and plug it into your Mac (a MacBook needs a USB-C to USB-A adapter). The clicker comes paired to its own receiver, so press any button and it's connected.

**Option B: Bluetooth.**
1. On the Mac, open **System Settings → Bluetooth**.
2. On the Spotlight, press and hold the **top** (pointer) and **bottom** (Back) buttons together for about 3 seconds, until the clicker vibrates. It stays in pairing mode for three minutes ([Logitech's steps](https://support.logi.com/hc/en-gb/articles/360023300194)).
3. Click **Connect** next to **Spotlight** in the Bluetooth list.

The Spotlight sleeps to save battery. Press any button to wake it; the menu bar icon stops being dimmed once the app sees it.

You don't need Logi Options+. If you have it and have remapped the Spotlight's Next or Back buttons, reset them to their defaults (or quit Options+), because Voice Clicker listens for the clicker's default Right Arrow and Left Arrow.

## 2. Build and run

```bash
git clone https://github.com/CodeHex/voice-clicker.git
cd voice-clicker
make install     # builds "Voice Clicker.app", copies it to /Applications and opens it
```

Other targets: `make run` (build and open from `build/` without installing) and `make app` (build only).

Or download `VoiceClicker.zip` from the [latest release](https://github.com/CodeHex/voice-clicker/releases/latest), unzip it, move it to Applications, and since it isn't notarized, clear the download quarantine once:

```bash
xattr -dr com.apple.quarantine "/Applications/Voice Clicker.app"
```

## 3. Grant permissions

On first launch macOS asks for two permissions. Turn **Voice Clicker** on in both, under **System Settings → Privacy & Security**:

| Permission | Why |
| --- | --- |
| **Input Monitoring** | Read button presses from the Spotlight. |
| **Accessibility** | Send ⌘D and Enter to Claude, and keep the clicker's own arrow keys out of it. |

When you switch a permission on, System Settings may offer **Quit & Reopen**. That briefly restarts the app, which is expected. The app also checks every couple of seconds and picks the permissions up without a restart. If the menu says a permission is still missing, use **Grant Accessibility…** / **Grant Input Monitoring…** from the menu.

**Rebuilt the app and it stopped working?** The build script signs with your Apple Development certificate if you have one, and otherwise ad-hoc with a signature pinned to the bundle ID, so grants should survive rebuilds. If a permission looks on but the menu says it's missing, an older build's entry is probably stale: quit the app, run `make reset-permissions`, remove Voice Clicker from both lists with the minus button, reopen it and grant again.

## Updates

When it starts, Voice Clicker checks [GitHub Releases](https://github.com/CodeHex/voice-clicker/releases) and, if there's a newer version, installs it and relaunches on its own. **Check for Updates…** in the menu does the same on demand, asking first. It only updates itself from `/Applications` (or `~/Applications`), so a build you run from `build/` is left alone.

Before installing, the app checks that the zip came from this repo's releases, that its SHA-256 matches the checksum GitHub lists for it, and that it holds Voice Clicker at the release's version with a signature pinned to our bundle ID.

Releases are signed the same way as local builds (ad-hoc, pinned to the bundle ID), so Input Monitoring and Accessibility carry over. If you build locally with an Apple Development certificate, the first update from a release changes the signature and macOS asks for both permissions once more.

To publish a release, tag a commit and push the tag. The Release workflow builds the app with that version and attaches the zip:

```bash
git tag v1.0.1 && git push origin v1.0.1
```

## Security notes

- **Updates trust this repo's GitHub releases.** Releases are signed ad-hoc, so the signature check proves the bundle ID but not who built the app. Anyone who can push a `v*` tag (or replace a release asset) can ship code that inherits the app's permissions. Turning on GitHub's *immutable releases* for the repo stops assets being swapped after publishing.
- **Ad-hoc grants are keyed to the bundle ID alone.** Pinning the signature to `com.codehex.VoiceClicker` is what lets permissions survive rebuilds and updates, but it also means any app ad-hoc signed with that ID gets Voice Clicker's Accessibility and Input Monitoring grants. Signing with a real certificate (set `CODESIGN_IDENTITY`, for releases too) closes that gap, at the cost of granting the permissions once more.

## Using it

1. Open the Claude desktop app and keep it in front.
2. Press **Next** to start dictation, then speak.
3. Press **Next** again to stop dictation.
4. Press **Back** to press Enter.

## Advanced settings (hold Option and click the icon)

- The full status line and the last action the app took.
- **Dictation Shortcut**: record a different shortcut for Next to send (Esc cancels), or reset it to ⌘D.
- **Apps**: the apps the buttons act in, the Claude desktop app (`com.anthropic.claudefordesktop`) by default. Bring another app to the front, open the menu, and choose **Add …** to include it. Click an app in the list to remove it.
- **Open Bluetooth Settings…**

## Troubleshooting

- **Icon stays dimmed and the status says "waiting for Spotlight"**: press a button to wake it, and check it shows as connected in Bluetooth settings or the receiver is plugged in.
- **Buttons do nothing in Claude**: check the status says On and that **Apps** (under Advanced) lists Claude.
- **The red dot is on but Claude isn't listening**: the dot shows when any app is using the microphone (a call, for example), not just Claude.
- **Arrow keys still reach Claude**: another app (often Logi Options+) is holding the device. Quit it.
- **Logs**: `log stream --predicate 'subsystem == "com.codehex.VoiceClicker"' --info`. The app logs every status change (with its permission state) and every Spotlight interface it opens.

## How it works

- `SpotlightHID.swift` uses IOKit's `IOHIDManager` to find the Spotlight (Logitech vendor `0x046D`; product `0xC53E` for the USB receiver, `0xB503` for Bluetooth, or any device named "Spotlight") and opens only its keyboard and consumer-control interfaces. It tries exclusive access first, so the arrow keys don't reach other apps; macOS refuses that over Bluetooth, so there it opens the device shared (the status line then says "shared access").
- `KeyTap.swift` is a `CGEventTap` that records the dictation shortcut and, with shared access, swallows the Spotlight's arrow keys while Claude is in front.
- `Actions.swift` posts ⌘D and Enter through `CGEvent`, and handles the permission checks.
- `Battery.swift` reads the Spotlight's battery: the `BatteryPercent` macOS publishes in the I/O Registry for Bluetooth devices if it's there, or else Logitech's HID++ protocol (Unified Battery `0x1004` or Battery Status `0x1000`) on the clicker's vendor interface, refreshed every minute.
- `Updater.swift` checks the latest GitHub release, downloads the zip, checks its checksum, version and that its signature is pinned to our bundle ID, swaps it in once the app quits and reopens it.
- `Microphone.swift` asks Core Audio whether the default microphone is recording, which drives the red dot.
- `StatusIcon.swift` draws the menu bar icon, and `AppDelegate.swift` is the menu and the glue between the rest.
- `Resources/AppIcon/AppIcon.svg` is the app icon's source. After editing it, render it to the 1024×1024 `AppIcon.png` next to it (for example `rsvg-convert -w 1024 -h 1024 AppIcon.svg -o AppIcon.png`); `build-app.sh` turns that PNG into the bundle's `.icns` with `sips` and `iconutil`.
