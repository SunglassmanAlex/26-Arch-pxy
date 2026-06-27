#!/usr/bin/env python3
"""Run the Lab+ xv6 boot target and check for a console milestone."""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run make test-labplus-xv6boot, save its output, and check a boot marker."
    )
    parser.add_argument(
        "--kernel",
        default="ready-to-run/xv6/kernel.bin",
        help="Flat xv6 kernel binary passed as XV6_KERNEL.",
    )
    parser.add_argument(
        "--fs",
        default="ready-to-run/xv6/fs.img",
        help="Optional xv6 fs.img passed as XV6_FS.",
    )
    parser.add_argument(
        "--max-cycles",
        default="5000000",
        help="Cycle budget passed as XV6_MAX_CYCLES.",
    )
    parser.add_argument(
        "--vopt",
        default="",
        help="Extra emulator options passed as VOPT.",
    )
    parser.add_argument(
        "--expect",
        default="init: starting sh",
        help="Console substring required for success.",
    )
    parser.add_argument(
        "--log",
        type=Path,
        default=REPO_ROOT / "build" / "xv6" / "boot.log",
        help="Path to write combined stdout/stderr.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    kernel = Path(args.kernel)
    if not kernel.is_absolute():
        kernel = REPO_ROOT / kernel
    if not kernel.is_file():
        print(f"xv6 kernel image not found: {kernel}", file=sys.stderr)
        print(
            "prepare one with: make xv6-prepare-images XV6_SRC=/path/to/xv6-riscv",
            file=sys.stderr,
        )
        return 2

    fs_img = Path(args.fs)
    if not fs_img.is_absolute():
        fs_img = REPO_ROOT / fs_img

    log_path = args.log
    if not log_path.is_absolute():
        log_path = REPO_ROOT / log_path
    log_path.parent.mkdir(parents=True, exist_ok=True)

    cmd = [
        "make",
        "test-labplus-xv6boot",
        f"XV6_KERNEL={kernel}",
        f"XV6_FS={fs_img}",
        f"XV6_MAX_CYCLES={args.max_cycles}",
    ]
    if args.vopt:
        cmd.append(f"VOPT={args.vopt}")

    print("running:", " ".join(str(part) for part in cmd))
    with log_path.open("w", encoding="utf-8", errors="replace") as log_file:
        proc = subprocess.Popen(
            cmd,
            cwd=REPO_ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            encoding="utf-8",
            errors="replace",
        )
        assert proc.stdout is not None
        for line in proc.stdout:
            print(line, end="")
            log_file.write(line)
        rc = proc.wait()

    if rc != 0:
        print(f"xv6 boot command failed with exit code {rc}; log: {log_path}", file=sys.stderr)
        return rc

    output = log_path.read_text(encoding="utf-8", errors="replace")
    if args.expect not in output:
        print(f"xv6 boot marker not found: {args.expect!r}; log: {log_path}", file=sys.stderr)
        return 1

    print(f"xv6 boot marker found: {args.expect!r}")
    print(f"xv6 boot log written: {log_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
