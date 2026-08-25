"""Normalização, diff e identidades físicas da fase I6."""
import copy
import json
import unittest

from passthrough_core import inventory
from passthrough_core.errors import ConflictError, DataError


CPU = """Architecture: x86_64
CPU(s): 8
On-line CPU(s) list: 0-7
Thread(s) per core: 2
Core(s) per socket: 4
Socket(s): 1
Model name: Fixture CPU
"""
MEMINFO = "MemTotal:       33554432 kB\n"
PCI = """0000:01:00.0 VGA compatible controller [0300]: Fixture [1234:5678]
0000:01:00.1 Audio device [0403]: Fixture [1234:5679]
"""
BLOCK = {
    "blockdevices": [
        {
            "name": "sda", "kname": "sda", "path": "/dev/sda", "type": "disk",
            "maj:min": "8:0", "size": 1000, "model": "System", "serial": "SYS", "wwn": "5000aa",
            "children": [{"name": "sda1", "kname": "sda1", "path": "/dev/sda1", "type": "part", "maj:min": "8:1", "size": 900, "model": "", "serial": "", "wwn": "", "pkname": "sda"}],
        },
        {
            "name": "sdb", "kname": "sdb", "path": "/dev/sdb", "type": "disk",
            "maj:min": "8:16", "size": 2000, "model": "Working", "serial": "WORK", "wwn": "5000bb",
            "children": [{"name": "sdb1", "kname": "sdb1", "path": "/dev/sdb1", "type": "part", "maj:min": "8:17", "size": 1900, "model": "", "serial": "", "wwn": "", "pkname": "sdb"}],
        },
        {"name": "sdc", "kname": "sdc", "path": "/dev/sdc", "type": "disk", "maj:min": "8:32", "size": 3000, "model": "HD1", "serial": "HD1", "wwn": "5000cc"},
    ]
}
BY_ID = "ata-system\t8:0\nata-working\t8:16\nata-hd1\t8:32\n"
UDEV = """E: MAJOR=8
E: MINOR=0
E: ID_WWN=0x5000aa
E: ID_SERIAL_SHORT=SYS

E: MAJOR=8
E: MINOR=16
E: ID_WWN=0x5000bb
E: ID_SERIAL_SHORT=WORK

E: MAJOR=8
E: MINOR=32
E: ID_WWN_WITH_EXTENSION=0x5000cc01
E: ID_WWN=0x5000cc
E: ID_SERIAL_SHORT=HD1
"""
USB = [
    {"vendor": "046d", "product": "c52b", "serial": "SERIAL-A", "port": "pci-0000:00:14.0-usb-0:2.3", "bus": 1, "device": 7}
]
INTERFACES = [{"ifname": "enp1s0", "address": "02:00:00:00:00:01", "permaddr": "02:00:00:00:00:01", "link_type": "ether"}]
BOOT = "FIRMWARE=uefi\nSECURE_BOOT=disabled\nBOOTLOADER=kernelstub\n"


def capture() -> dict:
    return {
        "schema_version": "1",
        "cpu_state": "present", "cpu_reason": "", "cpu_data": CPU,
        "memory_state": "present", "memory_reason": "", "memory_data": MEMINFO,
        "memory_report": "Memory Device\n        Size: 32768 MB",
        "pci_state": "present", "pci_reason": "", "pci_data": PCI,
        "disks_state": "present", "disks_reason": "", "block_json": json.dumps(BLOCK),
        "block_by_id_map": BY_ID, "udev_database": UDEV,
        "usb_state": "present", "usb_reason": "", "usb_data": json.dumps(USB),
        "interfaces_state": "present", "interfaces_reason": "", "interfaces_data": json.dumps(INTERFACES),
        "boot_state": "present", "boot_reason": "", "boot_data": BOOT,
        "baseboard_report": "Fixture board", "bios_report": "Fixture bios", "iommu_report": "Fixture IOMMU",
    }


