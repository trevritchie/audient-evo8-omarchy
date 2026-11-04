#!/usr/bin/env bash
# install.sh — Audient EVO 8 full installer for Omarchy Linux
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> [1/5] Installing Python package (evoctl, evotui)..."
uv tool install --editable "$REPO_DIR/audient-evo-py" --with pytest --with numpy --with sounddevice --force

echo "==> [2/5] Installing CLI & setup scripts to ~/.local/bin..."
mkdir -p ~/.local/bin
cp "$REPO_DIR/bin/evo8-audio" ~/.local/bin/evo8-audio
cp "$REPO_DIR/pipewire/evo8-setup.sh" ~/.local/bin/evo8-setup.sh
chmod +x ~/.local/bin/evo8-audio ~/.local/bin/evo8-setup.sh

echo "==> [3/5] Installing PipeWire, WirePlumber, and systemd user units..."
mkdir -p ~/.config/wireplumber/wireplumber.conf.d
mkdir -p ~/.config/pipewire/pipewire.conf.d
mkdir -p ~/.config/systemd/user
cp "$REPO_DIR/pipewire/51-evo8.conf" ~/.config/wireplumber/wireplumber.conf.d/51-evo8.conf
cp "$REPO_DIR/pipewire/evo8-stereo.conf" ~/.config/pipewire/pipewire.conf.d/evo8-stereo.conf
cp "$REPO_DIR/pipewire/evo8-setup.service" ~/.config/systemd/user/evo8-setup.service
cp "$REPO_DIR/pipewire/evo8-load-config.service" ~/.config/systemd/user/evo8-load-config.service
systemctl --user daemon-reload
systemctl --user enable evo8-setup.service evo8-load-config.service

echo "==> [4/5] Installing Omarchy Quickshell plugin (tbird.evo8)..."
mkdir -p ~/.config/omarchy/plugins/tbird.evo8
cp -r "$REPO_DIR/plugin/tbird.evo8/"* ~/.config/omarchy/plugins/tbird.evo8/
if command -v omarchy-shell >/dev/null 2>&1; then
    omarchy-shell shell rescanPlugins || true
fi

echo "==> [5/5] Applying EVO 8 hardware setup..."
~/.local/bin/evo8-setup.sh
echo "==> Done! Run 'evo8-audio status' or click the EVO 8 icon in the Omarchy bar."
