# Voice Clicker relay

The relay is a Raspberry Pi Zero 2 W with a Waveshare 1.3 inch LCD HAT. The Logitech Spotlight pairs to the Pi over Bluetooth. The Pi then sends Next and Back over Wi-Fi to Voice Clicker on whichever of your Macs you pick on its screen.

Every Mac with **Wi-Fi Relay** turned on in Voice Clicker's menu shows up on the Pi's screen. A Mac gets clicks only after you pair it once, and only while it's the Mac you picked. Voice Clicker still reads a Spotlight connected straight to the Mac, over Bluetooth or the USB receiver, so you can go back to that at any time.

## Hardware

| Part | Notes |
| --- | --- |
| Raspberry Pi Zero 2 WH | The H means the 40-pin header is already soldered on. |
| Waveshare 1.3 inch LCD HAT | 240x240 screen, a joystick and three buttons. It plugs onto the header. |
| microSD card, 8 GB or more | |
| Micro-USB power | Use the port marked PWR. A Mac's USB port or a 5 V phone charger works. |

To fit the HAT, press it onto the header with the screen facing up. If it came with two standoffs, put them at the two corners away from the header, with a screw up through the Pi and a screw down through the HAT into each.

## Set up the Pi

1. Install Raspberry Pi Imager: `brew install --cask raspberry-pi-imager`.
2. Choose Raspberry Pi Zero 2 W, then Raspberry Pi OS (other), then **Raspberry Pi OS Lite (64-bit)**.
3. In the settings, set the hostname to `voiceclicker`, a username and password, your Wi-Fi (2.4 GHz only), your country and time zone.
4. Turn on SSH with public-key authentication and paste your public key, for example from `pbcopy < ~/.ssh/id_ed25519.pub`.
5. Write the card, put it in the Pi and power it on. The first boot takes about three minutes.
6. Check you can log in with `ssh <username>@voiceclicker.local`.

The deploy script needs passwordless sudo on the Pi. If `ssh <username>@voiceclicker.local sudo -n true` fails, turn it on with your Pi password once:

```bash
ssh -t <username>@voiceclicker.local "echo '<username> ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/010_<username>-nopasswd && sudo chmod 440 /etc/sudoers.d/010_<username>-nopasswd"
```

## Install the relay

From this repo on your Mac:

```bash
./relay/deploy.sh <username>@voiceclicker.local
```

It copies this folder to the Pi and runs `install.sh` there. The script installs the Debian packages, turns on SPI for the screen and installs a `voiceclicker-relay` systemd service that starts on boot. Run it again after you change anything in `relay/`.

Logs: `ssh <username>@voiceclicker.local journalctl -u voiceclicker-relay -f`.

## Pair

1. In Voice Clicker's menu on each Mac, turn on **Wi-Fi Relay**. Allow Local Network access when macOS asks.
2. On the Pi, the Mac shows up as **NEW**. Highlight it with the joystick and press **KEY1**.
3. The Mac asks whether to pair and shows a six-digit code. If the Pi shows the same code, click **Pair** on the Mac and press **KEY1** on the Pi. The Mac's line changes to **OK**.
4. Press **KEY2** on the Pi, then hold the Spotlight's top and bottom buttons for about three seconds, until it vibrates. Remove the Spotlight from your Mac's Bluetooth list first if it keeps reconnecting there.

## Use

| Control | What it does |
| --- | --- |
| Joystick up and down | Move the highlight through the Macs |
| Joystick press | Send clicks to the highlighted Mac, or pair it if it's new |
| Joystick left and right | Switch straight to the previous or next paired Mac |
| KEY1 (top) | Pair the highlighted Mac. On a pairing code, YES |
| KEY2 (middle) | Pair a Spotlight |
| KEY3 (bottom) | The relay's address and details. Elsewhere, NO or BACK |

The `>` marks the Mac that gets clicks. It shows OK when paired and online, OFF when it's off the network, and NEW when it's found but not paired. The screen flashes NEXT or BACK with each click. On the Mac, the menu bar icon and the Claude-in-front rule work exactly as with a directly connected Spotlight.

## How it works

- `voiceclicker_relay/spotlight.py` reads the Spotlight's keys from the Linux input devices BlueZ creates, and grabs them so the Pi's console doesn't see them. It pairs and reads the battery with `bluetoothctl`.
- `macs.py` browses for `_voiceclicker._tcp` with zeroconf and keeps one TCP connection to each Mac.
- `protocol.py` is the protocol, documented at the top of the file. `Sources/RelayProtocol` is the Mac's side of it.
- `ui.py` draws the screen and `lcd.py` drives the ST7789 panel over SPI.
- `app.py` ties them together and handles the HAT's controls.
- The state, including the Mac keys, is in `/var/lib/voiceclicker-relay/state.json`, readable only by the service's user.

## Security

- Pairing is an X25519 key exchange. Both screens show a six-digit code derived from the shared secret, so a device in the middle would show a different code. Confirm on both sides only when the codes match.
- Each Mac has its own 256-bit key, stored in the Mac's keychain. Forget a relay under Advanced > Relays in Voice Clicker's menu.
- Every click carries an HMAC-SHA256 over the Mac's nonce for that connection and a counter that only goes up, so a forged or recorded click fails. Clicks aren't encrypted, because "next" and "back" aren't secret.
- Anyone who holds the Pi can pair a new Mac with it, and can read the keys off its SD card.

## Checks

```bash
cd relay && python3 -m unittest discover -s tests -t .   # needs the cryptography package
swift run relay-protocol-check                            # from the repo root
```

Both use the same test vectors, so the Pi's side and the Mac's side can't drift apart.