def v1(reordered: bool = False) -> str:
    lines = [
        "CPU|Architecture|x86_64", "CPU|CPU(s)|8", "CPU|On-line CPU(s) list|0-7",
        "CPU|Thread(s) per core|2", "CPU|Core(s) per socket|4", "CPU|Socket(s)|1",
        "CPU|Model name|Fixture CPU", "RAM_MIB|32768",
        "PCI|0000:01:00.0|0300|1234:5678",
        'DISK|BYTES="1073741824" MODEL="Fixture Disk" SERIAL="SER001" TYPE="disk"',
    ]
    if reordered:
        lines = lines[:8] + list(reversed(lines[8:]))
    return "\n".join(lines)


def current_report(identity: str | None = None) -> str:
    return """== HARDWARE IDENTITY ==
%s
== CPU ==
fixture
== RAM ==
fixture
== BASEBOARD ==
fixture
== BIOS ==
fixture
== PCI ==
fixture
== BLOCK DEVICES ==
fixture
== IOMMU/DMAR (pré-configuração) ==
fixture
""" % (identity if identity is not None else v1())


class NormalizeTests(unittest.TestCase):
    def test_snapshot_deterministic_and_round_trip_v2(self) -> None:
        data1, report1 = inventory.render_report(capture())
        data2, report2 = inventory.render_report(capture())
        self.assertEqual(report1, report2)
        self.assertEqual(data1["snapshot_fingerprint"], data2["snapshot_fingerprint"])
        parsed, source = inventory.parse_report_text(report1)
        self.assertEqual(source, "v2")
        self.assertEqual(inventory.fingerprints(parsed)[0], data1["snapshot_fingerprint"])

    def test_all_five_states_are_distinct(self) -> None:
        for state, reason in (("absent", "not_found"), ("unavailable", "probe_missing"), ("error", "probe_failed"), ("empty", "")):
            payload = capture()
            payload.update({"usb_state": state, "usb_reason": reason, "usb_data": ""})
            snapshot = inventory.normalize_capture(payload)
            self.assertEqual(snapshot["facts"]["usb"]["state"], state)
            expected = [] if state == "empty" else None
            self.assertEqual(snapshot["facts"]["usb"]["value"], expected)

    def test_state_with_data_is_rejected(self) -> None:
        payload = capture()
        payload.update({"usb_state": "unavailable", "usb_reason": "probe_missing"})
        with self.assertRaises(DataError):
            inventory.normalize_capture(payload)

    def test_closed_schema(self) -> None:
        payload = capture()
        payload["extra"] = "x"
        with self.assertRaises(DataError):
            inventory.normalize_capture(payload)

    def test_cpu_topology_inconsistent(self) -> None:
        payload = capture()
        payload["cpu_data"] = CPU.replace("CPU(s): 8", "CPU(s): 16")
        with self.assertRaises(DataError):
            inventory.normalize_capture(payload)


