"""Wrapper for /dev/evo* ioctl - raw USB control transfers via kernel module."""

import errno
import fcntl
import glob
import os
import struct
import time
from typing import BinaryIO

_USBDEVFS_RESET = (ord("U") << 8) | 20

# Must match struct evo_ctrl_xfer in evo_raw.c
# Layout: u8 bRequestType, u8 bRequest, u16 wValue, u16 wIndex, u16 wLength, u8[256] data
_XFER_FMT = "<BBHHH256s"
_XFER_SIZE = struct.calcsize(_XFER_FMT)

# _IOWR('E', 0, struct evo_ctrl_xfer) - must match the kernel module's ioctl number
# ioctl encoding: dir(2) | size(14) | type(8) | nr(8)
# dir = _IOC_READ|_IOC_WRITE = 3, size = _XFER_SIZE, type = 'E' (0x45), nr = 0
_IOC_WRITE = 1
_IOC_READ = 2
_IOC_DIR = _IOC_READ | _IOC_WRITE
EVO_CTRL_TRANSFER = (_IOC_DIR << 30) | (_XFER_SIZE << 16) | (0x45 << 8) | 0

# USB Audio Class constants
REQTYPE_SET = 0x21  # Host->Device, Class, Interface
REQTYPE_GET = 0xA1  # Device->Host, Class, Interface
REQ_CUR = 0x01  # SET_CUR / GET_CUR


def ctrl_transfer(
    fd: BinaryIO,
    bRequestType: int,
    bRequest: int,
    wValue: int,
    wIndex: int,
    data: bytes = b"",
    length: int | None = None,
) -> bytes | None:
    """Send a USB control transfer via the evo_raw kernel module.

    For SET (OUT) transfers, pass data bytes. length is inferred from data.
    For GET (IN) transfers, pass length (number of bytes to read). Returns bytes.
    """
    if bRequestType & 0x80:  # IN transfer
        wLength = length if length is not None else 0
        payload = b"\x00" * 256
    else:  # OUT transfer
        wLength = len(data)
        payload = data.ljust(256, b"\x00")

    buf = bytearray(
        struct.pack(_XFER_FMT, bRequestType, bRequest, wValue, wIndex, wLength, payload)
    )

    fcntl.ioctl(fd, EVO_CTRL_TRANSFER, buf)

    if bRequestType & 0x80:
        _, _, _, _, resp_len, resp_data = struct.unpack(_XFER_FMT, buf)
        return bytes(resp_data[:resp_len])
    return None


def open_device(dev_path: str) -> BinaryIO:
    """Open /dev/evo* for ioctl access. Use as context manager."""
    return open(dev_path, "rb")


def get_cur(fd: BinaryIO, wValue: int, wIndex: int, length: int) -> bytes:
    """GET_CUR request - read value"""
    result = ctrl_transfer(fd, REQTYPE_GET, REQ_CUR, wValue, wIndex, length=length)
    if result is None:
        raise RuntimeError("GET_CUR transfer returned no data")
    return result


def set_cur(fd: BinaryIO, wValue: int, wIndex: int, data: bytes) -> None:
    """SET_CUR request - write value"""
    ctrl_transfer(fd, REQTYPE_SET, REQ_CUR, wValue, wIndex, data=data)


def reset_usb_device(usb_pid: int = 0x0007) -> bool:
    """Perform a USBDEVFS_RESET on the Audient EVO USB device to clear control pipe stalls."""
    pid_hex = f"{usb_pid:04x}"
    for p in glob.glob("/sys/bus/usb/devices/*/idProduct"):
        d = os.path.dirname(p)
        try:
            vid = open(os.path.join(d, "idVendor")).read().strip().lower()
            pid = open(os.path.join(d, "idProduct")).read().strip().lower()
            if vid == "2708" and pid == pid_hex:
                bus = int(open(os.path.join(d, "busnum")).read().strip())
                dev = int(open(os.path.join(d, "devnum")).read().strip())
                usb_path = f"/dev/bus/usb/{bus:03d}/{dev:03d}"
                with open(usb_path, "wb") as ufd:
                    fcntl.ioctl(ufd, _USBDEVFS_RESET, 0)
                time.sleep(0.5)
                return True
        except OSError:
            continue
    return False
