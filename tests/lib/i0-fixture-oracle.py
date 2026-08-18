#!/usr/bin/env python3
"""Valida a intenção das fixtures sintéticas da fase I0.

Este helper é exclusivo de testes: não é o futuro core e não executa comandos
nem lê dados do host. Ele impede que uma fixture deixe silenciosamente de
representar o caso zero/um/múltiplos ou o erro declarado no manifesto.
"""
from __future__ import annotations

import json
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


def fail(message: str) -> "None":
    raise AssertionError(message)


def direct(parent: ET.Element, tag: str) -> list[ET.Element]:
    return [child for child in list(parent) if child.tag == tag]


def require(condition: bool, message: str) -> None:
    if not condition:
        fail(message)


def parse_tsv(path: Path) -> list[dict[str, str]]:
    lines = path.read_text(encoding="utf-8").splitlines()
    require(bool(lines), f"manifesto vazio: {path}")
    header = lines[0].split("\t")
    require(len(header) == len(set(header)), f"cabeçalho duplicado: {path}")
    rows: list[dict[str, str]] = []
    for number, line in enumerate(lines[1:], 2):
        if not line:
            continue
        values = line.split("\t")
        require(len(values) == len(header), f"{path}:{number}: colunas inválidas")
        rows.append(dict(zip(header, values, strict=True)))
    return rows


def parse_xml(path: Path) -> ET.Element:
    return ET.parse(path).getroot()


def hostdev_key(node: ET.Element) -> tuple[str, str, str, str] | None:
    source = node.find("source")
    address = source.find("address") if source is not None else None
    if address is None:
        return None
    return tuple(address.get(name, "") for name in ("domain", "bus", "slot", "function"))


def managed_domain_facts(root: ET.Element) -> dict[str, object]:
    devices = root.find("devices")
    require(devices is not None, "domínio sem devices")
    disks: list[tuple[str, str, str, str]] = []
    for disk in devices.findall("disk"):
        source = disk.find("source")
        driver = disk.find("driver")
        target = disk.find("target")
        disks.append(
            (
                source.get("file", source.get("dev", "")) if source is not None else "",
                driver.get("type", "") if driver is not None else "",
                driver.get("discard", "") if driver is not None else "",
                target.get("dev", "") if target is not None else "",
            )
        )
    interfaces = []
    for interface in devices.findall("interface"):
        mac = interface.find("mac")
        source = interface.find("source")
        interfaces.append(
            (
                mac.get("address", "").lower() if mac is not None else "",
                interface.get("type", ""),
                tuple(sorted(source.attrib.items())) if source is not None else (),
            )
        )
    hostdevs = sorted(
        (node.get("managed", ""), hostdev_key(node)) for node in devices.findall("hostdev")
    )
    cpu = root.find("cpu")
    topology = cpu.find("topology") if cpu is not None else None
    memory_backing = root.find("memoryBacking")
    huge = memory_backing.find("hugepages/page") if memory_backing is not None else None
    os_node = root.find("os")
    return {
        "disks": sorted(disks),
        "interfaces": sorted(interfaces),
        "hostdevs": hostdevs,
        "tpm": len(devices.findall("tpm")),
        "video": len(devices.findall("video")),
        "graphics": len(devices.findall("graphics")),
        "cpu": tuple(sorted(cpu.attrib.items())) if cpu is not None else (),
        "topology": tuple(sorted(topology.attrib.items())) if topology is not None else (),
        "hugepage": tuple(sorted(huge.attrib.items())) if huge is not None else (),
        "nvram": (os_node.findtext("nvram") or "") if os_node is not None else "",
    }


