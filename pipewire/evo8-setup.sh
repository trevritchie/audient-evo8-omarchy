#!/usr/bin/env bash
# EVO 8 Audio Setup — configures 6-channel profile, hardware mixer defaults,
# and sets EVO 8 stereo nodes as default PipeWire devices.
#
# Install: ~/.local/bin/evo8-setup.sh

set -euo pipefail

export PATH="$HOME/.local/bin:$PATH"

CARD="alsa_card.usb-Audient_EVO8-00"
PROFILE="output:analog-surround-51+input:analog-surround-51"
HW_SINK="alsa_output.usb-Audient_EVO8-00.analog-surround-51"
HW_SOURCE="alsa_input.usb-Audient_EVO8-00.analog-surround-51"
SINK="evo8_main_output"
SOURCE="evo8_mic_1_2"
CONFIG_FILE="$HOME/.config/audient-evo-py/evo8/config.json"

# Wait briefly for PipeWire/WirePlumber graph to settle if called on hotplug/login
for _ in {1..10}; do
    if pactl list cards short 2>/dev/null | grep -q "$CARD"; then
        break
    fi
    sleep 0.5
done

if ! pactl list cards short 2>/dev/null | grep -q "$CARD"; then
    echo "EVO 8 not connected ($CARD not found)."
    exit 0
fi

# 1. Force 6-channel surround-5.1 profile so CH1-6 playback & capture are active
pactl set-card-profile "$CARD" "$PROFILE" 2>/dev/null || true

# 2. Keep the underlying 6ch PipeWire hardware sink/source at 100% unity gain
#    so individual virtual sinks and hardware FU10/MU60 control actual loudness
pactl set-sink-mute "$HW_SINK" 0 2>/dev/null || true
pactl set-sink-volume "$HW_SINK" 100% 2>/dev/null || true
pactl set-source-mute "$HW_SOURCE" 0 2>/dev/null || true
pactl set-source-volume "$HW_SOURCE" 100% 2>/dev/null || true

# 3. Ensure ALSA FU10 loopback playback channels (CH5/6) are unmuted (254 = 0 dB)
#    and apply saved or baseline hardware DSP mixer config
if [[ -e /dev/evo8 ]] && command -v evoctl >/dev/null 2>&1; then
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "Initializing default EVO 8 hardware mixer configuration..."
        out2_vol=$(evoctl -d evo8 get volume -t output2 2>/dev/null | grep -oE '[-0-9.]+' | head -1 || echo "-20")
        if (( $(awk "BEGIN {print ($out2_vol < -90)}") )); then
            evoctl -d evo8 set volume -20 -t output2 || true
        fi
        # Route PC Main 1+2 -> MIX 1|2 at 0 dB
        evoctl -d evo8 mixer output1_2 --volume 0 --mix-output 0
        # Route PC Out 3+4 -> MIX 3|4 at 0 dB
        evoctl -d evo8 mixer output3_4 --volume 0 --mix-output 1
        # Route Loopback Out 5+6 -> MIX 1|2 at 0 dB
        evoctl -d evo8 mixer output5_6 --volume 0 --mix-output 0
        evoctl -d evo8 save "$CONFIG_FILE"
    else
        evoctl -d evo8 load "$CONFIG_FILE" || true
    fi
fi

# 4. Set default sink and source by exact node name
pactl set-default-sink "$SINK" 2>/dev/null || true
pactl set-default-source "$SOURCE" 2>/dev/null || true
echo "Default sink: $SINK | Default source: $SOURCE"
