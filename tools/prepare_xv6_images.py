#!/usr/bin/env python3
"""Prepare xv6 kernel.bin/fs.img artifacts for the Lab+ boot target."""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUT_DIR = REPO_ROOT / "ready-to-run" / "xv6"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Convert an xv6 kernel ELF to a flat binary and stage fs.img."
    )
    parser.add_argument(
        "--xv6-src",
        type=Path,
        help="xv6 source/build tree. Defaults kernel ELF to kernel/kernel and fs image to fs.img.",
    )
    parser.add_argument("--kernel-elf", type=Path, help="Path to xv6 kernel ELF")
    parser.add_argument("--fs-img", type=Path, help="Path to xv6 fs.img")
    parser.add_argument(
        "--objcopy",
        default=None,
        help="RISC-V objcopy executable. Auto-detects common riscv64 names if omitted.",
    )
    parser.add_argument(
        "--out-dir",
        type=Path,
        default=DEFAULT_OUT_DIR,
        help="Output directory for kernel.bin and fs.img",
    )
    return parser.parse_args()


def find_objcopy(explicit: str | None) -> str:
    candidates = [explicit] if explicit else [
        "riscv64-unknown-elf-objcopy",
        "riscv64-linux-gnu-objcopy",
    ]
    for candidate in candidates:
        if candidate and shutil.which(candidate):
            return candidate
    searched = ", ".join(candidate for candidate in candidates if candidate)
    raise SystemExit(f"RISC-V objcopy not found; tried: {searched}")


def resolve_inputs(args: argparse.Namespace) -> tuple[Path, Path | None]:
    kernel_elf = args.kernel_elf
    fs_img = args.fs_img

    if args.xv6_src is not None:
        src = args.xv6_src.resolve()
        kernel_elf = kernel_elf or (src / "kernel" / "kernel")
        fs_img = fs_img or (src / "fs.img")

    if kernel_elf is None:
        raise SystemExit("missing --kernel-elf or --xv6-src")

    kernel_elf = kernel_elf.resolve()
    if not kernel_elf.is_file():
        raise SystemExit(f"xv6 kernel ELF not found: {kernel_elf}")

    if fs_img is not None:
        fs_img = fs_img.resolve()
        if not fs_img.is_file():
            raise SystemExit(f"xv6 fs.img not found: {fs_img}")

    return kernel_elf, fs_img


def main() -> int:
    args = parse_args()
    kernel_elf, fs_img = resolve_inputs(args)
    objcopy = find_objcopy(args.objcopy)
    out_dir = args.out_dir.resolve()
    kernel_bin = out_dir / "kernel.bin"
    staged_fs = out_dir / "fs.img"

    out_dir.mkdir(parents=True, exist_ok=True)
    subprocess.run([objcopy, "-O", "binary", str(kernel_elf), str(kernel_bin)], check=True)
    print(f"xv6 kernel binary written: {kernel_bin}")

    if fs_img is not None:
        shutil.copyfile(fs_img, staged_fs)
        print(f"xv6 fs image staged: {staged_fs}")
    else:
        print("xv6 fs image not provided; boot target will use the default simple-block pattern")

    print("next command:")
    print(f"  make test-labplus-xv6boot XV6_KERNEL={kernel_bin} XV6_FS={staged_fs}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