def validate_xml(root_dir: Path) -> None:
    xml_dir = root_dir / "xml"
    rows = parse_tsv(xml_dir / "cases.tsv")
    require(len(rows) == 9, "manifesto XML deve enumerar nove casos")
    declared = {row["fixture"] for row in rows}
    actual = {path.name for path in xml_dir.glob("*.xml")}
    require(actual <= declared, f"XML sem caso declarado: {sorted(actual - declared)}")

    one = parse_xml(xml_dir / "domain-one.xml")
    require(one.tag == "domain", "domain-one sem raiz domain")
    devices = one.find("devices")
    require(devices is not None, "domain-one sem devices")
    qcow = [d for d in devices.findall("disk") if (d.find("source") is not None and d.find("source").get("file") == "/vm/fixture.qcow2")]
    block = [d for d in devices.findall("disk") if (d.find("source") is not None and d.find("source").get("dev") == "/dev/disk/by-id/fixture-disk")]
    nics = [n for n in devices.findall("interface") if n.find("mac") is not None and n.find("mac").get("address", "").lower() == "52:54:00:12:34:56"]
    hostdevs = devices.findall("hostdev")
    one_cardinalities = (
        len(qcow), len(block), len(nics), len(devices.findall("tpm")),
        len(devices.findall("video")), len(devices.findall("graphics")),
        len(one.findall("os/nvram")), len(one.findall("cpu")),
        len(one.findall("memoryBacking/hugepages/page")),
    )
    require(all(count == 1 for count in one_cardinalities), f"domain-one não mantém cardinalidade um: {one_cardinalities}")
    require(len(hostdevs) == 2 and len({hostdev_key(n) for n in hostdevs}) == 2, "GPU/áudio não são hostdevs distintos")
    require(all(node.get("managed") == "yes" for node in hostdevs), "hostdev sem managed=yes")
    require(one.find("cpu/topology") is not None, "topologia CPU ausente")
    require(qcow[0].find("driver").get("discard") == "unmap", "discard fixture ausente")
    require(devices.get("fixture-unmanaged") == "keep" and qcow[0].find("alias") is not None, "conteúdo não gerenciado ausente")

    zero = parse_xml(xml_dir / "domain-zero.xml")
    zero_devices = zero.find("devices")
    require(zero_devices is not None, "domain-zero sem devices")
    require(not any((
        zero_devices.findall("disk"), zero_devices.findall("hostdev"),
        zero_devices.findall("interface"), zero_devices.findall("tpm"),
        zero_devices.findall("video"), zero_devices.findall("graphics"),
        zero.findall("os/nvram"), zero.findall("cpu"),
        zero.findall("memoryBacking/hugepages/page"),
    )), "domain-zero não representa cardinalidade zero")

    multiple = parse_xml(xml_dir / "domain-multiple.xml")
    multi_devices = multiple.find("devices")
    require(multi_devices is not None, "domain-multiple sem devices")
    multi_disks = multi_devices.findall("disk")
    multi_qcow = [d for d in multi_disks if d.find("source") is not None and d.find("source").get("file") == "/vm/fixture.qcow2"]
    multi_block = [d for d in multi_disks if d.find("source") is not None and d.find("source").get("dev") == "/dev/disk/by-id/fixture-disk"]
    multi_nics = [n for n in multi_devices.findall("interface") if n.find("mac") is not None and n.find("mac").get("address", "").lower() == "52:54:00:12:34:56"]
    multi_hostdevs = multi_devices.findall("hostdev")
    by_address: dict[tuple[str, str, str, str] | None, list[ET.Element]] = {}
    for node in multi_hostdevs:
        by_address.setdefault(hostdev_key(node), []).append(node)
    multi_cardinalities = (
        len(multi_qcow), len(multi_block), len(multi_nics),
        len(multi_devices.findall("tpm")), len(multi_devices.findall("video")),
        len(multi_devices.findall("graphics")), len(multiple.findall("os/nvram")),
        len(multiple.findall("cpu")), len(multiple.findall("memoryBacking/hugepages/page")),
    )
    require(all(count == 2 for count in multi_cardinalities), f"domain-multiple perdeu cardinalidade múltipla: {multi_cardinalities}")
    require(len(by_address) == 2 and all(len(nodes) == 2 for nodes in by_address.values()), "GPU/áudio múltiplos não estão duplicados por BDF")
    require(all({node.get("managed") for node in nodes} == {"yes", "no"} for nodes in by_address.values()), "atributo managed ambíguo não está representado")
    require({disk.find("driver").get("discard", "") for disk in multi_qcow} == {"", "unmap"}, "discard múltiplo/ambíguo ausente")

    try:
        parse_xml(xml_dir / "domain-malformed.xml")
    except ET.ParseError:
        pass
    else:
        fail("domain-malformed deixou de ser malformado")

    ordered = parse_xml(xml_dir / "domain-order-equivalent.xml")
    require(managed_domain_facts(one) == managed_domain_facts(ordered), "fixtures de ordem não são semanticamente equivalentes nos campos gerenciados")
    require(ordered.get("fixture-unmanaged") == "keep" and ordered.find("devices").get("fixture-unmanaged") == "keep", "equivalente perdeu atributo não gerenciado")

    hotplug = parse_xml(xml_dir / "domain-hotplug-numa.xml")
    require(hotplug.find("maxMemory") is not None and hotplug.find("vcpus") is not None, "fixture de hotplug incompleta")
    require(hotplug.find("numatune") is not None and hotplug.find("cpu/numa") is not None, "fixture NUMA incompleta")

    managed = parse_xml(xml_dir / "network-managed.xml")
    unmanaged = parse_xml(xml_dir / "network-unmanaged.xml")
    ambiguous = parse_xml(xml_dir / "network-multiple.xml")
    require(managed.findtext("description") == "vm-passthrough:60-rede-nat:v1", "marcador gerenciado inválido")
    require(unmanaged.findtext("description") != managed.findtext("description"), "rede não gerenciada usa marcador")
    require(len(ambiguous.findall("forward")) == 2 and len(ambiguous.findall("bridge")) == 2 and len(ambiguous.findall("ip/dhcp/host")) == 2, "rede ambígua perdeu cardinalidade múltipla")


