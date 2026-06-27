#!/usr/bin/env python3
"""Run the Lab+ xv6 boot target and check for a console milestone."""

from __future__ import annotations

import argparse
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
ANSI_RE = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
TIMER_RE = re.compile(r"now = [0-9]+s\s*")


def normalize_output(output: str) -> str:
    """Remove emulator status noise that can interleave with UART bytes."""
    output = ANSI_RE.sub("", output)
    output = TIMER_RE.sub("", output)
    return output.replace("\r", "")


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
        default="420000000",
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
    parser.add_argument(
        "--no-early-stop",
        action="store_true",
        help="Keep running until the emulator exits even after the expected marker appears.",
    )
    return parser.parse_args()


def stop_process_tree(proc: subprocess.Popen[str]) -> None:
    """Stop the emulator after the requested marker is observed."""
    if proc.poll() is not None:
        return
    if os.name == "posix":
        descendants = collect_descendants(proc.pid)
        if descendants:
            for pid in reversed(descendants):
                try:
                    os.kill(pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                except OSError:
                    pass
            return
        try:
            os.killpg(proc.pid, signal.SIGTERM)
            return
        except ProcessLookupError:
            return
        except OSError:
            pass
    proc.terminate()


def read_child_pids(pid: int) -> list[int]:
    children_path = Path("/proc") / str(pid) / "task" / str(pid) / "children"
    try:
        text = children_path.read_text(encoding="ascii")
    except OSError:
        return []
    return [int(value) for value in text.split() if value.isdigit()]


def collect_descendants(pid: int) -> list[int]:
    descendants: list[int] = []
    seen: set[int] = set()
    stack = read_child_pids(pid)
    while stack:
        child = stack.pop()
        if child in seen:
            continue
        seen.add(child)
        descendants.append(child)
        stack.extend(read_child_pids(child))
    return descendants


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
    cmd = [
        "make",
        "test-labplus-xv6boot",
        f"XV6_KERNEL={kernel}",
        f"XV6_FS={fs_img}",
        f"XV6_MAX_CYCLES={args.max_cycles}",
    ]
    if args.vopt:
        cmd.append(f"VOPT={args.vopt}")

    tmp_fd, tmp_name = tempfile.mkstemp(prefix="xv6-boot-", suffix=".log")
    tmp_path = Path(tmp_name)

    early_stop = not args.no_early_stop
    marker_found = False
    output_parts: list[str] = []

    print("running:", " ".join(str(part) for part in cmd))
    try:
        with open(tmp_fd, "w", encoding="utf-8", errors="replace") as log_file:
            proc = subprocess.Popen(
                cmd,
                cwd=REPO_ROOT,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                encoding="utf-8",
                errors="replace",
                start_new_session=(os.name == "posix"),
            )
            assert proc.stdout is not None
            for line in proc.stdout:
                print(line, end="")
                log_file.write(line)
                output_parts.append(line)
                if (
                    early_stop
                    and not marker_found
                    and args.expect in normalize_output("".join(output_parts))
                ):
                    marker_found = True
                    msg = f"xv6 boot marker observed early: {args.expect!r}; stopping emulator\n"
                    print(msg, end="")
                    log_file.write(msg)
                    log_file.flush()
                    stop_process_tree(proc)
            rc = proc.wait()

        log_path.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(tmp_path), str(log_path))
    finally:
        if tmp_path.exists():
            tmp_path.unlink()

    output = normalize_output(log_path.read_text(encoding="utf-8", errors="replace"))
    marker_found = marker_found or (args.expect in output)

    if rc != 0 and not marker_found:
        print(f"xv6 boot command failed with exit code {rc}; log: {log_path}", file=sys.stderr)
        return rc

    if not marker_found:
        print(f"xv6 boot marker not found: {args.expect!r}; log: {log_path}", file=sys.stderr)
        return 1

    print(f"xv6 boot marker found: {args.expect!r}")
    print(f"xv6 boot log written: {log_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
