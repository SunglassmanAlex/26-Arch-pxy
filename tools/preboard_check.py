#!/usr/bin/env python3
"""Static pre-board checks for the Vivado Nexys4 DDR project."""

from __future__ import annotations

import re
import sys
import xml.etree.ElementTree as ET
import hashlib
from datetime import datetime
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
PROJECT = REPO_ROOT / "vivado" / "test-cpu" / "project" / "project_1.xpr"
PROJECT_DIR = PROJECT.parent
IMPL_DIR = PROJECT_DIR / "project_1.runs" / "impl_1"

EXPECTED_PART = "xc7a100tcsg324-1"
EXPECTED_TOP = "basys3_top"
MIN_BITSTREAM_SIZE = 1024 * 1024

REQUIRED_FILESET_PATHS = {
    "sources_1": [
        "../../src/with_delay/bram_wrapper.sv",
        "../../src/with_delay/cbus_crossbar.sv",
        "../../src/device.svh",
        "../../src/device.sv",
        "../../src/with_delay/soc_top.sv",
        "../../src/with_delay/basys3_top.sv",
        "../../../ready-to-run/lab3/lab3-test.coe",
    ],
    "constrs_1": [
        "../../src/Basys-3-Master.xdc",
    ],
    "sim_1": [
        "../../src/with_delay/simtop.sv",
    ],
    "bram_0": [
        "../src/ip/bram_0/bram_0.xci",
    ],
    "clk_wiz_0": [
        "../src/ip/clk_wiz_0/clk_wiz_0.xci",
    ],
}

REQUIRED_XDC_PINS = {
    "clk": "E3",
    "btnC": "N17",
    "sw[0]": "J15",
    "sw[1]": "L16",
    "sw[2]": "M13",
    "sw[3]": "R15",
    "led[0]": "H17",
    "led[1]": "K15",
    "led[2]": "J13",
    "led[3]": "N14",
    "RsTx": "D4",
    "RsRx": "C4",
}

IMPLEMENTATION_ARTIFACTS = {
    "bitstream": IMPL_DIR / "basys3_top.bit",
    "route_status": IMPL_DIR / "basys3_top_route_status.rpt",
    "drc_routed": IMPL_DIR / "basys3_top_drc_routed.rpt",
    "timing_summary": IMPL_DIR / "basys3_top_timing_summary_routed.rpt",
}


def ok(name: str) -> None:
    print(f"{name} [OK]")


def info(name: str, message: str) -> None:
    print(f"{name} [INFO] {message}")


def fail(name: str, message: str) -> None:
    print(f"{name} [FAIL] {message}", file=sys.stderr)
    raise SystemExit(1)


def require(condition: bool, name: str, message: str) -> None:
    if not condition:
        fail(name, message)
    ok(name)


def resolve_vivado_path(raw_path: str) -> Path:
    path = raw_path.replace("$PPRDIR", str(PROJECT_DIR))
    path = path.replace("$PSRCDIR", str(PROJECT_DIR / "project_1.srcs"))
    path = path.replace("$PRUNDIR", str(PROJECT_DIR / "project_1.runs"))
    return Path(path).resolve()


def fileset(root: ET.Element, name: str) -> ET.Element:
    node = root.find(f".//FileSet[@Name='{name}']")
    if node is None:
        fail(f"vivado_fileset_{name}", "missing fileset")
    return node


def files_in(fileset_node: ET.Element) -> dict[Path, str]:
    result = {}
    for node in fileset_node.findall("./File"):
        raw = node.attrib.get("Path", "")
        if raw:
            result[resolve_vivado_path(raw)] = raw
    return result


def fileset_top(fileset_node: ET.Element) -> str | None:
    node = fileset_node.find("./Config/Option[@Name='TopModule']")
    return None if node is None else node.attrib.get("Val")


def xdc_has_pin(xdc_text: str, port: str, pin: str) -> bool:
    port_pattern = re.escape(port)
    pattern = rf"PACKAGE_PIN\s+{re.escape(pin)}\b.*get_ports\s+\{{?{port_pattern}\}}?"
    return re.search(pattern, xdc_text) is not None


