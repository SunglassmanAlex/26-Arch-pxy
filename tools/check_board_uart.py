#!/usr/bin/env python3
"""Read the Nexys4 DDR UART and wait for an expected board output string."""

from __future__ import annotations

import argparse
import os
import select
import sys
import termios
import time


BAUD_RATES = {
    9600: termios.B9600,
    19200: termios.B19200,
    38400: termios.B38400,
    57600: termios.B57600,
    115200: termios.B115200,
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Capture board UART output and wait for an expected string."
    )
    parser.add_argument("--port", required=True, help="Serial device, e.g. /dev/ttyUSB1")
    parser.add_argument("--baud", type=int, default=9600, choices=sorted(BAUD_RATES))
    parser.add_argument("--timeout", type=float, default=10.0, help="Seconds to wait")
    parser.add_argument(
        "--expect",
        default="Hello World!",
        help="Expected substring. Backslash escapes such as \\r\\n are accepted.",
    )
    return parser.parse_args()


def escaped_bytes(text: str) -> bytes:
    return text.encode("utf-8").decode("unicode_escape").encode("latin1")


def configure_serial(fd: int, baud: int) -> list:
    old_attrs = termios.tcgetattr(fd)
    attrs = termios.tcgetattr(fd)
    baud_flag = BAUD_RATES[baud]

    attrs[0] = 0
    attrs[1] = 0
    attrs[2] = baud_flag | termios.CS8 | termios.CREAD | termios.CLOCAL
    attrs[3] = 0
    attrs[4] = baud_flag
    attrs[5] = baud_flag
    attrs[6][termios.VMIN] = 0
    attrs[6][termios.VTIME] = 0

    termios.tcsetattr(fd, termios.TCSANOW, attrs)
    termios.tcflush(fd, termios.TCIFLUSH)
    return old_attrs


def main() -> int:
    args = parse_args()
    expected = escaped_bytes(args.expect)
    deadline = time.monotonic() + args.timeout
    captured = bytearray()

    try:
        fd = os.open(args.port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    except OSError as exc:
        print(f"failed to open {args.port}: {exc}", file=sys.stderr)
        return 2

    old_attrs = None
    try:
        old_attrs = configure_serial(fd, args.baud)
        print(
            f"listening on {args.port} at {args.baud} baud, waiting for {expected!r}",
            file=sys.stderr,
        )

        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                print(
                    f"timed out waiting for {expected!r}; captured {bytes(captured)!r}",
                    file=sys.stderr,
                )
                return 1

            readable, _, _ = select.select([fd], [], [], remaining)
            if not readable:
                continue

            chunk = os.read(fd, 4096)
            if not chunk:
                continue

            captured.extend(chunk)
            sys.stdout.buffer.write(chunk)
            sys.stdout.buffer.flush()

            if expected in captured:
                print(f"\nmatched {expected!r}", file=sys.stderr)
                return 0
    finally:
        if old_attrs is not None:
            termios.tcsetattr(fd, termios.TCSANOW, old_attrs)
        os.close(fd)


if __name__ == "__main__":
    raise SystemExit(main())
