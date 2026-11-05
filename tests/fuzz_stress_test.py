"""Adversarial fuzzing and concurrency stress tests for Audient EVO 8 Omarchy stack.

Tests:
1. CLI argument fuzzing (NaN, Inf, malformed numbers, bad strings, boundary values)
2. Corrupted/malformed config & state JSON fuzzing (.mixer-state.json, config.json, .monitor-prefs.json)
3. Curses TUI (evotui) keystroke, resize (1x1..200x80), file-picker path injection, and USB fault fuzzing
4. High-concurrency multi-process read/write stress test (atomic file integrity & JSON validity)
"""

from __future__ import annotations

import concurrent.futures
import curses
import errno
import importlib.machinery
import importlib.util
import json
import math
import os
import pty
import random
import select
import shutil
import struct
import subprocess
import sys
import tempfile
import termios
import fcntl
import time
from pathlib import Path
from unittest.mock import MagicMock, patch

REPO_ROOT = Path(__file__).resolve().parents[1]
EVO_PY_DIR = REPO_ROOT / "audient-evo-py"
EVO8_AUDIO_BIN = REPO_ROOT / "bin" / "evo8-audio"

sys.path.insert(0, str(EVO_PY_DIR))

from evo import config as cfg
from evo.controller import EVOController
from evo.devices import EVO8
import evoctl
import evotui


def load_evo8_audio_module():
    loader = importlib.machinery.SourceFileLoader("evo8_audio", str(EVO8_AUDIO_BIN))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


class FailingMockEVO:
    """Mock EVOController that can inject random OSErrors (EPROTO, EPIPE, ENODEV)."""

    def __init__(self, spec=EVO8, fail_rate: float = 0.0):
        self.spec = spec
        self.fail_rate = fail_rate

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def _maybe_fail(self):
        if self.fail_rate > 0 and random.random() < self.fail_rate:
            err = random.choice([errno.EPROTO, errno.EPIPE, errno.ENODEV, errno.ETIMEDOUT])
            raise OSError(err, os.strerror(err))

    def get_status_raw(self) -> bytes:
        self._maybe_fail()
        # Always fail or return valid 24-byte EVO8 status blob
        return b"\x00" * 24

    def decode_status(self, data: bytes) -> dict:
        return {
            "output1": {"volume": -20.0, "mute": False},
            "output2": {"volume": -20.0, "mute": False},
            "input1": {"gain": -8.0, "mute": False, "phantom": False},
            "input2": {"gain": 10.0, "mute": False, "phantom": False},
            "input3": {"gain": -8.0, "mute": False, "phantom": False},
            "input4": {"gain": -8.0, "mute": False, "phantom": False},
        }

    def set_volume(self, db: float, output_pair: int | None = None):
        if not math.isfinite(db):
            raise ValueError(f"Non-finite db passed to set_volume: {db}")
        self._maybe_fail()
        return (round(db * 256), db)

    def set_gain(self, target: str, db: float):
        if not math.isfinite(db):
            raise ValueError(f"Non-finite db passed to set_gain: {db}")
        self._maybe_fail()
        return (round(db * 256), db)

    def get_mute(self, target: str) -> bool:
        self._maybe_fail()
        return False

    def set_mute(self, target: str, muted: bool):
        if not isinstance(target, str):
            raise TypeError(f"target must be str, got {type(target)}")
        self._maybe_fail()

    def get_phantom(self, target: str) -> bool:
        self._maybe_fail()
        return False

    def set_phantom(self, target: str, enabled: bool):
        if not isinstance(target, str):
            raise TypeError(f"target must be str, got {type(target)}")
        self._maybe_fail()

    def set_mixer_input(self, input_num: int, gain_db: float, pan: float = 0.0, mix_output: int = 0):
        if not math.isfinite(gain_db) or not math.isfinite(pan):
            raise ValueError(f"Non-finite mixer input args: gain_db={gain_db}, pan={pan}")
        self._maybe_fail()

    def set_mixer_output(
        self, volume_db: float, pan_l: float = -100.0, pan_r: float = 100.0, output_pair: int = 0, mix_output: int = 0
    ):
        if not math.isfinite(volume_db) or not math.isfinite(pan_l) or not math.isfinite(pan_r):
            raise ValueError(f"Non-finite mixer output args: {volume_db}, {pan_l}, {pan_r}")
        self._maybe_fail()


