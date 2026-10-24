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
| Dimmed remote | Off, the Spotlight isn't connected, or a permission is missing (open the menu to see which) |
| Remote with a red dot | The microphone is recording, i.e. Claude is listening |
| 🟢 return arrow (flash) | You pressed Back |
| 🔵 hand | Waiting for you to press a new dictation shortcut |

The menu stays minimal: whether the app is running, **Turn Off / Turn On**, **Launch at Login** and **Quit**. Hold **Option** while you click the icon to see **Advanced** settings.

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

Or download a prebuilt `VoiceClicker.zip` from the latest [Build workflow run](https://github.com/CodeHex/voice-clicker/actions/workflows/build.yml) (under *Artifacts*), unzip it, move it to Applications, and since it isn't notarized, clear the download quarantine once:

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

## Using it

1. Open the Claude desktop app and keep it in front.
2. Press **Next** to start dictation, then speak.
3. Press **Next** again to stop dictation.
4. Press **Back** to press Enter.

## Advanced settings (hold Option and click the icon)

- The full status line and the last action the app took.
- **Dictation Shortcut**: record a different shortcut for Next to send, or reset it to ⌘D.
- **Apps**: the apps the buttons act in, the Claude desktop app (`com.anthropic.claudefordesktop`) by default. Bring another app to the front, open the menu, and choose **Add …** to include it. Click an app in the list to remove it.
- **Open Bluetooth Settings…**

## Using it with more than one Mac

Each Mac needs its own copy of Voice Clicker and its own permissions. Each copy only reacts to clicks that reach its Mac. The simplest way to switch is to move the USB receiver; over Bluetooth, re-pair (hold the top and bottom buttons for about 3 seconds) when you switch.

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
- `Microphone.swift` asks Core Audio whether the default microphone is recording, which drives the red dot.
- `AppDelegate.swift` is the menu bar UI and the glue between them.
