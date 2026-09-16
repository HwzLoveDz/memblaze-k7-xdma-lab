#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Memblaze K7 XDMA Lab contributors

"""Static publication checks for the Memblaze K7 XDMA Lab repository."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
import tarfile
import xml.etree.ElementTree as ET
from pathlib import Path
from urllib.parse import unquote


ROOT = Path(__file__).resolve().parents[1]
VENDOR_ARCHIVE = ROOT / "vendor" / "xdma_linux_kernel_b8466090.tar.gz"
VENDOR_SOURCE_MANIFEST = ROOT / "vendor" / "xdma_linux_kernel_b8466090.sha256"
RELEASE_CHECKSUMS = ROOT / "SHA256SUMS.txt"
CLEAN_BUILD_EVIDENCE = (
    "evidence/validated_repository_clean_build_vivado_2026_1_sanitized.log"
)
PHYSICAL_REGRESSION_EVIDENCE = (
    "evidence/validated_repository_exact_image_physical_regression_sanitized.log"
)
EXPECTED_VENDOR_SHA256 = (
    "aba9086b051e2e29ee6a38a0b655857010e75400d7c410340334938586be23a2"
)
EXPECTED_VENDOR_SOURCE_MANIFEST_SHA256 = (
    "5bc795735ea76a74d073d3e7b57431d8da077cdbc47bc33f4eb1d82b4a289720"
)
FPGA_SOURCE_FILES = (
    "fpga/build.tcl",
    "fpga/create_project.tcl",
    "fpga/bd/create_design.tcl",
    "fpga/constraints/board.xdc",
    "fpga/mig/memblaze_ddr3.prj",
    "fpga/program_sram.tcl",
)

REQUIRED = {
    "README.md",
    "README.zh-CN.md",
    "LICENSE",
    "THIRD_PARTY_NOTICES.md",
    "RELEASE_MANIFEST.json",
    "docs/HARDWARE_SETUP.zh-CN.md",
    "docs/NEXT_EXPERIMENTS.zh-CN.md",
    "docs/SECURE_BOOT.zh-CN.md",
    "docs/EXACT_IMAGE_REGRESSION.zh-CN.md",
    "docs/TROUBLESHOOTING.zh-CN.md",
    "docs/VALIDATED_RESULTS.zh-CN.md",
    "linux/01_probe.sh",
    "linux/02_build_driver.sh",
    "linux/03_secure_boot_status.sh",
    "linux/04_load_verify.sh",
    "linux/05_dma_smoke.sh",
    "linux/06_extended_validation.sh",
    "linux/07_release_advanced.sh",
    "linux/run_exact_image_regression.sh",
    "linux/99_cleanup.sh",
    "linux/lib/dmesg_capture.sh",
    "linux/lib/kernel_error_filter.sh",
    "linux/patches/0001-portable-kbuild.patch",
    "fpga/build.tcl",
    "fpga/create_project.tcl",
    "fpga/bd/create_design.tcl",
    "fpga/constraints/board.xdc",
    "fpga/mig/memblaze_ddr3.prj",
    "fpga/README.md",
    "fpga/program_sram.tcl",
    "tools/generate_sha256s.py",
    "tools/test_dmesg_capture.sh",
    "tools/test_exact_wrapper_reexec.sh",
    "tools/test_kernel_error_filter.sh",
    "vendor/xdma_linux_kernel_b8466090.tar.gz",
    "vendor/xdma_linux_kernel_b8466090.sha256",
    "LICENSES/GPL-2.0.txt",
    "LICENSES/Xilinx-XDMA-BSD.txt",
    "evidence/README.md",
    "evidence/historical_single_request_1g_failure_sanitized.log",
}

FORBIDDEN_SUFFIXES = {
    ".bit",
    ".bin",
    ".dcp",
    ".xpr",
    ".xci",
    ".bd",
    ".wdb",
    ".pfx",
    ".p12",
    ".priv",
    ".key",
    ".der",
    ".cer",
    ".pem",
    ".crt",
    ".csr",
    ".lic",
    ".ko",
    ".o",
    ".sys",
    ".env",
    ".pyc",
    ".pyo",
}

FORBIDDEN_DIRECTORY_NAMES = {"__pycache__", ".pytest_cache", ".mypy_cache"}
FORBIDDEN_FILE_NAMES = {
    ".env",
    "authorized_keys",
    "id_dsa",
    "id_ecdsa",
    "id_ed25519",
    "id_rsa",
    "known_hosts",
}

TEXT_SUFFIXES = {
    ".md",
    ".sh",
    ".tcl",
    ".xdc",
    ".prj",
    ".v",
    ".sv",
    ".vhd",
    ".py",
    ".json",
    ".yml",
    ".yaml",
    ".patch",
    ".txt",
    ".gitignore",
    ".gitattributes",
    ".log",
}

SENSITIVE_PATTERNS = {
    "Windows user path": re.compile(r"(?i)[A-Z]:[\\/]+Users[\\/]+[^\\/\s]+"),
    "email address": re.compile(
        r"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"
    ),
    "labeled device serial": re.compile(
        r"(?i)\b(?:USB|JTAG|DEVICE)[_ -]?SERIAL\s*[:=]\s*\S+"
    ),
    "private key": re.compile(
        r"-----BEGIN (?:[A-Z0-9]+(?: [A-Z0-9]+)* )?PRIVATE KEY-----"
    ),
    "possible SHA-256 certificate fingerprint": re.compile(
        r"(?i)\b(?:[0-9a-f]{2}:){31}[0-9a-f]{2}\b"
    ),
}

RELEASE_PLACEHOLDER_PHRASES = {
    "Unreleased",
    "pre-publication",
    "No public push should be made until every release blocker",
    "The public wiring image is still missing",
    "发布前 `v0.1.0-lab`",
    "发布阻塞项全部关闭后再公开推送",
    "接线图尚未加入",
}

def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def fpga_source_set_sha256(relative_files: tuple[str, ...]) -> str:
    """Hash each ordered UTF-8 path, NUL, exact file bytes, and a final NUL."""
    digest = hashlib.sha256()
    for relative in relative_files:
        digest.update(relative.encode("utf-8"))
        digest.update(b"\0")
        digest.update((ROOT / relative).read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()


def without_tcl_comments(text: str) -> str:
    """Remove full-line Tcl/XDC comments before checking executable statements."""
    return "\n".join(
        line for line in text.splitlines() if not line.lstrip().startswith("#")
    )


def parse_tcl_config_pairs(text: str, errors: list[str]) -> dict[str, str]:
    pairs: dict[str, str] = {}
    for name, value in re.findall(
        r"\bCONFIG\.([A-Za-z0-9_]+)\s+\{([^{}\r\n]*)\}",
        without_tcl_comments(text),
    ):
        if name in pairs and pairs[name] != value:
            errors.append(
                f"FPGA block-design generator sets CONFIG.{name} more than once "
                f"with different values: {pairs[name]!r}, {value!r}"
            )
        pairs[name] = value
    return pairs


def parse_xdc_package_pins(text: str, errors: list[str]) -> dict[str, str]:
    pins: dict[str, str] = {}
    for line in without_tcl_comments(text).splitlines():
        match = re.match(
            r"^\s*set_property\s+PACKAGE_PIN\s+(\S+)\s+"
            r"\[get_ports\s+(?:\{([^}]+)\}|([^\]\s]+))\]\s*$",
            line,
        )
        if not match:
            continue
        package_pin = match.group(1)
        port = match.group(2) or match.group(3)
        if port in pins and pins[port] != package_pin:
            errors.append(
                f"board.xdc assigns {port} to multiple pins: "
                f"{pins[port]}, {package_pin}"
            )
        pins[port] = package_pin
    package_to_ports: dict[str, list[str]] = {}
    for port, package_pin in pins.items():
        package_to_ports.setdefault(package_pin, []).append(port)
    for package_pin, ports in package_to_ports.items():
        if len(ports) > 1:
            errors.append(
                f"board.xdc assigns package pin {package_pin} to multiple ports: "
                f"{', '.join(sorted(ports))}"
            )
    return pins


def parse_evidence_key_values(path: Path, errors: list[str]) -> dict[str, str]:
    values: dict[str, str] = {}
    for line_number, line in enumerate(
        path.read_text(encoding="utf-8").splitlines(), start=1
    ):
        match = re.fullmatch(r"([A-Z][A-Z0-9_]*)=(\S(?:.*\S)?)", line)
        if not match:
            continue
        key, value = match.groups()
        if key in values:
            errors.append(
                f"duplicate evidence key {key} in {path.relative_to(ROOT)}:"
                f"{line_number}"
            )
        else:
            values[key] = value
    return values


def require_evidence_values(
    path: Path,
    values: dict[str, str],
    expected: dict[str, str],
    errors: list[str],
) -> None:
    relative = path.relative_to(ROOT).as_posix()
    for key, wanted in expected.items():
        actual = values.get(key)
        if actual != wanted:
            errors.append(
                f"{relative} must contain exactly {key}={wanted}; found {actual!r}"
            )


def repository_files() -> list[Path]:
    return sorted(
        path
        for path in ROOT.rglob("*")
        if path.is_file() and ".git" not in path.relative_to(ROOT).parts
    )


def is_text(path: Path) -> bool:
    return (
        path.name in {"LICENSE", ".gitignore", ".gitattributes"}
        or path.suffix.lower() in TEXT_SUFFIXES
    )


def check_sensitive_text(path: Path, text: str, errors: list[str]) -> None:
    relative = path.relative_to(ROOT).as_posix()
    for label, pattern in SENSITIVE_PATTERNS.items():
        if pattern.search(text):
            errors.append(f"{label} found in {relative}")


def check_local_links(path: Path, text: str, errors: list[str]) -> None:
    for raw_target in re.findall(r"\[[^\]]+\]\(([^)]+)\)", text):
        target = raw_target.strip().strip("<>")
        if not target or target.startswith(("#", "http://", "https://", "mailto:")):
            continue
        target = unquote(target.split("#", 1)[0])
        resolved = (path.parent / target).resolve()
        try:
            resolved.relative_to(ROOT.resolve())
        except ValueError:
            errors.append(f"{path.relative_to(ROOT)}: link escapes repository: {target}")
            continue
        if not resolved.exists():
            errors.append(f"{path.relative_to(ROOT)}: missing local link: {target}")


def check_tar(errors: list[str]) -> None:
    if not VENDOR_ARCHIVE.is_file():
        return
    actual = sha256(VENDOR_ARCHIVE)
    if actual != EXPECTED_VENDOR_SHA256:
        errors.append(f"vendor SHA-256 mismatch: {actual}")
        return
    with tarfile.open(VENDOR_ARCHIVE, "r:gz") as archive:
        names = [member.name.replace("\\", "/") for member in archive.getmembers()]
        for name in names:
            pure = Path(name)
            if pure.is_absolute() or ".." in pure.parts:
                errors.append(f"unsafe archive path: {name}")
        roots = {Path(name).parts[0] for name in names if Path(name).parts}
        if len(roots) != 1:
            errors.append(f"vendor archive must have one top-level directory: {sorted(roots)}")
        tails = {"/".join(Path(name).parts[-3:]) for name in names}
        if not any(tail.endswith("linux-kernel/LICENSE") for tail in tails):
            errors.append("vendor archive is missing XDMA/linux-kernel/LICENSE")
        if not any(tail.endswith("linux-kernel/COPYING") for tail in tails):
            errors.append("vendor archive is missing XDMA/linux-kernel/COPYING")
    if not VENDOR_SOURCE_MANIFEST.is_file():
        return
    actual_manifest = sha256(VENDOR_SOURCE_MANIFEST)
    if actual_manifest != EXPECTED_VENDOR_SOURCE_MANIFEST_SHA256:
        errors.append(f"vendor source-manifest SHA-256 mismatch: {actual_manifest}")


def check_fpga_source(errors: list[str]) -> None:
    build_entry = ROOT / "fpga" / "build.tcl"
    if build_entry.is_file():
        build_text = without_tcl_comments(build_entry.read_text(encoding="utf-8"))
        if not re.search(
            r"\bsource\s+\[file\s+join\s+\$fpga_root\s+create_project\.tcl\]",
            build_text,
        ):
            errors.append("fpga/build.tcl does not invoke create_project.tcl")

    project_script = ROOT / "fpga" / "create_project.tcl"
    if project_script.is_file():
        project_text = without_tcl_comments(
            project_script.read_text(encoding="utf-8")
        )
        project_patterns = {
            "exact part": r"\bcreate_project\s+\S+\s+\$project_dir\s+-part\s+xc7k325tffg900-2\b",
            "block-design source": r"\bset\s+bd_script\s+\[file\s+join\s+\$fpga_root\s+bd\s+create_design\.tcl\]",
            "board XDC source": r"\bset\s+board_xdc\s+\[file\s+join\s+\$fpga_root\s+constraints\s+board\.xdc\]",
            "MIG source": r"\[file\s+join\s+\$fpga_root\s+mig\s+memblaze_ddr3\.prj\]",
            "top module": r"\bset_property\s+top\s+memblaze_k7_xdma_wrapper\b",
            "check_timing execution": r"\bcheck_timing\s+-verbose\s+-return_string\b",
            "check_timing fail-closed gate": r"\bfail\s+check_timing_gate\b",
            "bus-skew report": r"\breport_bus_skew\b",
            "bitstream write": r"\bwrite_bitstream\s+-force\s+\$bitstream_file\b",
        }
        for label, pattern in project_patterns.items():
            if not re.search(pattern, project_text, flags=re.MULTILINE):
                errors.append(f"FPGA project generator lacks executable {label}")
        zero_check_block = re.search(
            r"\bset\s+zero_timing_checks\s+\{(?P<body>.*?)\}",
            project_text,
            flags=re.DOTALL,
        )
        expected_zero_checks = {
            "no_clock",
            "constant_clock",
            "generated_clocks",
            "latch_loops",
            "loops",
            "multiple_clock",
            "unconstrained_internal_endpoints",
            "partial_input_delay",
            "partial_output_delay",
        }
        if zero_check_block is None:
            errors.append("FPGA project generator lacks zero_timing_checks")
        else:
            actual_zero_checks = set(zero_check_block.group("body").split())
            if actual_zero_checks != expected_zero_checks:
                errors.append(
                    "FPGA zero_timing_checks differ from the required set: "
                    f"{sorted(actual_zero_checks)}"
                )
        for required_statement in (
            "check_timing_count no_input_delay",
            "check_timing_count no_output_delay",
            "require_report_lines no_input_delay",
            "require_report_lines no_output_delay",
            "check_timing_count pulse_width_clock",
            "Expected 20.000 ns",
        ):
            if required_statement not in project_text:
                errors.append(
                    "FPGA project generator lacks timing allowlist check: "
                    f"{required_statement}"
                )

    bd_path = ROOT / "fpga" / "bd" / "create_design.tcl"
    bd_code = ""
    if bd_path.is_file():
        bd_text = bd_path.read_text(encoding="utf-8")
        bd_code = without_tcl_comments(bd_text)
        config_pairs = parse_tcl_config_pairs(bd_text, errors)
        expected_config = {
            "functional_mode": "DMA",
            "mode_selection": "Advanced",
            "device_port_type": "PCI_Express_Endpoint_device",
            "pcie_blk_locn": "X0Y0",
            "pl_link_cap_max_link_width": "X8",
            "pl_link_cap_max_link_speed": "5.0_GT/s",
            "ref_clk_freq": "100_MHz",
            "axi_addr_width": "64",
            "axi_data_width": "128_bit",
            "axi_id_width": "4",
            "axisten_freq": "250",
            "en_axi_master_if": "true",
            "dedicate_perst": "true",
            "sys_reset_polarity": "ACTIVE_LOW",
            "vendor_id": "10EE",
            "pf0_device_id": "7024",
            "pf0_revision_id": "00",
            "pf0_subsystem_vendor_id": "10EE",
            "pf0_subsystem_id": "0007",
            "pf0_class_code_base": "05",
            "pf0_class_code_sub": "80",
            "pf0_class_code_interface": "00",
            "pf0_bar0_enabled": "true",
            "pf0_bar0_type": "Memory",
            "pf0_bar0_size": "128",
            "pf0_bar0_scale": "Kilobytes",
            "pf0_bar0_64bit": "false",
            "pf0_bar0_prefetchable": "false",
            "pf0_bar0_index": "0",
            "pf0_bar1_enabled": "false",
            "pf0_bar2_enabled": "false",
            "pf0_bar3_enabled": "false",
            "pf0_bar4_enabled": "false",
            "pf0_bar5_enabled": "false",
            "xdma_size": "64",
            "xdma_scale": "Kilobytes",
            "bar_indicator": "BAR_0",
            "bar0_indicator": "1",
            "bar1_indicator": "0",
            "bar2_indicator": "0",
            "bar3_indicator": "0",
            "bar4_indicator": "0",
            "bar5_indicator": "0",
            "pciebar2axibar_xdma": "0x0000000000000000",
            "pf0_msi_enabled": "true",
            "pf0_msi_cap_multimsgcap": "1_vector",
            "pf0_msix_enabled": "false",
            "axilite_master_en": "false",
            "axist_bypass_en": "false",
            "xdma_axilite_slave": "false",
            "xdma_axi_intf_mm": "AXI_Memory_Mapped",
            "xdma_rnum_chnl": "2",
            "xdma_wnum_chnl": "2",
            "xdma_num_usr_irq": "1",
            "enable_gen4": "false",
            "enable_gtwizard": "false",
            "runbit_fix": "false",
            "XML_INPUT_FILE": "memblaze_ddr3.prj",
            "CLKOUT1_REQUESTED_OUT_FREQ": "200.000",
            "PRIM_IN_FREQ": "50.000",
            "NUM_SI": "1",
            "NUM_MI": "1",
        }
        for name, wanted in expected_config.items():
            actual = config_pairs.get(name)
            if actual != wanted:
                errors.append(
                    f"FPGA block-design CONFIG.{name} must be {wanted!r}; "
                    f"found {actual!r}"
                )
        if not re.search(
            r"\bassign_bd_address\s+-offset\s+0x0+\s+-range\s+"
            r"0x000100000000\b.*?"
            r"\[get_bd_addr_spaces\s+xdma_0/M_AXI\].*?"
            r"\[get_bd_addr_segs\s+mig_7series_0/memmap/memaddr\]",
            bd_code,
            flags=re.DOTALL,
        ):
            errors.append("FPGA block-design generator lacks the exact 4 GiB DDR map")
        required_connections = {
            "XDMA M_AXI to interconnect": (
                "xdma_0/M_AXI",
                "axi_mem_intercon/S00_AXI",
            ),
            "interconnect to MIG": (
                "axi_mem_intercon/M00_AXI",
                "mig_7series_0/S_AXI",
            ),
        }
        for label, (first_pin, second_pin) in required_connections.items():
            pattern = (
                r"\bconnect_bd_intf_net\s+"
                rf"\[get_bd_intf_pins\s+{re.escape(first_pin)}\]\s+\\?\s*"
                rf"\[get_bd_intf_pins\s+{re.escape(second_pin)}\]"
            )
            if not re.search(pattern, bd_code):
                errors.append(f"FPGA block-design generator lacks {label}")

    mig_path = ROOT / "fpga" / "mig" / "memblaze_ddr3.prj"
    mig_pads: dict[str, str] = {}
    if mig_path.is_file():
        try:
            mig_root = ET.parse(mig_path).getroot()
        except ET.ParseError as exc:
            errors.append(f"MIG configuration is not valid XML: {exc}")
        else:
            controller = mig_root.find("Controller")
            if controller is None:
                errors.append("MIG configuration lacks Controller")
            else:
                expected_values = {
                    "DataWidth": "64",
                    "ECC": "Disabled",
                    "C0_MEM_SIZE": "4294967296",
                    "C0_S_AXI_ADDR_WIDTH": "32",
                    "C0_S_AXI_DATA_WIDTH": "128",
                    "C0_S_AXI_ID_WIDTH": "4",
                }
                for tag, wanted in expected_values.items():
                    actual = controller.findtext(f".//{tag}")
                    if actual != wanted:
                        errors.append(
                            f"MIG {tag} must be {wanted!r}; found {actual!r}"
                        )
                if mig_root.findtext("TargetFPGA") != "xc7k325t-ffg900/-2":
                    errors.append("MIG TargetFPGA is not xc7k325t-ffg900/-2")
                if mig_root.findtext("SysResetPolarity") != "ACTIVE LOW":
                    errors.append("MIG SysResetPolarity is not ACTIVE LOW")

                pin_selection = controller.find("PinSelection")
                if pin_selection is None:
                    errors.append("MIG configuration lacks PinSelection")
                else:
                    signal_to_pad: dict[str, str] = {}
                    pad_to_signals: dict[str, list[str]] = {}
                    for pin in pin_selection.findall("Pin"):
                        signal = pin.get("name", "")
                        pad = pin.get("PADName", "")
                        if not signal or not re.fullmatch(r"[A-Z]{1,2}[0-9]+", pad):
                            errors.append(
                                f"MIG pin has invalid signal/PADName: {signal!r}/{pad!r}"
                            )
                            continue
                        if signal in signal_to_pad:
                            errors.append(f"MIG signal is assigned more than once: {signal}")
                        signal_to_pad[signal] = pad
                        pad_to_signals.setdefault(pad, []).append(signal)
                    for pad, signals in pad_to_signals.items():
                        if len(signals) > 1:
                            errors.append(
                                f"MIG PAD {pad} is assigned to multiple signals: "
                                f"{', '.join(sorted(signals))}"
                            )
                        else:
                            mig_pads[pad] = signals[0]

                    expected_indices = {
                        "ddr3_addr": set(range(16)),
                        "ddr3_ba": set(range(3)),
                        "ddr3_ck_n": {0},
                        "ddr3_ck_p": {0},
                        "ddr3_cke": {0},
                        "ddr3_cs_n": {0},
                        "ddr3_dm": set(range(8)),
                        "ddr3_dq": set(range(64)),
                        "ddr3_dqs_n": set(range(8)),
                        "ddr3_dqs_p": set(range(8)),
                        "ddr3_odt": {0},
                    }
                    for signal, expected in expected_indices.items():
                        found = {
                            int(match.group(1))
                            for name in signal_to_pad
                            if (match := re.fullmatch(
                                rf"{re.escape(signal)}\[(\d+)\]", name
                            ))
                        }
                        if found != expected:
                            errors.append(
                                f"MIG {signal} indices must be "
                                f"{sorted(expected)}; found {sorted(found)}"
                            )
                    for scalar in (
                        "ddr3_cas_n",
                        "ddr3_ras_n",
                        "ddr3_reset_n",
                        "ddr3_we_n",
                    ):
                        if list(signal_to_pad).count(scalar) != 1:
                            errors.append(f"MIG must assign scalar signal once: {scalar}")

    xdc_path = ROOT / "fpga" / "constraints" / "board.xdc"
    if xdc_path.is_file():
        xdc_text = xdc_path.read_text(encoding="utf-8")
        xdc_code = without_tcl_comments(xdc_text)
        if not re.search(
            r"\bset_property\s+BITSTREAM\.CONFIG\.UNUSEDPIN\s+Pullnone\s+"
            r"\[current_design\]",
            xdc_code,
        ):
            errors.append(
                "board.xdc must keep unused configuration pins at Pullnone"
            )
        package_pins = parse_xdc_package_pins(xdc_text, errors)
        expected_package_pins = {
            "CLK_IN_D_0_clk_p[0]": "U8",
            "pcie_mgt_0_txp[0]": "L4",
            "pcie_mgt_0_txp[1]": "M2",
            "pcie_mgt_0_txp[2]": "N4",
            "pcie_mgt_0_txp[3]": "P2",
            "pcie_mgt_0_txp[4]": "T2",
            "pcie_mgt_0_txp[5]": "U4",
            "pcie_mgt_0_txp[6]": "V2",
            "pcie_mgt_0_txp[7]": "Y2",
            "sys_rst_n_0": "V22",
            "clk_in1_50M": "D27",
        }
        for port, wanted in expected_package_pins.items():
            actual = package_pins.get(port)
            if actual != wanted:
                errors.append(
                    f"board.xdc {port} must use {wanted}; found {actual!r}"
                )
        for unresolved_status_port in (
            "user_lnk_up_0",
            "DDR_init_calib_complete_0",
        ):
            if unresolved_status_port in package_pins:
                errors.append(
                    "board.xdc must not reintroduce unverified active status port: "
                    f"{unresolved_status_port}"
                )
            if re.search(rf"\b{re.escape(unresolved_status_port)}\b", bd_code):
                errors.append(
                    "FPGA block design must not reintroduce unverified active "
                    f"status port: {unresolved_status_port}"
                )
        for unverified_status_pin in ("R24", "T20"):
            if unverified_status_pin in package_pins.values():
                errors.append(
                    "board.xdc must not drive unverified status pin: "
                    f"{unverified_status_pin}"
                )
        if re.search(r"(?i)\bPACKAGE_PIN\s+W26\b", xdc_code):
            errors.append("board.xdc actively constrains unresolved W26")
        for pad in sorted(set(package_pins.values()).intersection(mig_pads)):
            errors.append(
                f"package pin {pad} is shared by board.xdc port(s) and "
                f"MIG signal {mig_pads[pad]}"
            )

    fpga_readme = ROOT / "fpga" / "README.md"
    if fpga_readme.is_file():
        readme_text = fpga_readme.read_text(encoding="utf-8")
        if "generic PF0 BAR0 setting of 128 KiB" not in readme_text:
            errors.append("fpga/README.md does not state the 128 KiB PF0 BAR0 setting")
        if "XDMA configuration aperture setting of 64 KiB" not in readme_text:
            errors.append(
                "fpga/README.md does not distinguish the 64 KiB XDMA aperture"
            )


def check_wiring_image(path: Path, errors: list[str]) -> None:
    data = path.read_bytes()
    if not data:
        errors.append(f"wiring image is empty: {path.relative_to(ROOT).as_posix()}")
        return
    suffix = path.suffix.lower()
    valid = False
    if suffix == ".png":
        valid = data.startswith(b"\x89PNG\r\n\x1a\n")
    elif suffix in {".jpg", ".jpeg"}:
        valid = data.startswith(b"\xff\xd8\xff")
    elif suffix == ".webp":
        valid = len(data) >= 12 and data.startswith(b"RIFF") and data[8:12] == b"WEBP"
    elif suffix == ".svg":
        valid = b"<svg" in data[:4096].lower()
    if not valid:
        errors.append(
            f"wiring image content does not match {suffix}: "
            f"{path.relative_to(ROOT).as_posix()}"
        )


def check_release_evidence(
    clean_build: dict[str, object],
    physical_regression: dict[str, object],
    errors: list[str],
) -> None:
    evidence_specs = (
        ("clean build", clean_build, CLEAN_BUILD_EVIDENCE),
        ("physical regression", physical_regression, PHYSICAL_REGRESSION_EVIDENCE),
    )
    evidence_paths: dict[str, Path] = {}
    for label, section, expected_relative in evidence_specs:
        declared_relative = section.get("evidence_file")
        if declared_relative != expected_relative:
            errors.append(
                f"{label} evidence_file must be {expected_relative}; "
                f"found {declared_relative!r}"
            )
            continue
        path = ROOT / expected_relative
        evidence_paths[label] = path
        if not path.is_file():
            errors.append(f"{label} evidence file is missing: {expected_relative}")
            continue
        declared_sha = section.get("evidence_sha256")
        if not isinstance(declared_sha, str) or not re.fullmatch(
            r"[0-9a-f]{64}", declared_sha
        ):
            errors.append(f"{label} evidence_sha256 is missing or invalid")
        elif sha256(path) != declared_sha:
            errors.append(f"{label} evidence SHA-256 does not match its file")

    clean_path = evidence_paths.get("clean build")
    if clean_path is not None and clean_path.is_file():
        values = parse_evidence_key_values(clean_path, errors)
        require_evidence_values(
            clean_path,
            values,
            {
                "EVIDENCE_TYPE": "REPOSITORY_CLEAN_BUILD",
                "CLEAN_BUILD": "PASS",
                "VIVADO": "2026.1",
                "PART": "xc7k325tffg900-2",
                "TOP": "memblaze_k7_xdma_wrapper",
                "DRC_ERROR_COUNT": "0",
                "TIMING_CONSTRAINTS": "PASS",
                "CLOCK_50_PERIOD_NS": "20.000",
                "CHECK_TIMING_NO_CLOCK": "0",
                "CHECK_TIMING_CONSTANT_CLOCK": "0",
                "CHECK_TIMING_GENERATED_CLOCKS": "0",
                "CHECK_TIMING_LATCH_LOOPS": "0",
                "CHECK_TIMING_LOOPS": "0",
                "CHECK_TIMING_MULTIPLE_CLOCK": "0",
                "UNCONSTRAINED_INTERNAL_ENDPOINTS": "0",
                "CHECK_TIMING_PARTIAL_INPUT_DELAY": "0",
                "CHECK_TIMING_PARTIAL_OUTPUT_DELAY": "0",
                "CHECK_TIMING_NO_INPUT_DELAY": "9",
                "CHECK_TIMING_NO_OUTPUT_DELAY": "1",
                "CHECK_TIMING_PULSE_WIDTH_CLOCK": "8",
                "METHODOLOGY_LUTAR_1_WARNING_COUNT": "3",
                "METHODOLOGY_PDRC_190_WARNING_COUNT": "12",
                "METHODOLOGY_XDCB_5_WARNING_COUNT": "1",
                "METHODOLOGY_REQP_1959_ADVISORY_COUNT": "64",
                "METHODOLOGY_RELATED_VIOLATION_COUNT": "0",
                "BUS_SKEW_VIOLATION_COUNT": "0",
                "BITSTREAM_GENERATED": "yes",
                "BITSTREAM_INCLUDED": "no",
            },
            errors,
        )
        clock50_name = values.get("CLOCK_50_NAME", "")
        if not re.fullmatch(r"\S+", clock50_name):
            errors.append(
                f"{clean_path.relative_to(ROOT)} lacks a valid CLOCK_50_NAME"
            )
        source_set_hash = values.get("FPGA_SOURCE_SET_SHA256", "")
        if not re.fullmatch(r"[0-9a-f]{64}", source_set_hash):
            errors.append(
                f"{clean_path.relative_to(ROOT)} lacks a valid "
                "FPGA_SOURCE_SET_SHA256"
            )
        elif all((ROOT / relative).is_file() for relative in FPGA_SOURCE_FILES) and (
            source_set_hash != fpga_source_set_sha256(FPGA_SOURCE_FILES)
        ):
            errors.append(
                "clean-build evidence FPGA source-set SHA-256 does not match "
                "the current repository"
            )
        for key in (
            "SETUP_WNS_NS",
            "HOLD_WHS_NS",
            "MINIMUM_BUS_SKEW_SLACK_NS",
        ):
            raw = values.get(key, "")
            if not re.fullmatch(r"(?:0|[1-9][0-9]*)(?:\.[0-9]+)?", raw):
                errors.append(
                    f"{clean_path.relative_to(ROOT)} has invalid or negative {key}"
                )
        raw_count = values.get("BUS_SKEW_CONSTRAINT_COUNT", "")
        if not re.fullmatch(r"[0-9]+", raw_count) or int(raw_count) < 1:
            errors.append(
                f"{clean_path.relative_to(ROOT)} must record a positive "
                "BUS_SKEW_CONSTRAINT_COUNT"
            )
        evidence_bitstream_hash = values.get("BITSTREAM_SHA256")
        if not isinstance(evidence_bitstream_hash, str) or not re.fullmatch(
            r"[0-9a-f]{64}", evidence_bitstream_hash
        ):
            errors.append("clean-build evidence lacks a valid BITSTREAM_SHA256")
        elif clean_build.get("bitstream_sha256") != evidence_bitstream_hash:
            errors.append(
                "clean-build manifest bitstream SHA-256 differs from its evidence"
            )
        manifest_field_map = {
            "drc_error_count": "DRC_ERROR_COUNT",
            "setup_wns_ns": "SETUP_WNS_NS",
            "hold_whs_ns": "HOLD_WHS_NS",
            "bus_skew_constraint_count": "BUS_SKEW_CONSTRAINT_COUNT",
            "bus_skew_violation_count": "BUS_SKEW_VIOLATION_COUNT",
            "minimum_bus_skew_slack_ns": "MINIMUM_BUS_SKEW_SLACK_NS",
        }
        for manifest_key, evidence_key in manifest_field_map.items():
            if str(clean_build.get(manifest_key)) != values.get(evidence_key):
                errors.append(
                    f"clean-build manifest {manifest_key} differs from "
                    f"evidence {evidence_key}"
                )

    physical_path = evidence_paths.get("physical regression")
    if physical_path is not None and physical_path.is_file():
        values = parse_evidence_key_values(physical_path, errors)
        require_evidence_values(
            physical_path,
            values,
            {
                "EVIDENCE_TYPE": "REPOSITORY_EXACT_IMAGE_PHYSICAL_REGRESSION",
                "PHYSICAL_REGRESSION": "PASS",
                "JTAG_SRAM": "PASS",
                "PCI_ENUMERATION": "PASS",
                "ENDPOINT": "10ee:7024",
                "SUBSYSTEM": "10ee:0007",
                "LSPCI_VERBOSE": "CAPTURED",
                "SECURE_BOOT": "enabled",
                "XDMA_DRIVER": "PASS",
                "WINDOWS_JTAG_EVIDENCE": "PASS",
                "IDLE_INHIBITOR": "active",
                "KERNEL_LOG_CONTRACT": "PASS",
                "KERNEL_ERROR_CONTRACT": "PASS",
                "KERNEL_ERROR_FILTER_REGRESSION": "PASS",
                "DMA_DATA_COMPARE": "PASS",
                "DMA_64M_BOTH_CHANNELS": "PASS",
                "ALIAS_4G": "PASS",
                "CHUNKED_1G": "PASS",
                "CONTROL_ENGINE_IDENTIFIERS": "PASS",
                "CONCURRENT_DMA": "PASS",
                "FULL_4G_DATA_COMPARE": "PASS",
                "FULL_4G_CHUNK_COUNT": "64",
                "FULL_4G_BYTES_COVERED": "4294967296",
                "FULL_4G_WRITE_RECORDS": "64",
                "FULL_4G_VERIFY_RECORDS": "64",
                "FULL_4G_VERIFY_MISMATCHES": "0",
                "TOTAL_H2C_BYTES": "5644488704",
                "TOTAL_C2H_BYTES": "5644488704",
                "TOTAL_BIDIRECTIONAL_BYTES": "11288977408",
                "ADVANCED_RELEASE_VALIDATION": "PASS",
                "PCIE_PATH_STATUS_STABLE": "yes",
                "INTERNAL_EVIDENCE_SHA256": "PASS",
                "CLEANUP_STATUS": "PASS",
                "CLEANUP_RC": "0",
                "FINAL_STATE_CAPTURE_RC": "0",
                "WORKFLOW_COMPLETE": "yes",
                "NEW_SEVERE_KERNEL_MESSAGES": "none",
                "FINAL_DATA_TESTS": "PASS",
                "FINAL_EXPERIMENT_RC": "0",
            },
            errors,
        )
        irq_status = values.get("IRQ_DELTA_STATUS")
        if irq_status not in {"PASS", "UNAVAILABLE"}:
            errors.append(
                f"{physical_path.relative_to(ROOT)} must record IRQ_DELTA_STATUS "
                "as PASS or UNAVAILABLE"
            )
        elif irq_status == "UNAVAILABLE" and not values.get("IRQ_DELTA_REASON"):
            errors.append(
                f"{physical_path.relative_to(ROOT)} must explain unavailable IRQ evidence"
            )
        aer_status = values.get("AER_STATUS_STABLE")
        if aer_status not in {"yes", "UNAVAILABLE"}:
            errors.append(
                f"{physical_path.relative_to(ROOT)} must record AER_STATUS_STABLE "
                "as yes or UNAVAILABLE"
            )
        elif aer_status == "UNAVAILABLE" and not values.get("AER_STATUS_REASON"):
            errors.append(
                f"{physical_path.relative_to(ROOT)} must explain unavailable AER evidence"
            )
        bar_size = values.get("PF0_BAR0_RESOURCE_SIZE_KIB", "")
        if not re.fullmatch(r"[1-9][0-9]*", bar_size):
            errors.append(
                f"{physical_path.relative_to(ROOT)} lacks a positive integer "
                "PF0_BAR0_RESOURCE_SIZE_KIB"
            )
        manifest_bar_size = physical_regression.get("pf0_bar0_resource_size_kib")
        if str(manifest_bar_size) != bar_size:
            errors.append(
                "physical-regression manifest PF0 BAR0 resource size differs "
                "from its lspci evidence"
            )
        if physical_regression.get("raw_final_experiment_rc") != 0:
            errors.append(
                "physical-regression manifest must record raw_final_experiment_rc=0"
            )
        if physical_regression.get("package_revision") != values.get(
            "PACKAGE_REVISION"
        ):
            errors.append(
                "physical-regression manifest package revision differs from its evidence"
            )
        if physical_regression.get("repository_commit") != values.get(
            "REPOSITORY_COMMIT"
        ):
            errors.append(
                "physical-regression manifest repository commit differs from its evidence"
            )
        tested_hash = values.get("BITSTREAM_SHA256")
        if not isinstance(tested_hash, str) or not re.fullmatch(
            r"[0-9a-f]{64}", tested_hash
        ):
            errors.append("physical evidence lacks a valid BITSTREAM_SHA256")
        elif physical_regression.get("tested_bitstream_sha256") != tested_hash:
            errors.append(
                "physical-regression manifest bitstream SHA-256 differs from its evidence"
            )


def check_kernel_log_guards(errors: list[str]) -> None:
    helper_path = ROOT / "linux" / "lib" / "dmesg_capture.sh"
    if helper_path.is_file():
        helper_text = helper_path.read_text(encoding="utf-8")
        for required in (
            '"${sudo_cmd[@]}" dmesg',
            "journalctl --dmesg --boot=0",
            "--output=short-monotonic",
            "MEMBLAZE_KERNEL_LOG_BACKEND",
            "memblaze_select_kernel_log_text",
            "memblaze_select_kernel_log_file",
            "memblaze_capture_kernel_log_text",
            "memblaze_capture_kernel_log_file",
            "KERNEL_LOG_DMESG_ATTEMPT_RC=",
            "KERNEL_LOG_JOURNAL_ATTEMPT_RC=",
        ):
            if required not in helper_text:
                errors.append(
                    "linux/lib/dmesg_capture.sh lacks kernel-log fallback guard: "
                    f"{required}"
                )

    helper_test_path = ROOT / "tools" / "test_dmesg_capture.sh"
    if helper_test_path.is_file():
        helper_test_text = helper_test_path.read_text(encoding="utf-8")
        for required in (
            "unsupported dmesg --time-format=raw was reintroduced",
            "fixed dmesg backend",
            "fixed journal backend",
            "dmesg failure stderr",
            "failed journal stderr",
        ):
            if required not in helper_test_text:
                errors.append(
                    "tools/test_dmesg_capture.sh lacks runtime-contract case: "
                    f"{required}"
                )

    probe_path = ROOT / "linux" / "01_probe.sh"
    if probe_path.is_file():
        probe_text = probe_path.read_text(encoding="utf-8")
        for required in (
            'resource_file="/sys/bus/pci/devices/$bdf/resource"',
            "LSPCI_VERBOSE=CAPTURED",
            "PF0_BAR0_RESOURCE_SIZE_KIB=",
            'source "$dmesg_helper"',
            "memblaze_select_kernel_log_file",
        ):
            if required not in probe_text:
                errors.append(f"linux/01_probe.sh lacks BAR evidence guard: {required}")
    for relative in (
        "linux/04_load_verify.sh",
        "linux/05_dma_smoke.sh",
        "linux/06_extended_validation.sh",
        "linux/07_release_advanced.sh",
    ):
        path = ROOT / relative
        if not path.is_file():
            continue
        text = path.read_text(encoding="utf-8")
        for required in (
            'source "$dmesg_helper"',
            "memblaze_select_kernel_log_file",
            "memblaze_capture_kernel_log_file",
            'cmp --silent - "$dmesg_before_file"',
            "KernelLogPrefix=stable",
        ):
            if required not in text:
                errors.append(f"{relative} lacks kernel-log guard: {required}")

    workflow_path = ROOT / "linux" / "run_exact_image_regression.sh"
    if workflow_path.is_file():
        workflow_text = workflow_path.read_text(encoding="utf-8")
        workflow_guards = (
            "--bitstream-sha256",
            "--jtag-report-sha256",
            "--expected-live-disk-serial-prefix",
            "MEMBLAZE_IDLE_INHIBITED",
            "exec systemd-inhibit",
            "--what=idle",
            'actual_bitstream_sha256="$(sha256sum "$bitstream"',
            'actual_report_sha256="$(sha256sum "$jtag_report"',
            'tr -d \'\\r\' < "$sidecar"',
            'readonly jtag_report_text="$(tr -d \'\\r\' < "$jtag_report")"',
            'root_source="$(findmnt -rn -T / -o SOURCE)"',
            "protected_mounts=",
            "protected_swaps=",
            "runtime_protected_swaps=",
            "/proc/swaps",
            '(( ${#expected_live_serial} >= 16 ))',
            '[[ "$cow_serial" == "$expected_live_serial"* ]]',
            "SecureBoot enabled",
            "IDLE_INHIBITOR=active",
            "PROGRAM.HW_CFGMEM=",
            "PROGRAM.IS_SUPPORTED=1",
            "PROGRAM.FILE",
            "PROGRAM.HW_BITSTREAM",
            'run_step KERNEL_LOG_CONTRACT bash "$kernel_log_contract"',
            'run_step KERNEL_ERROR_CONTRACT bash "$kernel_error_contract"',
            'run_step PROBE bash "$script_dir/01_probe.sh"',
            'run_step BUILD bash "$script_dir/02_build_driver.sh"',
            'run_step SECURE_BOOT bash "$script_dir/03_secure_boot_status.sh"',
            'run_step LOAD bash "$script_dir/04_load_verify.sh"',
            'run_step SMOKE_DEFAULT bash "$script_dir/05_dma_smoke.sh"',
            'run_step ALIAS_4G bash "$script_dir/06_extended_validation.sh"',
            'run_step RELEASE_ADVANCED bash "$script_dir/07_release_advanced.sh"',
            'run_step CLEANUP bash "$script_dir/99_cleanup.sh"',
            "ENGINE_ID_H2C1=0x1fc00106",
            "ENGINE_ID_C2H1=0x1fc10106",
            "IRQ_DELTA_REASON=",
            "AER_STATUS_CAPTURED=",
            "AER_STATUS_REASON=",
            "PCIE_PATH_STATUS_STABLE=yes",
            "EARLY_TOOLCHAIN_AND_MOK_PREFLIGHT=PASS",
            '[[ "$(uname -m)" == "x86_64" ]]',
            '[[ -e "$kernel_build_dir/Makefile" ]]',
            '[[ -x "$kernel_sign_file" ]]',
            'mok_private_owner_mode="$(sudo stat',
            "certificate_public_key_sha=",
            "private_public_key_sha=",
            'mokutil --test-key "$mok_certificate"',
            "memblaze_select_kernel_log_text",
            "memblaze_capture_kernel_log_text",
            "memblaze_capture_kernel_log_file",
            "for (( attempt=0; attempt<log_flush_poll_attempts; attempt++ ))",
            "readonly log_flush_poll_attempts=600",
            "LOG_FLUSH_TIMEOUT:",
            "trap finish_workflow EXIT",
            'keepalive_sleep_pid=""',
            "trap stop_keepalive EXIT INT TERM",
            'kill "$sudo_keepalive_pid"',
            'wait "$sudo_keepalive_pid"',
            'session_pipeline_status=("${PIPESTATUS[@]}")',
            "WORKFLOW_SUBSHELL_FINAL_RC=",
            "SESSION_LOG_TEE_RC=",
            'sha256sum "$run_root/windows_jtag_program_status.txt"',
            "EVIDENCE_BUNDLE_SHA256=",
        )
        for required in workflow_guards:
            if required not in workflow_text:
                errors.append(
                    "linux/run_exact_image_regression.sh lacks protected "
                    f"workflow guard: {required}"
                )
        if workflow_text.count('grep -Fxq "SavedResult=$result_dir"') != 3:
            errors.append(
                "linux/run_exact_image_regression.sh must wait for the final "
                "SavedResult marker from all three logged DMA stages"
            )
        if not workflow_text.rstrip().endswith('exit "$workflow_rc"'):
            errors.append(
                "linux/run_exact_image_regression.sh must return the exact "
                "workflow status after writing its evidence bundle"
            )
        if "--expected-live-disk-serial " in workflow_text:
            errors.append(
                "linux/run_exact_image_regression.sh must describe and enforce "
                "a serial prefix because Linux may append a USB serial suffix"
            )
        cleanup_index = workflow_text.find(
            'run_step CLEANUP bash "$script_dir/99_cleanup.sh"'
        )
        post_cleanup_capture_index = workflow_text.find(
            "capture_state after_cleanup_gate"
        )
        final_filter_index = workflow_text.find(
            'if ! severe_kernel_messages="$(memblaze_filter_severe_kernel_messages'
        )
        if not (
            0 <= cleanup_index < post_cleanup_capture_index < final_filter_index
        ):
            errors.append(
                "linux/run_exact_image_regression.sh must capture and filter the "
                "final kernel log after mandatory cleanup"
            )

        # Linux exposed the same validated USB identifier with a controller-added
        # suffix in prior bring-up evidence. Keep a non-personal fixture here so a
        # future refactor does not regress to exact-string matching.
        serial_prefix_fixture = "0123456789abcdef"
        linux_serial_fixture = f"{serial_prefix_fixture}fedcba9876543210"
        if not linux_serial_fixture.startswith(serial_prefix_fixture):
            errors.append("internal Live-USB serial-prefix fixture is invalid")

    advanced_path = ROOT / "linux" / "07_release_advanced.sh"
    if advanced_path.is_file():
        advanced_text = advanced_path.read_text(encoding="utf-8")
        for required in (
            "Read 32-bit value at address",
            "candidate=$NF",
            '[[ "$value" =~ ^0x[0-9a-f]{8}$ ]]',
            "(( ((value & 0x00000f00) >> 8) == expected_channel ))",
            "(( (value & 0x000000ff) == 0x06 ))",
            "read_engine_identifier H2C1 0x0100 0x1fc00000 1",
            "read_engine_identifier C2H1 0x1100 0x1fc10000 1",
        ):
            if required not in advanced_text:
                errors.append(
                    "linux/07_release_advanced.sh lacks the pinned vendor "
                    f"reg_rw parser guard: {required}"
                )
        if "Read 32-bits value" in advanced_text:
            errors.append(
                "linux/07_release_advanced.sh uses the wrong plural form for "
                "the pinned vendor reg_rw output"
            )

        # Static fixtures for the exact output form and identifier layout in
        # the pinned reg_rw.c/libxdma.c. Bits 11:8 encode the channel number.
        reg_rw_fixtures = (
            ("H2C0", "0x1fc00006", 0x1FC00000, 0),
            ("H2C1", "0x1fc00106", 0x1FC00000, 1),
            ("C2H0", "0x1fc10006", 0x1FC10000, 0),
            ("C2H1", "0x1fc10106", 0x1FC10000, 1),
        )
        for label, expected_value, expected_family, expected_channel in reg_rw_fixtures:
            fixture = f"Read 32-bit value at address 0x00000000: {expected_value}"
            fixture_candidate = fixture.rsplit(maxsplit=1)[-1].lower()
            if re.fullmatch(r"0x[0-9a-f]{8}", fixture_candidate) is None:
                errors.append(f"internal reg_rw parser fixture is invalid for {label}")
                continue
            numeric = int(fixture_candidate, 16)
            if (
                numeric & 0xFFFF0000 != expected_family
                or (numeric & 0x00000F00) >> 8 != expected_channel
                or numeric & 0xFF != 0x06
            ):
                errors.append(f"internal XDMA identifier fixture is invalid for {label}")


def find_pending_values(value: object, prefix: str = "manifest") -> list[str]:
    found: list[str] = []
    if isinstance(value, dict):
        for key, child in value.items():
            found.extend(find_pending_values(child, f"{prefix}.{key}"))
    elif isinstance(value, list):
        for index, child in enumerate(value):
            found.extend(find_pending_values(child, f"{prefix}[{index}]"))
    elif isinstance(value, str) and value.strip().lower() == "pending":
        found.append(prefix)
    return found


def check_release_checksums(files: list[Path], errors: list[str]) -> None:
    if not RELEASE_CHECKSUMS.is_file():
        errors.append("SHA256SUMS.txt is missing")
        return
    targets = sorted(
        (path for path in files if path != RELEASE_CHECKSUMS),
        key=lambda path: path.relative_to(ROOT).as_posix(),
    )
    expected = "".join(
        f"{sha256(path)}  {path.relative_to(ROOT).as_posix()}\n" for path in targets
    ).encode("utf-8")
    if RELEASE_CHECKSUMS.read_bytes() != expected:
        errors.append("SHA256SUMS.txt does not match the current repository tree")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--release",
        action="store_true",
        help="also require the final original wiring image and cleared manifest",
    )
    parser.add_argument(
        "--print-fpga-source-set-sha256",
        action="store_true",
        help="print the deterministic FPGA source-set digest and exit",
    )
    args = parser.parse_args()

    if args.print_fpga_source_set_sha256:
        missing_sources = [
            relative
            for relative in FPGA_SOURCE_FILES
            if not (ROOT / relative).is_file()
        ]
        if missing_sources:
            for relative in missing_sources:
                print(f"ERROR: missing FPGA source: {relative}", file=sys.stderr)
            return 1
        print(
            "FPGA_SOURCE_SET_SHA256="
            + fpga_source_set_sha256(FPGA_SOURCE_FILES)
        )
        return 0

    errors: list[str] = []
    warnings: list[str] = []
    files = repository_files()
    relative_files = {path.relative_to(ROOT).as_posix() for path in files}

    missing = sorted(REQUIRED - relative_files)
    errors.extend(f"missing required file: {name}" for name in missing)

    for path in files:
        relative = path.relative_to(ROOT)
        forbidden_directories = FORBIDDEN_DIRECTORY_NAMES.intersection(relative.parts)
        if forbidden_directories:
            errors.append(
                "forbidden generated directory: "
                f"{relative.as_posix()} ({', '.join(sorted(forbidden_directories))})"
            )
        if path.name in FORBIDDEN_FILE_NAMES or path.name.startswith(".env."):
            errors.append(f"forbidden public file: {relative.as_posix()}")
        if path.suffix.lower() in FORBIDDEN_SUFFIXES:
            errors.append(f"forbidden public artifact: {relative.as_posix()}")
        if path.suffix.lower() == ".log" and relative.parts[0] != "evidence":
            errors.append(f"log file outside sanitized evidence directory: {relative.as_posix()}")
        text_candidate = is_text(path)
        if not text_candidate and path.stat().st_size > 16 * 1024 * 1024:
            continue
        data = path.read_bytes()
        if not text_candidate:
            # Catch extensionless scripts, copied SSH material, and renamed text
            # secrets without trying to decode binary archives or images.
            if b"\x00" not in data:
                try:
                    decoded = data.decode("utf-8")
                except UnicodeDecodeError:
                    pass
                else:
                    check_sensitive_text(path, decoded, errors)
            continue
        if data.startswith(b"\xef\xbb\xbf"):
            errors.append(f"UTF-8 BOM found: {relative.as_posix()}")
        if b"\x00" in data:
            errors.append(f"NUL byte found in text file: {relative.as_posix()}")
        if b"\r" in data:
            errors.append(f"carriage return found in public text file: {relative.as_posix()}")
        if data and not data.endswith(b"\n"):
            errors.append(f"missing final newline: {relative.as_posix()}")
        text = data.decode("utf-8", errors="replace")
        if "\ufffd" in text:
            errors.append(f"invalid UTF-8 replacement found: {relative.as_posix()}")
        check_sensitive_text(path, text, errors)
        if path.suffix.lower() == ".md":
            check_local_links(path, text, errors)

    for script in sorted((ROOT / "linux").glob("*.sh")):
        head = script.read_text(encoding="utf-8").splitlines()[:4]
        if "# SPDX-License-Identifier: MIT" not in head:
            errors.append(f"missing MIT SPDX header: {script.relative_to(ROOT)}")

    for script in (ROOT / "fpga").rglob("*.tcl"):
        head = script.read_text(encoding="utf-8").splitlines()[:4]
        if "# SPDX-License-Identifier: MIT" not in head:
            errors.append(f"missing MIT SPDX header: {script.relative_to(ROOT)}")

    for script in (ROOT / "tools").glob("*.py"):
        head = script.read_text(encoding="utf-8").splitlines()[:4]
        if "# SPDX-License-Identifier: MIT" not in head:
            errors.append(f"missing MIT SPDX header: {script.relative_to(ROOT)}")

    patch_path = ROOT / "linux" / "patches" / "0001-portable-kbuild.patch"
    if patch_path.is_file():
        patch_text = patch_path.read_text(encoding="utf-8")
        for required_text in (
            "BSD-3-Clause",
            "Modified 2026-09-14",
            "ccflags-y := -I$(src)/../include $(XVC_FLAGS)",
        ):
            if required_text not in patch_text:
                errors.append(f"portable Kbuild patch lacks: {required_text}")
        if "/lib/modules/5.15.0-67-generic" in patch_text and not any(
            line.startswith("-") and "5.15.0-67-generic" in line
            for line in patch_text.splitlines()
        ):
            errors.append("portable Kbuild patch retains an active hard-coded kernel path")

    try:
        manifest = json.loads((ROOT / "RELEASE_MANIFEST.json").read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        errors.append(f"invalid release manifest: {exc}")
        manifest = {}
    if not isinstance(manifest, dict):
        errors.append("release manifest root must be a JSON object")
        manifest = {}
    if manifest.get("schema_version") != 2:
        errors.append("RELEASE_MANIFEST.json schema_version must be 2")

    expected_fpga_sources = list(FPGA_SOURCE_FILES)
    fpga_design = manifest.get("fpga_design", {})
    if not isinstance(fpga_design, dict):
        errors.append("RELEASE_MANIFEST.json fpga_design must be an object")
        fpga_design = {}
    if fpga_design.get("repository_inputs_complete") is not True:
        errors.append("fpga_design must record repository_inputs_complete=true")
    for key, wanted in {
        "part": "xc7k325tffg900-2",
        "top": "memblaze_k7_xdma_wrapper",
        "address_space": "0x00000000-0xffffffff",
    }.items():
        if fpga_design.get(key) != wanted:
            errors.append(f"fpga_design {key} must be {wanted!r}")
    if fpga_design.get("source_files") != expected_fpga_sources:
        errors.append("fpga_design source_files do not match the repository-local source set")
    mig_configuration = fpga_design.get("mig_configuration", {})
    if not isinstance(mig_configuration, dict):
        mig_configuration = {}
    if mig_configuration.get("path") != "fpga/mig/memblaze_ddr3.prj":
        errors.append("fpga_design mig_configuration path is missing or unexpected")
    if mig_configuration.get("terms") != (
        "subject to applicable AMD/Xilinx tool and IP terms"
    ):
        errors.append("fpga_design MIG tool/IP terms boundary is missing")
    if mig_configuration.get("version_control_basis") != (
        "AMD UG949 2026.1, IP Versions and Revision Control"
    ):
        errors.append("fpga_design MIG version-control basis is missing")

    declared_source_hashes = fpga_design.get("source_sha256")
    if isinstance(declared_source_hashes, dict):
        if set(declared_source_hashes) != set(expected_fpga_sources):
            errors.append("fpga_design source_sha256 keys do not match source_files")
        for relative in expected_fpga_sources:
            source_path = ROOT / relative
            declared_hash = declared_source_hashes.get(relative)
            if not isinstance(declared_hash, str) or not re.fullmatch(
                r"[0-9a-f]{64}", declared_hash
            ):
                errors.append(f"invalid source SHA-256 in manifest: {relative}")
            elif source_path.is_file() and sha256(source_path) != declared_hash:
                errors.append(f"FPGA source SHA-256 mismatch: {relative}")
    elif args.release:
        errors.append("fpga_design source_sha256 is not a complete hash object")
    else:
        warnings.append("FPGA source SHA-256 manifest awaits the frozen source set")

    clean_build = fpga_design.get("clean_build", {})
    if not isinstance(clean_build, dict):
        clean_build = {}
    physical_regression = fpga_design.get("physical_regression", {})
    if not isinstance(physical_regression, dict):
        physical_regression = {}
    if clean_build.get("evidence_file") != CLEAN_BUILD_EVIDENCE:
        errors.append(
            f"fpga_design clean_build evidence_file must be {CLEAN_BUILD_EVIDENCE}"
        )
    if clean_build.get("vivado") != "2026.1":
        errors.append("fpga_design clean_build vivado must be '2026.1'")
    if physical_regression.get("evidence_file") != PHYSICAL_REGRESSION_EVIDENCE:
        errors.append(
            "fpga_design physical_regression evidence_file must be "
            f"{PHYSICAL_REGRESSION_EVIDENCE}"
        )
    expected_physical_gates = [
        "JTAG volatile SRAM programming",
        "PCIe enumeration",
        "lspci -vv active BAR resource capture",
        "Secure Boot enabled and signed XDMA module accepted",
        "XDMA build, signing, load, and binding",
        "basic DMA comparison",
        "64 MiB comparison on both DMA channels",
        "alias-4g",
        "chunked-1g",
        "four XDMA engine identifiers",
        "concurrent dual-channel DMA comparison",
        "full 4 GiB chunked comparison",
        "PCIe and kernel-log stability, with AER recorded when exposed",
        "cleanup",
    ]
    if physical_regression.get("required_gates") != expected_physical_gates:
        errors.append("fpga_design physical_regression required_gates are incomplete")
    if clean_build.get("bitstream_included") is not False:
        errors.append("fpga_design clean_build must record bitstream_included=false")
    if args.release:
        if clean_build.get("status") != "pass":
            errors.append("repository-local FPGA clean build is not recorded as pass")
        if clean_build.get("bitstream_generated") is not True:
            errors.append("repository-local FPGA clean build did not generate a bitstream")
        if physical_regression.get("status") != "pass":
            errors.append("repository-local FPGA physical regression is not recorded as pass")
        build_bitstream_hash = clean_build.get("bitstream_sha256")
        tested_bitstream_hash = physical_regression.get("tested_bitstream_sha256")
        if not isinstance(build_bitstream_hash, str) or not re.fullmatch(
            r"[0-9a-f]{64}", build_bitstream_hash
        ):
            errors.append("clean-build bitstream SHA-256 is missing or invalid")
        if not isinstance(tested_bitstream_hash, str) or not re.fullmatch(
            r"[0-9a-f]{64}", tested_bitstream_hash
        ):
            errors.append("physical-regression bitstream SHA-256 is missing or invalid")
        if (
            isinstance(build_bitstream_hash, str)
            and isinstance(tested_bitstream_hash, str)
            and build_bitstream_hash != tested_bitstream_hash
        ):
            errors.append("clean-build and physically tested bitstream SHA-256 differ")
        check_release_evidence(clean_build, physical_regression, errors)
    else:
        if clean_build.get("status") != "pass":
            warnings.append("repository-local FPGA clean build is still pending")
        if physical_regression.get("status") != "pass":
            warnings.append("repository-local FPGA physical regression is still pending")

    wiring_candidates = [
        path
        for path in (ROOT / "docs" / "images").glob("wiring-overview.*")
        if path.suffix.lower() in {".png", ".jpg", ".jpeg", ".webp", ".svg"}
    ]
    if not wiring_candidates:
        message = "final wiring image is not present as docs/images/wiring-overview.*"
        if args.release:
            errors.append(message)
        else:
            warnings.append(message)
    elif len(wiring_candidates) > 1:
        errors.append("more than one final wiring image is present")
    else:
        check_wiring_image(wiring_candidates[0], errors)
        if args.release:
            image_name = wiring_candidates[0].name
            required_references = {
                ROOT / "README.md": f"docs/images/{image_name}",
                ROOT / "README.zh-CN.md": f"docs/images/{image_name}",
                ROOT / "docs" / "HARDWARE_SETUP.zh-CN.md": f"images/{image_name}",
            }
            for document, target in required_references.items():
                if target not in document.read_text(encoding="utf-8"):
                    errors.append(
                        f"{document.relative_to(ROOT).as_posix()} does not reference {target}"
                    )
    hardware_record = manifest.get("hardware_record", {})
    if not isinstance(hardware_record, dict):
        hardware_record = {}
    if args.release:
        if hardware_record.get("status") != "documented-and-validated":
            errors.append(
                "hardware_record status must be 'documented-and-validated'"
            )
        declared_images: list[tuple[str, object]] = []
        declared_images.append(("wiring_figure", hardware_record.get("wiring_figure")))
        photos = hardware_record.get("photos", {})
        if not isinstance(photos, dict):
            photos = {}
        for key in ("parts", "debug_session", "powered_fixture"):
            declared_images.append((f"photos.{key}", photos.get(key)))
        image_paths: dict[str, str] = {}
        for label, entry in declared_images:
            if not isinstance(entry, dict):
                errors.append(f"hardware_record {label} must be an object")
                continue
            relative = entry.get("path")
            declared_hash = entry.get("sha256")
            if not isinstance(relative, str):
                errors.append(f"hardware_record {label} path is missing")
                continue
            image_paths[label] = relative
            path = ROOT / relative
            if not path.is_file():
                errors.append(f"hardware image is missing: {relative}")
                continue
            if not isinstance(declared_hash, str) or not re.fullmatch(
                r"[0-9a-f]{64}", declared_hash
            ):
                errors.append(f"hardware_record {label} SHA-256 is invalid")
            elif sha256(path) != declared_hash:
                errors.append(f"hardware image SHA-256 mismatch: {relative}")
            if (
                path.suffix.lower() in {".jpg", ".jpeg"}
                and b"Exif\x00\x00" in path.read_bytes()
            ):
                errors.append(f"JPEG still contains EXIF metadata: {relative}")
        expected_images = {
            "wiring_figure": "docs/images/wiring-overview.svg",
            "photos.parts": "docs/images/hardware-parts-overview.jpg",
            "photos.debug_session": "docs/images/xdma-debug-session.jpg",
            "photos.powered_fixture": "docs/images/hardware-running.jpg",
        }
        if image_paths != expected_images:
            errors.append("hardware_record image paths do not match the public image set")
        required_image_references = {
            ROOT / "README.md": (
                "docs/images/wiring-overview.svg",
                "docs/images/xdma-debug-session.jpg",
            ),
            ROOT / "README.zh-CN.md": (
                "docs/images/wiring-overview.svg",
                "docs/images/xdma-debug-session.jpg",
            ),
            ROOT / "docs" / "HARDWARE_SETUP.zh-CN.md": tuple(
                "images/" + Path(relative).name
                for relative in expected_images.values()
            ),
        }
        for document, targets in required_image_references.items():
            content = document.read_text(encoding="utf-8")
            for target in targets:
                if target not in content:
                    errors.append(
                        f"{document.relative_to(ROOT).as_posix()} does not reference {target}"
                    )
    if args.release and manifest.get("status") != "release-ready":
        errors.append("RELEASE_MANIFEST.json status is not release-ready")
    if args.release and manifest.get("publication_blockers"):
        errors.append("RELEASE_MANIFEST.json still contains publication blockers")
    if args.release:
        for pending_path in find_pending_values(manifest):
            errors.append(f"pending value remains in release manifest: {pending_path}")
        for path in files:
            if path.suffix.lower() not in {".md", ".json"}:
                continue
            text = re.sub(r"\s+", " ", path.read_text(encoding="utf-8"))
            for phrase in RELEASE_PLACEHOLDER_PHRASES:
                normalized_phrase = re.sub(r"\s+", " ", phrase)
                if normalized_phrase in text:
                    errors.append(
                        "release placeholder remains in "
                        f"{path.relative_to(ROOT).as_posix()}: {phrase}"
                    )
        check_release_checksums(files, errors)

    check_fpga_source(errors)
    check_kernel_log_guards(errors)
    check_tar(errors)

    if warnings:
        for warning in warnings:
            print(f"WARNING: {warning}")
    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        print(f"VALIDATION=FAIL errors={len(errors)} warnings={len(warnings)}")
        return 1
    print(f"VALIDATION=PASS files={len(files)} warnings={len(warnings)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