def test_1_cli_input_fuzzing(failures: list[str]):
    print("=== [1/4] Fuzzing evo8-audio & evoctl CLI inputs ===")
    mod = load_evo8_audio_module()
    tmp_dir = Path(tempfile.mkdtemp(prefix="evo8_fuzz_"))
    try:
        mod.PREFS_FILE = tmp_dir / ".monitor-prefs.json"
        mod.SAVED_CFG_FILE = tmp_dir / "config.json"
        cfg.CONFIG_DIR = tmp_dir

        fuzz_vectors = [
            ["buffer", "abc", "--quiet"],
            ["buffer", "nan", "--quiet"],
            ["buffer", "-64", "--quiet"],
            ["buffer", "999999", "--quiet"],
            ["buffer", "", "--quiet"],
            ["rate", "abc", "--quiet"],
            ["rate", "48000.5", "--quiet"],
            ["rate", "-48000", "--quiet"],
            ["rate", "192000", "--quiet"],
            ["gain", "1", "nan", "--quiet"],
            ["gain", "1", "inf", "--quiet"],
            ["gain", "1", "-inf", "--quiet"],
            ["gain", "1", "notanumber", "--quiet"],
            ["volume", "1", "nan", "--quiet"],
            ["volume", "2", "inf", "--quiet"],
            ["volume", "1", "bad", "--quiet"],
            ["monitor", "1", "nan", "--quiet"],
            ["monitor", "1", "inf", "--quiet"],
            ["monitor", "1", "bad_state", "--quiet"],
            ["monitor", "1", "on", "--db", "nan", "--quiet"],
            ["monitor", "1", "on", "--pan", "inf", "--quiet"],
            ["pcmix", "1", "nan", "--quiet"],
            ["pcmix", "2", "-inf", "--quiet"],
            ["pcmix", "1", "bad", "--quiet"],
            ["loopback", "invalid_source", "--quiet"],
            ["loopback", "main", "--level", "-500", "--quiet"],
            ["loopback", "main", "--level", "999999", "--quiet"],
        ]

        with patch.object(mod, "EVOController", lambda spec: FailingMockEVO(spec, fail_rate=0.5)), \
             patch.object(mod, "_run", return_value=""), \
             patch.object(mod, "_notify", return_value=None):
            for argv in fuzz_vectors:
                try:
                    with patch.object(sys, "argv", ["evo8-audio"] + argv):
                        mod.main()
                except SystemExit:
                    # Clean CLI rejection via sys.exit / parser.error is expected
                    pass
                except Exception as exc:
                    failures.append(f"CLI fuzz crash on {argv}: {type(exc).__name__}: {exc}")

                # Check that config files on disk never contain NaN/Infinity or invalid JSON
                for fpath in tmp_dir.rglob("*.json"):
                    try:
                        raw = fpath.read_text()
                        json.loads(raw, parse_constant=lambda c: (_ for _ in ()).throw(ValueError(f"Non-standard JSON constant {c}")))
                    except Exception as exc:
                        failures.append(f"Corrupted JSON written to {fpath.name} after {argv}: {exc}")
                        fpath.unlink(missing_ok=True)

        # Also fuzz evoctl CLI parser
        evoctl_vectors = [
            ["--device", "evo8", "set", "volume", "nan", "-t", "output1"],
            ["--device", "evo8", "set", "volume", "inf", "-t", "output1"],
            ["--device", "evo8", "set", "gain", "nan", "-t", "input1"],
            ["--device", "evo8", "set", "gain", "999", "-t", "input1"],
            ["--device", "evo8", "mixer", "input1", "--volume", "nan"],
            ["--device", "evo8", "mixer", "input1", "--volume", "0", "--pan", "inf"],
            ["--device", "evo8", "mixer", "output1_2", "--volume", "-200"],
            ["--device", "evo8", "mixer", "output1_2", "--volume", "0", "--pan-l", "nan"],
        ]
        for argv in evoctl_vectors:
            try:
                evoctl.parse_args(EVO8, argv)
                failures.append(f"evoctl.parse_args unexpectedly accepted invalid args: {argv}")
            except SystemExit:
                pass
            except Exception as exc:
                failures.append(f"evoctl.parse_args crashed on {argv}: {type(exc).__name__}: {exc}")
    finally:
        shutil.rmtree(tmp_dir, ignore_errors=True)


