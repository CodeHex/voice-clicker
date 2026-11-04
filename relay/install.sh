#!/usr/bin/env bash
# Installs the relay on a Raspberry Pi running Raspberry Pi OS Lite. Run it on
# the Pi from this folder:
#
#   sudo ./install.sh
#
# Or from a Mac, with deploy.sh, which copies this folder over first.
set -euo pipefail
cd "$(dirname "$0")"

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo ./install.sh" >&2
  exit 1
fi

apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  python3-evdev python3-zeroconf python3-cryptography python3-spidev python3-pil \
  python3-numpy python3-gpiozero python3-lgpio fonts-dejavu-core bluez >/dev/null

# The LCD HAT is on SPI, which Raspberry Pi OS ships turned off.
raspi-config nonint do_spi 0
rfkill unblock bluetooth

# A system user with only the groups the relay needs: input for the
# Spotlight, spi and gpio for the HAT, bluetooth for pairing.
if ! id voiceclicker >/dev/null 2>&1; then
  useradd --system --no-create-home --shell /usr/sbin/nologin voiceclicker
fi
usermod -a -G input,spi,gpio,bluetooth voiceclicker

install -d /opt/voiceclicker-relay
rm -rf /opt/voiceclicker-relay/voiceclicker_relay
cp -R voiceclicker_relay /opt/voiceclicker-relay/
install -m 644 voiceclicker-relay.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable voiceclicker-relay >/dev/null
systemctl restart voiceclicker-relay
echo "Installed. Logs: journalctl -u voiceclicker-relay -f"
