# Audient EVO 8 on Omarchy Linux

Full hardware DSP mixer, zero-latency direct guitar/XLR monitoring, PipeWire 6-channel split (with dedicated stereo Loopback capture/playback nodes), dynamic buffer size / sample rate control, full terminal matrix mixer (`evotui`), and native Omarchy Quickshell bar widget plugin (`tbird.evo8`).

## Architecture & What This Solves

1. **Buffer Size & Sample Rate Control (`evo8-audio buffer` / `evo8-audio rate`)**
   - Dynamically controls PipeWire `clock.force-quantum` (`32` to `2048` samples or `auto`) and `clock.force-rate` (`44100`, `48000`, `88200`, `96000` Hz) via `pw-metadata` and the Quickshell bar widget.
2. **Hardware DSP Matrix Mixer (`MU60` 10×4 Matrix via `/dev/evo8`)**
   - Uses the `evo_raw` USB control transfer kernel module (`audient-evo-py/kmod/`) and patched `evoctl` / `evotui` to control:
     - **Inputs 1–4 Preamps (`FU11`)**: `-8.0 dB` to `+50.0 dB` hardware gain, `48V` Phantom Power (`EU58`), Input Mutes (`EU58`).
     - **Hardware Outputs (`FU10` / `EU59`)**: `OUT 1|2` (Main/HP1) & `OUT 3|4` (Line/HP2) hardware attenuation (`-96..0 dB`) and hardware mute (`EU59` `0x0100`/`0x0102`), plus automatic unmuting of `FU10` digital playback trims (`CH3–6`).
     - **10×4 Hardware Matrix Mixer (`MU60`)**: Route any combination of Mic/Guitar Inputs 1–4, USB Playback 1–4, and Loopback Playback 5–6 to `MIX 1|2` or `MIX 3|4` with independent level (`-128..+6 dB`) and stereo pan (`-100..+100`).
3. **Dedicated Stereo Loopback Recording & Playback (`pipewire/51-evo8.conf` & `evo8-stereo.conf`)**
   - Forces WirePlumber onto the 6-channel `output:analog-surround-51+input:analog-surround-51` profile (fixing WirePlumber's default 3-channel `analog-surround-21` priority collision that disabled Input 4 and Loopback 5+6) and enables `api.alsa.soft-mixer = true`.
   - Splits the 6-channel card into 6 isolated PipeWire stereo nodes (protected from EasyEffects hijacking via `node.dont-reconnect = true` and `node.dont-move = true`):
     - `evo8_main_out` (**EVO 8 Main Output 1+2**)
     - `evo8_line_3_4` (**EVO 8 Line Output 3+4**)
     - `evo8_loopback_out` (**EVO 8 Loopback Send 5+6**)
     - `evo8_mic_1_2` (**EVO 8 Mic/Inst Input 1+2**)
     - `evo8_mic_3_4` (**EVO 8 Mic Input 3+4**)
     - `evo8_loopback_in` (**EVO 8 Loopback Capture 5+6**)
4. **Zero-Latency Direct Guitar / XLR Monitoring (`evo8-audio monitor`)**
   - Toggle or adjust hardware DSP monitoring for Input 1 (JFET Instrument DI / XLR 1) and Inputs 2–4 directly in the EVO 8's internal mixer (`MU60`) without opening Reaper or any DAW.

## Quick Reference

```bash
# Show full status (or --json)
evo8-audio status

# Zero-latency direct guitar/mic monitoring on Input 1
evo8-audio monitor 1 on --db 0.0
evo8-audio monitor 1 off

# Set PipeWire buffer size (quantum) and sample rate
evo8-audio buffer 128
evo8-audio buffer auto
evo8-audio rate 48000

# Preamp gain (-8 to +50 dB) & 48V phantom power
evo8-audio gain 1 28
evo8-audio phantom 1 toggle

# Launch full 3-tab interactive TUI mixer in floating window
evo8-audio tui
```