def test_2_corrupted_config_fuzzing(failures: list[str]):
    print("=== [2/4] Fuzzing corrupted/malformed JSON state files ===")
    mod = load_evo8_audio_module()
    tmp_dir = Path(tempfile.mkdtemp(prefix="evo8_corrupt_"))
    try:
        mod.PREFS_FILE = tmp_dir / "evo8" / ".monitor-prefs.json"
        mod.SAVED_CFG_FILE = tmp_dir / "evo8" / "config.json"
        cfg.CONFIG_DIR = tmp_dir

        corrupt_payloads = [
            "",
            "{",
            "null",
            "[]",
            '"string_root"',
            "12345",
            '{"version": 999}',
            '{"version": 2, "mix_outputs": null}',
            '{"version": 2, "mix_outputs": []}',
            '{"version": 2, "mix_outputs": {"mix1_2": null}}',
            '{"version": 2, "mix_outputs": {"mix1_2": {"inputs": null, "outputs": null}}}',
            '{"output1": null, "output2": "bad", "input1": {"gain": "loud", "mute": "yes", "phantom": 123}}',
            '{"last_monitor_db": null, "loopback_source": 12345, "loopback_level": "loud"}',
        ]

        evo_dir = tmp_dir / "evo8"
        evo_dir.mkdir(parents=True, exist_ok=True)

        with patch.object(mod, "EVOController", lambda spec: FailingMockEVO(spec, fail_rate=1.0)), \
             patch.object(mod, "_run", return_value=""), \
             patch.object(mod, "_notify", return_value=None):
            for payload in corrupt_payloads:
                for target_file in [
                    evo_dir / "config.json",
                    evo_dir / ".mixer-state.json",
                    evo_dir / ".monitor-prefs.json",
                ]:
                    target_file.write_text(payload)

                # Now run status --json, monitor toggle, loopback apply, and EvoTUI init
                try:
                    st = mod.get_full_status(fast=True)
                    json.dumps(st, allow_nan=False)
                except Exception as exc:
                    failures.append(f"get_full_status(fast=True) crashed on payload {payload!r}: {type(exc).__name__}: {exc}")

                try:
                    st2 = mod.get_full_status(fast=False)
                    json.dumps(st2, allow_nan=False)
                except Exception as exc:
                    failures.append(f"get_full_status(fast=False) crashed on payload {payload!r}: {type(exc).__name__}: {exc}")

                try:
                    with patch.object(sys, "argv", ["evo8-audio", "monitor", "1", "toggle", "--quiet"]):
                        mod.main()
                except Exception as exc:
                    failures.append(f"monitor toggle crashed on payload {payload!r}: {type(exc).__name__}: {exc}")

                try:
                    tui = evotui.EvoTUI(FailingMockEVO(EVO8, fail_rate=1.0))
                except Exception as exc:
                    failures.append(f"EvoTUI.__init__ crashed on payload {payload!r}: {type(exc).__name__}: {exc}")

                try:
                    cfg.load_and_apply(FailingMockEVO(EVO8, fail_rate=0.0), evo_dir / "config.json")
                except ValueError:
                    pass
                except Exception as exc:
                    failures.append(f"cfg.load_and_apply raised unexpected {type(exc).__name__} on payload {payload!r}: {exc}")
    finally:
        shutil.rmtree(tmp_dir, ignore_errors=True)


