"""Fixtures sintéticas de I3: XML de domínio, de rede e JSON do qemu-img.

Todo valor aqui é `PUBLIC` (seção 3.9): nomes, caminhos, MAC, BDF e digests são
inventados para o teste e não descrevem nenhum host real.
"""
from __future__ import annotations

QCOW2 = "/vm/fixture.qcow2"
HD1 = "/dev/disk/by-id/ata-FIXTURE_SERIAL0001"
GPU_BDF = "0000:0a:00.0"
AUDIO_BDF = "0000:0a:00.1"
NIC_MAC = "52:54:00:12:34:56"
MARCADOR = "vm-passthrough: rede gerenciada"
DIGEST = "f" * 64


def domain(
    *,
    discard: str = "",
    extra_disks: str = "",
    hostdevs: str = "",
    interfaces: str | None = None,
    features: str = "<features><acpi/><apic/></features>",
    memory_backing: str = "",
    cputune: str = "",
    cpu: str = "",
    metadata: str = "",
    graphics: str = "<graphics type='spice'/><video><model type='qxl'/></video>",
    vcpu: str = "<vcpu placement='static'>4</vcpu>",
    extra_root: str = "",
    os_block: str = "",
) -> str:
    """Monta um `<domain>` sintético com as partes que cada teste precisa."""
    if interfaces is None:
        interfaces = (
            "<interface type='network'>"
            "<mac address='%s'/><source network='default'/>"
            "<model type='virtio'/></interface>" % NIC_MAC
        )
    driver = "<driver name='qemu' type='qcow2'%s/>" % (
        " discard='%s'" % discard if discard else ""
    )
    return (
        "<domain type='kvm'>"
        "<name>fixture-win11</name>"
        "<memory unit='MiB'>8192</memory>"
        "<currentMemory unit='MiB'>8192</currentMemory>"
        + metadata
        + memory_backing
        + vcpu
        + cputune
        + os_block
        + features
        + cpu
        + extra_root
        + "<devices>"
        "<disk type='file' device='disk'>"
        + driver
        + "<source file='%s'/>" % QCOW2
        + "<target dev='vda' bus='virtio'/>"
        "</disk>"
        + extra_disks
        + hostdevs
        + interfaces
        + graphics
        + "</devices>"
        "</domain>"
    )


HOSTDEV_GPU = (
    "<hostdev mode='subsystem' type='pci' managed='yes'>"
    "<source><address domain='0x0000' bus='0x0a' slot='0x00' function='0x0'/></source>"
    "</hostdev>"
)
HOSTDEV_GPU_SEM_MANAGED = (
    "<hostdev mode='subsystem' type='pci'>"
    "<source><address domain='0x0000' bus='0x0a' slot='0x00' function='0x0'/></source>"
    "</hostdev>"
)
HOSTDEV_USB = (
    "<hostdev mode='subsystem' type='usb' managed='yes'>"
    "<source><vendor id='0x046d'/><product id='0xc52b'/></source>"
    "</hostdev>"
)
HOSTDEV_USB_SEM_DISCRIMINADOR = (
    "<hostdev mode='subsystem' type='usb' managed='yes'><source/></hostdev>"
)
DISCO_HD1 = (
    "<disk type='block' device='disk'>"
    "<driver name='qemu' type='raw' cache='none'/>"
    "<source dev='%s'/>"
    "<target dev='vdb' bus='virtio'/>"
    "</disk>" % HD1
)
DISCO_CDROM = (
    "<disk type='file' device='cdrom'>"
    "<driver name='qemu' type='raw'/>"
    "<source file='/vm/windows.iso'/>"
    "<target dev='sda' bus='sata'/>"
    "</disk>"
)


def network(
    *,
    nome: str = "vm-passthrough-nat",
    descricao: str | None = MARCADOR,
    uuid: str = "6f1d2a3b-4c5d-6e7f-8091-a2b3c4d5e6f7",
    forward: str = "<forward mode='nat' dev='enp3s0'><nat><port start='1024' end='65535'/></nat></forward>",
    bridge: str = "<bridge name='virbr9' stp='on' delay='0'/>",
    ips: str | None = None,
) -> str:
    """Monta um `<network>` sintético."""
    if ips is None:
        ips = (
            "<ip address='192.168.77.1' netmask='255.255.255.0'>"
            "<dhcp>"
            "<range start='192.168.77.100' end='192.168.77.254'/>"
            "<host mac='%s' ip='192.168.77.10'/>"
            "</dhcp>"
            "</ip>" % NIC_MAC
        )
    corpo = "<name>%s</name>" % nome
    if uuid:
        corpo += "<uuid>%s</uuid>" % uuid
    if descricao is not None:
        corpo += "<description>%s</description>" % descricao
    corpo += forward + bridge + ips
    return "<network>" + corpo + "</network>"


def snapshot(*, discos: str | None = None) -> str:
    """Monta um `<domainsnapshot>` sintético."""
    if discos is None:
        discos = (
            "<disk name='vda' snapshot='internal'/>"
            "<disk name='vdb' snapshot='no'/>"
        )
    return (
        "<domainsnapshot><name>snap-fixture</name>"
        "<disks>" + discos + "</disks></domainsnapshot>"
    )


QEMU_IMG_SIMPLES = (
    '{"virtual-size":68719476736,"filename":"/vm/fixture.qcow2",'
    '"cluster-size":65536,"format":"qcow2","actual-size":1234567}'
)
QEMU_IMG_COM_BACKING = (
    '{"virtual-size":68719476736,"filename":"/vm/overlay.qcow2",'
    '"cluster-size":65536,"format":"qcow2","actual-size":4096,'
    '"backing-filename":"/vm/fixture.qcow2",'
    '"full-backing-filename":"/vm/fixture.qcow2"}'
)
QEMU_IMG_CADEIA = (
    '[{"filename":"/vm/overlay.qcow2","format":"qcow2",'
    '"backing-filename":"/vm/fixture.qcow2",'
    '"full-backing-filename":"/vm/fixture.qcow2"},'
    '{"filename":"/vm/fixture.qcow2","format":"qcow2"}]'
)