class ParserAndDiffTests(unittest.TestCase):
    def test_current_reordering_is_semantically_equal(self) -> None:
        first, _ = inventory.parse_report_text(current_report(v1()))
        second, _ = inventory.parse_report_text(current_report(v1(True)))
        self.assertEqual(inventory.fingerprints(first)[1], inventory.fingerprints(second)[1])
        diff = inventory.diff_command({"expected_report": current_report(v1()), "actual_capture": v1(True)})
        self.assertEqual(diff["requires_redetect"], 0)

    def test_legacy_converges_on_common_subset(self) -> None:
        legacy = """== CPU ==
Architecture: x86_64
CPU(s): 8
On-line CPU(s) list: 0-7
Thread(s) per core: 2
Core(s) per socket: 4
Socket(s): 1
Model name: Fixture CPU
== RAM ==
Memory Device
        Size: 32768 MB
== BASEBOARD ==
fixture
== BIOS ==
fixture
== PCI ==
01:00.0 VGA compatible controller [0300]: Fixture [1234:5678]
== BLOCK DEVICES ==
NAME SIZE TYPE MODEL SERIAL
sda 1G disk Fixture_Disk SER001
== IOMMU/DMAR (pré-configuração) ==
fixture
"""
        snapshot, source = inventory.parse_report_text(legacy)
        self.assertEqual(source, "legacy-v0")
        self.assertEqual(snapshot["facts"]["memory"]["value"]["total_mib"], 32768)
        self.assertEqual(snapshot["facts"]["usb"]["state"], "unavailable")

    def test_ram_tolerance_boundary(self) -> None:
        within = v1().replace("RAM_MIB|32768", "RAM_MIB|33792")
        outside = v1().replace("RAM_MIB|32768", "RAM_MIB|34817")
        self.assertEqual(inventory.diff_command({"expected_report": current_report(), "actual_capture": within})["requires_redetect"], 0)
        self.assertEqual(inventory.diff_command({"expected_report": current_report(), "actual_capture": outside})["requires_redetect"], 1)

    def test_physical_change_requires_redetection(self) -> None:
        changed = v1().replace("SER001", "SER999")
        diff = inventory.diff_command({"expected_report": current_report(), "actual_capture": changed})
        self.assertEqual(diff["physical_changed"], 1)
        self.assertEqual(diff["requires_redetect"], 1)

    def test_duplicate_truncated_and_hostile_reports_rejected(self) -> None:
        cases = [
            current_report() + "== CPU ==\nagain\n",
            current_report().replace("== BLOCK DEVICES ==\nfixture\n", ""),
            current_report().replace("fixture", "$(id)", 1),
            current_report().replace("fixture", "`id`", 1),
            current_report().replace("fixture", "source /tmp/x", 1),
        ]
        for report in cases:
            with self.subTest(report=report[-30:]):
                with self.assertRaises(DataError):
                    inventory.parse_report_text(report)

    def test_v2_rejects_truncated_or_visibly_inconsistent_envelope(self) -> None:
        _data, report = inventory.render_report(capture())
        usb_start = report.index("== USB ==")
        interfaces_start = report.index("== INTERFACES ==")
        truncated = report[:usb_start] + report[interfaces_start:]
        tampered = report.replace('\"model\":\"Fixture CPU\"', '\"model\":\"TAMPERED\"', 1)
        marker_end = report.index("\n", report.index("INVENTORY_V2|"))
        forged_marker = (
            report[:marker_end].replace('\"by_id\":[\"ata-system\"]', '\"forged\":1,\"by_id\":[\"ata-system\"]', 1)
            + report[marker_end:]
        )
        block_start = report.index("== BLOCK DEVICES ==")
        usb_start = report.index("== USB ==")
        tampered_disk_body = (
            report[:block_start]
            + report[block_start:usb_start].replace('\"serial\":\"SYS\"', '\"serial\":\"OTHER\"', 1)
            + report[usb_start:]
        )
        for candidate in (truncated, tampered, forged_marker, tampered_disk_body):
            with self.subTest(candidate=candidate[usb_start:usb_start + 40]):
                with self.assertRaises(DataError):
                    inventory.parse_report_text(candidate)

    def test_losing_previously_known_coverage_requires_redetection(self) -> None:
        _expected_data, expected = inventory.render_report(capture())
        degraded_capture = capture()
        degraded_capture.update({"usb_state": "unavailable", "usb_reason": "probe_missing", "usb_data": ""})
        _actual_data, actual = inventory.render_report(degraded_capture)
        diff = inventory.diff_command({"expected_report": expected, "actual_capture": actual})
        self.assertEqual(diff["coverage_changed"], 1)
        self.assertEqual(diff["state_changed"], 1)
        self.assertEqual(diff["requires_redetect"], 1)

    def test_duplicate_cpu_key_rejected(self) -> None:
        with self.assertRaises(DataError):
            inventory.parse_report_text(current_report(v1() + "\nCPU|CPU(s)|8"))