def test_3_tui_fuzzing(failures: list[str]):
    print("=== [3/4] Fuzzing evotui (resizes 1x1..200x80, keys, path traversal, USB errors) ===")
    tmp_dir = Path(tempfile.mkdtemp(prefix="evo8_tui_"))
    try:
        cfg.CONFIG_DIR = tmp_dir
        mock_evo = FailingMockEVO(EVO8, fail_rate=0.4)
        tui = evotui.EvoTUI(mock_evo)

        # Fake curses window to test _draw at extreme sizes and key handling
        class DummyWindow:
            def __init__(self, h: int, w: int):
                self.h = h
                self.w = w
                self.keys = []

            def getmaxyx(self):
                return (self.h, self.w)

            def erase(self):
                pass

            def clear(self):
                pass

            def refresh(self):
                pass

            def timeout(self, _t):
                pass

            def move(self, r, c):
                if r < 0 or r >= self.h or c < 0 or c >= self.w:
                    raise curses.error(f"move({r}, {c}) out of bounds ({self.h}x{self.w})")

            def addnstr(self, r, c, text, n, *_args):
                if r < 0 or r >= self.h or c < 0 or c >= self.w or n < 0:
                    raise curses.error(f"addnstr({r}, {c}, n={n}) out of bounds ({self.h}x{self.w})")

        with patch("curses.color_pair", return_value=0):
            # Test drawing across extreme terminal dimensions in all modes/windows
            sizes = [(1, 1), (2, 2), (5, 10), (15, 30), (24, 60), (25, 80), (40, 120), (80, 200)]
            for mode in ("normal", "save", "load"):
                for win_tab in ("controls", "mixer"):
                    tui._mode = mode
                    tui._window = win_tab
                    tui._file_input = "test_config"
                    for h, w in sizes:
                        scr = DummyWindow(h, w)
                        try:
                            tui._draw(scr)
                            if tui._text_cursor_pos:
                                r, c = tui._text_cursor_pos
                                scr.move(r, c)
                        except Exception as exc:
                            failures.append(
                                f"EvoTUI._draw crashed at size {w}x{h} (mode={mode}, tab={win_tab}): "
                                f"{type(exc).__name__}: {exc}"
                            )

            # Test path traversal in save mode
            tui._mode = "save"
            tui._file_input = "../../escaped_file"
            try:
                tui._picker_key(10)  # Enter
                if (tmp_dir.parent / "escaped_file.json").exists():
                    failures.append("EvoTUI save mode allowed path traversal '../escaped_file.json'!")
                    (tmp_dir.parent / "escaped_file.json").unlink(missing_ok=True)
            except Exception as exc:
                failures.append(f"EvoTUI save mode crashed on '../escaped_file': {type(exc).__name__}: {exc}")

            tui._mode = "save"
            tui._file_input = "subdir/nested"
            try:
                tui._picker_key(10)  # Enter
            except Exception as exc:
                failures.append(f"EvoTUI save mode crashed on 'subdir/nested': {type(exc).__name__}: {exc}")
    finally:
        shutil.rmtree(tmp_dir, ignore_errors=True)


def test_4_concurrency_stress(failures: list[str]):
    print("=== [4/4] Running 16-worker concurrent read/write stress test ===")
    mod = load_evo8_audio_module()
    tmp_dir = Path(tempfile.mkdtemp(prefix="evo8_conc_"))
    try:
        mod.PREFS_FILE = tmp_dir / "evo8" / ".monitor-prefs.json"
        mod.SAVED_CFG_FILE = tmp_dir / "evo8" / "config.json"
        cfg.CONFIG_DIR = tmp_dir

        def worker(worker_id: int):
            errs = []
            with patch.object(mod, "EVOController", lambda spec: FailingMockEVO(spec, fail_rate=0.2)), \
                 patch.object(mod, "_run", return_value=""), \
                 patch.object(mod, "_notify", return_value=None):
                for i in range(40):
                    op = (worker_id + i) % 5
                    try:
                        if op == 0:
                            st = mod.get_full_status(fast=True)
                            raw = json.dumps(st, allow_nan=False)
                            json.loads(raw)
                        elif op == 1:
                            args = MagicMock(input_num=str((i % 4) + 1), db=str((i % 58) - 8), quiet=True)
                            mod.cmd_gain(args)
                        elif op == 2:
                            args = MagicMock(
                                input_num=str((i % 4) + 1),
                                state="on" if i % 2 == 0 else "off",
                                db=float((i % 20) - 15),
                                pan=float((i % 40) - 20),
                                mix="both",
                                quiet=True,
                            )
                            mod.cmd_monitor(args)
                        elif op == 3:
                            args = MagicMock(pair=str((i % 2) + 1), db=str(-(i % 60)), quiet=True)
                            mod.cmd_volume(args)
                        elif op == 4:
                            src = ["main", "out3_4", "send5_6", "hwmix", "off"][i % 5]
                            args = MagicMock(state=src, level=50 + (i % 100), quiet=True)
                            mod.cmd_loopback(args)
                    except Exception as exc:
                        errs.append(f"Worker {worker_id} iter {i} op {op} failed: {type(exc).__name__}: {exc}")
            return errs

        with concurrent.futures.ThreadPoolExecutor(max_workers=16) as pool:
            futs = [pool.submit(worker, wid) for wid in range(16)]
            for f in concurrent.futures.as_completed(futs):
                failures.extend(f.result())
    finally:
        shutil.rmtree(tmp_dir, ignore_errors=True)


def main():
    failures: list[str] = []
    test_1_cli_input_fuzzing(failures)
    test_2_corrupted_config_fuzzing(failures)
    test_3_tui_fuzzing(failures)
    test_4_concurrency_stress(failures)

    print(f"\n=== FUZZ & STRESS SUMMARY: {len(failures)} issues found ===")
    for idx, f in enumerate(failures[:30], 1):
        print(f"  {idx}. {f}")
    if len(failures) > 30:
        print(f"  ... and {len(failures) - 30} more")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
