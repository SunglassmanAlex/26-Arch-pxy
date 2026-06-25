#!/usr/bin/env python3
"""Static pre-board checks for the Vivado Nexys4 DDR project."""

from __future__ import annotations

import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
PROJECT = REPO_ROOT / "vivado" / "test-cpu" / "project" / "project_1.xpr"
PROJECT_DIR = PROJECT.parent

EXPECTED_PART = "xc7a100tcsg324-1"
EXPECTED_TOP = "basys3_top"

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


def ok(name: str) -> None:
    print(f"{name} [OK]")


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

    print("Vivado pre-board source check passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