class DiskIdentityTests(unittest.TestCase):
    def payload(self) -> dict:
        return {
            "block_json": json.dumps(BLOCK), "block_by_id_map": BY_ID,
            "udev_database": UDEV, "system_members": "/dev/sda1",
            "working_members": "/dev/sdb1", "hd1_members": "/dev/sdc",
        }

    def test_three_distinct_roles(self) -> None:
        data = inventory.disk_plan_command(self.payload())
        self.assertEqual(data["valid"], 1)
        self.assertEqual(data["conflict_count"], 0)
        for role in ("system", "working", "hd1"):
            self.assertRegex(data[role + "_fingerprint"], r"^[0-9a-f]{64}$")

    def test_each_pair_collision_fails_closed(self) -> None:
        for left, right, member in (("system", "working", "/dev/sda1"), ("system", "hd1", "/dev/sda"), ("working", "hd1", "/dev/sdb")):
            payload = self.payload()
            payload[right + "_members"] = member
            data = inventory.disk_plan_command(payload)
            self.assertEqual(data["valid"], 0, (left, right))
            self.assertGreaterEqual(data["conflict_count"], 1)

    def test_expected_fingerprint_detects_toctou(self) -> None:
        payload = self.payload()
        payload["expected_system_fingerprint"] = "0" * 64
        with self.assertRaises(ConflictError):
            inventory.disk_plan_command(payload)

    def test_cloned_stable_disk_identity_is_rejected(self) -> None:
        payload = self.payload()
        block = copy.deepcopy(BLOCK)
        clone = copy.deepcopy(block["blockdevices"][0])
        clone.update({"name": "sdd", "kname": "sdd", "path": "/dev/sdd", "maj:min": "8:48", "children": []})
        block["blockdevices"].append(clone)
        payload["block_json"] = json.dumps(block)
        with self.assertRaises(DataError):
            inventory.disk_plan_command(payload)

    def test_system_role_fingerprint_covers_all_physical_members(self) -> None:
        single = inventory.disk_plan_command(self.payload())
        payload = self.payload()
        payload.update({"system_members": "/dev/sda1,/dev/sdb1", "working_members": ""})
        composite = inventory.disk_plan_command(payload)
        self.assertNotEqual(single["system_fingerprint"], composite["system_fingerprint"])
        collision = dict(payload, working_members="/dev/sdb1")
        self.assertEqual(inventory.disk_plan_command(collision)["valid"], 0)

    def test_missing_stable_identity_rejected(self) -> None:
        payload = self.payload()
        block = copy.deepcopy(BLOCK)
        block["blockdevices"][2].update({"serial": "", "wwn": ""})
        payload["block_json"] = json.dumps(block)
        payload["block_by_id_map"] = "ata-system\t8:0\nata-working\t8:16\n"
        payload["udev_database"] = UDEV.split("E: MAJOR=8\nE: MINOR=32", 1)[0]
        with self.assertRaises(DataError):
            inventory.disk_plan_command(payload)


class UsbIdentityTests(unittest.TestCase):
    def resolve(self, devices: list[dict], **updates: str) -> dict:
        payload = {
            "usb_data": json.dumps(devices), "mode": "select", "vendor": "046d",
            "product": "c52b", "identity_kind": "", "identity_sha256": "",
            "expected_bus": "1", "expected_device": "7",
        }
        payload.update(updates)
        return inventory.usb_resolve_command(payload)

    def test_serial_survives_bus_device_renumbering(self) -> None:
        selected = self.resolve(USB)
        changed = [dict(USB[0], bus=4, device=22)]
        resolved = self.resolve(
            changed, mode="resolve", identity_kind=selected["identity_kind"],
            identity_sha256=selected["identity_sha256"], expected_bus="1", expected_device="7",
        )
        self.assertEqual(resolved["valid"], 1)
        self.assertEqual(resolved["renumbered"], 1)

    def test_port_fallback_survives_renumbering(self) -> None:
        device = [dict(USB[0], serial="")]
        selected = self.resolve(device)
        self.assertEqual(selected["identity_kind"], "port")
        changed = [dict(device[0], bus=8, device=9)]
        resolved = self.resolve(changed, mode="resolve", identity_kind="port", identity_sha256=selected["identity_sha256"], expected_bus="1", expected_device="7")
        self.assertEqual((resolved["valid"], resolved["renumbered"]), (1, 1))

    def test_duplicate_identity_fails_closed(self) -> None:
        devices = [USB[0], dict(USB[0], bus=2, device=8)]
        selected = self.resolve(devices)
        self.assertEqual(selected["valid"], 0)
        self.assertIn("duplicada", selected["error"])

    def test_missing_serial_and_port_fails_closed(self) -> None:
        device = [dict(USB[0], serial="", port="")]
        selected = self.resolve(device)
        self.assertEqual(selected["valid"], 0)

    def test_wrong_expected_address_does_not_pick_by_order(self) -> None:
        selected = self.resolve(USB, expected_bus="9", expected_device="9")
        self.assertEqual(selected["valid"], 0)
        self.assertEqual(selected["match_count"], 0)


if __name__ == "__main__":
    unittest.main()
