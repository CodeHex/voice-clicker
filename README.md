# Voice Clicker

A small macOS menu bar app that turns a **Logitech Spotlight** presentation clicker into a voice remote for Claude Code (or any other app):

| Clicker button | What happens |
| --- | --- |
| **Next** (the big middle button) | Starts macOS Dictation in the frontmost app. Press again to stop. |
| **Back** (the bottom button) | Stops dictation if it's running, waits a moment for the last words to land, then presses **Return** to submit the prompt. |

You can swap these or use different buttons with **Learn Buttons…** in the menu.

A microphone icon in the menu bar shows the app's state:

| Icon | Meaning |
| --- | --- |
| 🎙 `mic` | On, Spotlight connected, ready |
| `mic.slash` | Off, the Spotlight isn't connected, or a permission is missing (open the menu to see which) |
| 🟠 filled mic (flash) | You pressed the voice button |
| 🟢 return arrow (flash) | You pressed the submit button |
| 🔴 filled mic | Dictation is running |
| 🔵 hand | Waiting for you to press a button while learning |

Click the icon for status, the last action, settings, and **Turn Off / Turn On**.

## Requirements

- macOS 13 Ventura or later
- Xcode or the Xcode Command Line Tools (`xcode-select --install`), for Swift 5.9+
- A Logitech Spotlight, paired over its USB receiver or Bluetooth (below)

## 1. Connect the Spotlight to your Mac

Charge it first if it's been sitting in a drawer: plug its USB-C cable into the bottom of the clicker. One minute of charging gives about three hours of use.

Pick **one** of these:

**Option A: USB receiver (simplest, no pairing needed).** The receiver is stored inside the bottom end of the Spotlight; pull it out and plug it into your Mac. It's USB-A, so a MacBook needs a USB-C to USB-A adapter. The clicker comes paired to its own receiver, so press any button and it's connected.

**Option B: Bluetooth.**
1. On the Mac, open **System Settings → Bluetooth** (the app's menu also has **Clicker Input → Open Bluetooth Settings…**).
2. On the Spotlight, press and hold **Next** and **Back** together for about 3 seconds, until the light starts blinking. It's now in pairing mode.
3. Click **Connect** next to **Spotlight** in the Bluetooth list.

If the clicker doesn't appear, search for "Spotlight" on [Logitech support](https://support.logi.com) for your model's pairing steps.

The Spotlight sleeps to save battery. Press any button to wake it; the menu bar icon switches from `mic.slash` to `mic` once the app sees it.

## 2. Logi Options+ (optional, but read this)

You **don't** need Logi Options+. Out of the box the Spotlight sends Right Arrow (Next) and Left Arrow (Back), and Voice Clicker reads those straight from the device.

If you do have Options+ installed and have remapped the Spotlight's buttons in it, Options+ intercepts the presses before they reach the normal keyboard channel, and Voice Clicker won't see them. Either:

- reset the Next and Back buttons to their defaults in Options+ (or quit Options+), **or**
- in Options+, map the two buttons to unusual keys such as **F18** and **F19**, then in Voice Clicker choose **Clicker Input → Keystrokes (Logi Options+ Remap)** and use **Learn Buttons…** to teach it those keys.

The top (highlight/pointer) button only works through Options+, so use Next and Back with the default mode.

## 3. Build and run

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

## 4. Grant permissions

On first launch macOS asks for two permissions. Turn **Voice Clicker** on in both, under **System Settings → Privacy & Security**:

| Permission | Why |
| --- | --- |
| **Input Monitoring** | Read button presses from the Spotlight. |
| **Accessibility** | Press Start/Stop Dictation in the Edit menu, press Return, and listen for keystrokes. |

When you switch a permission on, System Settings may offer **Quit & Reopen**. That briefly quits and restarts the app, which is expected and isn't a crash. The app also checks every couple of seconds and picks the permissions up without a restart. If the menu says a permission is still missing, use **Grant Accessibility…** / **Grant Input Monitoring…** from the menu.

**Rebuilt the app and it stopped working?** The build is ad-hoc signed, so macOS treats each rebuild as a new app. Remove Voice Clicker from both lists (or run `make reset-permissions`) and grant again. To avoid this, sign with your Apple Development certificate:
`CODESIGN_IDENTITY="Apple Development: Your Name (TEAMID)" make install`.

## 5. Turn on Dictation

**System Settings → Keyboard → Dictation → On.** The first time you dictate, macOS may ask to allow the microphone.

## Using it with Claude Code

1. Run `claude` in Terminal, iTerm2, Ghostty, the VS Code terminal, or any app with an **Edit → Start Dictation** menu item.
2. Keep that window in front. Press **Next** and talk. Your words appear in Claude Code's prompt.
3. Press **Back** to stop dictation and submit.

Voice Clicker always acts on the frontmost app, so it also works anywhere else you can dictate.

## Settings (in the menu)

- **Learn Buttons…**: press the button for voice, then the one for submit.
- **Voice Action**
  - *macOS Dictation (Edit menu)* (default): presses Start/Stop Dictation through Accessibility, so there's no shortcut to configure. This relies on the English menu titles.
  - *Keyboard Shortcut*: press a recorded shortcut instead. Use this if your Mac isn't in English, or to drive another voice tool such as Superwhisper or Wispr Flow. Set a custom Dictation shortcut in System Settings → Keyboard → Dictation, then **Record Shortcut…** and press it.
- **Submit Action**: whether to stop dictation before Return, and how long to wait (0.2–2 s; use longer for tools that transcribe after you stop).
- **Clicker Input**
  - *Spotlight Directly*: read the device over HID (default).
  - *Keystrokes*: react to keys from any keyboard (for Options+ remaps).
  - *Exclusive Access to Spotlight*: on by default, so the clicker's arrow keys don't also move the cursor in your terminal. If another app holds the device, Voice Clicker falls back to shared access and swallows those keys itself; the status line then says "shared access".
- **Launch at Login**: works when the app runs from `/Applications`.

## Troubleshooting

- **Icon shows `mic.slash` and the status says "waiting for Spotlight"**: press a button to wake it, and check it shows as connected in Bluetooth settings or the receiver is plugged in.
- **"No Start Dictation menu item in …"**: that app has no Dictation menu item (or it's greyed out because no text field is focused). Click into the terminal window, or switch to *Keyboard Shortcut*.
- **Arrow keys still move the cursor**: another app (often Logi Options+) holds the device. See section 2.
- **Logs**: `log stream --predicate 'subsystem == "com.codehex.VoiceClicker"' --info`. The app logs every status change (with its permission state) and every Spotlight it opens.

## How it works

- `SpotlightHID.swift` uses IOKit's `IOHIDManager` to find the Spotlight (Logitech vendor `0x046D`; product `0xC53E` for the USB receiver, `0xB503` for Bluetooth, or any device named "Spotlight") and opens only its keyboard and consumer-control interfaces, exclusively when possible.
- `KeyTap.swift` is a `CGEventTap` for recording shortcuts, keystroke mode, and swallowing Spotlight keys when exclusive access isn't available.
- `Actions.swift` presses the Dictation menu items through the Accessibility API and posts Return through `CGEvent`.
- `AppDelegate.swift` is the menu bar UI and the glue between them.