def parse_timing_wns(timing_text: str) -> float | None:
    for line in timing_text.splitlines():
        match = re.match(r"\s*(-?\d+\.\d+)\s+(-?\d+\.\d+)\s+\d+\s+\d+", line)
        if match:
            return float(match.group(1))
    return None


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main() -> int:
    require(PROJECT.exists(), "vivado_project_exists", str(PROJECT))

    root = ET.parse(PROJECT).getroot()
    part = root.find("./Configuration/Option[@Name='Part']")
    require(
        part is not None and part.attrib.get("Val") == EXPECTED_PART,
        "vivado_project_part_nexys4",
        f"expected {EXPECTED_PART}",
    )

    for set_name, relative_paths in REQUIRED_FILESET_PATHS.items():
        node = fileset(root, set_name)
        present = files_in(node)
        for relative in relative_paths:
            resolved = (PROJECT_DIR / relative).resolve()
            require(
                resolved in present,
                f"vivado_{set_name}_{Path(relative).name}_listed",
                f"missing {relative}",
            )
            require(
                resolved.exists(),
                f"vivado_{set_name}_{Path(relative).name}_exists",
                str(resolved),
            )

    top = fileset_top(fileset(root, "sources_1"))
    require(
        top == EXPECTED_TOP,
        "vivado_synth_top_wrapper",
        f"expected {EXPECTED_TOP}, got {top}",
    )

    top_file = (REPO_ROOT / "vivado" / "src" / "with_delay" / "basys3_top.sv")
    top_text = top_file.read_text(encoding="utf-8")
    require(
        re.search(r"\bmodule\s+nexys4_top\b", top_text) is not None,
        "vivado_nexys4_top_defined",
        "missing nexys4_top module",
    )
    require(
        re.search(r"\bmodule\s+basys3_top\b", top_text) is not None
        and "nexys4_top u_nexys4_top" in top_text,
        "vivado_basys3_compat_wrapper",
        "missing basys3_top wrapper around nexys4_top",
    )

    xdc_file = (REPO_ROOT / "vivado" / "src" / "Basys-3-Master.xdc")
    xdc_text = xdc_file.read_text(encoding="utf-8")
    require(
        "Nexys4 DDR" in xdc_text and EXPECTED_PART in xdc_text,
        "vivado_xdc_nexys4_header",
        "missing Nexys4 DDR header/part",
    )
    for port, pin in REQUIRED_XDC_PINS.items():
        require(
            xdc_has_pin(xdc_text, port, pin),
            f"vivado_xdc_pin_{port.replace('[', '_').replace(']', '')}",
            f"expected {port} on {pin}",
        )

    bitstream = IMPLEMENTATION_ARTIFACTS["bitstream"]
    require(bitstream.exists(), "vivado_bitstream_exists", str(bitstream))
    require(
        bitstream.stat().st_size >= MIN_BITSTREAM_SIZE,
        "vivado_bitstream_size",
        f"{bitstream.stat().st_size} bytes",
    )
    bitstream_stat = bitstream.stat()
    info(
        "vivado_bitstream_manifest",
        "path={} size={} mtime={} sha256={}".format(
            bitstream.relative_to(REPO_ROOT),
            bitstream_stat.st_size,
            datetime.fromtimestamp(bitstream_stat.st_mtime).astimezone().isoformat(
                sep=" ", timespec="seconds"
            ),
            sha256_file(bitstream),
        ),
    )
    bin_files = sorted(IMPL_DIR.glob("*.bin"))
    if bin_files:
        info(
            "vivado_flash_bin",
            "found " + ", ".join(str(path.relative_to(REPO_ROOT)) for path in bin_files),
        )
    else:
        info("vivado_flash_bin", "not found; program .bit or regenerate flash image")

    route_report = IMPLEMENTATION_ARTIFACTS["route_status"]
    require(route_report.exists(), "vivado_route_report_exists", str(route_report))
    route_text = route_report.read_text(encoding="utf-8", errors="replace")
    require(
        re.search(r"# of nets with routing errors\.+\s*:\s*0\s*:", route_text) is not None,
        "vivado_route_errors_zero",
        "route report does not show zero routing errors",
    )

    drc_report = IMPLEMENTATION_ARTIFACTS["drc_routed"]
    require(drc_report.exists(), "vivado_drc_report_exists", str(drc_report))
    drc_text = drc_report.read_text(encoding="utf-8", errors="replace")
    require(
        "Violations found: 0" in drc_text,
        "vivado_drc_violations_zero",
        "routed DRC report has violations",
    )

    timing_report = IMPLEMENTATION_ARTIFACTS["timing_summary"]
    require(timing_report.exists(), "vivado_timing_report_exists", str(timing_report))
    timing_text = timing_report.read_text(encoding="utf-8", errors="replace")
    wns = parse_timing_wns(timing_text)
    require(
        wns is not None and wns >= 0.0,
        "vivado_timing_wns_nonnegative",
        f"WNS={wns}",
    )
    info("vivado_timing_manifest", f"WNS={wns} ns")
    require(
        "All user specified timing constraints are met." in timing_text,
        "vivado_timing_constraints_met",
        "timing summary does not report timing met",
    )

    print("Vivado pre-board check passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
