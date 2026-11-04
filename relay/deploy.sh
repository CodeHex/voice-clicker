#!/usr/bin/env bash
# Copies the relay to a Pi over SSH and installs it there:
#
#   ./relay/deploy.sh                        # ben@voiceclicker.local
#   ./relay/deploy.sh pi@other-relay.local
#
# The Pi user needs passwordless sudo, which Raspberry Pi OS sets up for the
# first user.
set -euo pipefail
cd "$(dirname "$0")"
TARGET="${1:-ben@voiceclicker.local}"

rsync -a --delete --exclude __pycache__ --exclude tests ./ "$TARGET:voiceclicker-relay/"
ssh "$TARGET" "sudo ~/voiceclicker-relay/install.sh"