def validate_qemu(root_dir: Path) -> None:
    qemu_dir = root_dir / "qemu-img"
    rows = parse_tsv(qemu_dir / "cases.tsv")
    require(len(rows) == 6, "manifesto qemu-img deve enumerar seis casos")
    valid_names = {"qcow2-backing.json", "raw.json", "chain.json", "missing-fields.json", "invalid-values.json"}
    parsed: dict[str, object] = {}
    for name in valid_names:
        parsed[name] = json.loads((qemu_dir / name).read_text(encoding="utf-8"))
    try:
        json.loads((qemu_dir / "malformed.json").read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        pass
    else:
        fail("JSON malformado passou no parser")
    qcow = parsed["qcow2-backing.json"]
    require(isinstance(qcow, dict) and qcow.get("format") == "qcow2" and qcow.get("backing-filename-format") == "qcow2", "qcow2/backing inválido")
    raw = parsed["raw.json"]
    require(isinstance(raw, dict) and raw.get("format") == "raw", "raw inválido")
    chain = parsed["chain.json"]
    require(isinstance(chain, list) and [item["format"] for item in chain] == ["qcow2", "qcow2", "raw"], "cadeia inválida")
    missing = parsed["missing-fields.json"]
    require(isinstance(missing, dict) and "virtual-size" not in missing, "fixture de campo ausente não está ausente")
    invalid = parsed["invalid-values.json"]
    require(isinstance(invalid, dict) and invalid.get("virtual-size") == -1 and not isinstance(invalid.get("filename"), str), "fixture de tipos inválidos deixou de ser inválida")


def validate_cpu_inventory(root_dir: Path) -> None:
    cpu_dir = root_dir / "cpu"
    rows = parse_tsv(cpu_dir / "cases.tsv")
    require(len(rows) == 6, "manifesto CPU deve enumerar seis casos")
    for name in ("multisocket-smt.csv", "sparse-offline-numa.csv"):
        records = []
        for line in (cpu_dir / name).read_text(encoding="utf-8").splitlines():
            if not line or line.startswith("#"):
                continue
            fields = line.split(",")
            require(len(fields) == 5, f"{name}: linha CPU inválida")
            records.append(fields)
        require(records and len({row[0] for row in records}) == len(records), f"{name}: IDs duplicados")
        require(any(row[4] == "Y" for row in records), f"{name}: sem CPU online")
    sparse = (cpu_dir / "sparse-offline-numa.csv").read_text(encoding="utf-8")
    require(",N\n" in sparse and "29,3,1,1,Y" in sparse, "fixture sparse não cobre offline/ID esparso/NUMA")

    inv_dir = root_dir / "inventory"
    inv_rows = parse_tsv(inv_dir / "cases.tsv")
    require(len(inv_rows) == 8, "manifesto de inventário deve enumerar oito casos")
    mandatory = ("== CPU ==", "== RAM ==", "== BASEBOARD ==", "== BIOS ==", "== PCI ==", "== BLOCK DEVICES ==", "== IOMMU/DMAR (pré-configuração) ==")
    for name in ("current.txt", "current-reordered.txt", "legacy.txt", "identity-changed.txt"):
        text = (inv_dir / name).read_text(encoding="utf-8")
        require(all(section in text for section in mandatory), f"inventário completo sem seção: {name}")
    truncated = (inv_dir / "truncated.txt").read_text(encoding="utf-8")
    require(any(section not in truncated for section in mandatory), "inventário truncado ficou completo")
    require("SER001" in (inv_dir / "current.txt").read_text(encoding="utf-8") and "SER999" in (inv_dir / "identity-changed.txt").read_text(encoding="utf-8"), "mudança de identidade não está representada")


def main() -> int:
    if len(sys.argv) != 2:
        print(f"uso: {Path(sys.argv[0]).name} FIXTURES_I0", file=sys.stderr)
        return 64
    root_dir = Path(sys.argv[1]).resolve()
    require(root_dir.is_dir(), f"diretório ausente: {root_dir}")
    validate_xml(root_dir)
    validate_qemu(root_dir)
    validate_cpu_inventory(root_dir)
    print("OK: intenção estrutural das fixtures I0 validada")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (AssertionError, OSError, ValueError) as exc:
        print(f"FALHA: {exc}", file=sys.stderr)
        raise SystemExit(1)
