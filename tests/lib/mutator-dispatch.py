#!/usr/bin/env python3
"""Dispatcher stateful e fail-closed dos mutadores I0.

Executado apenas pelos wrappers criados por mutator-harness.sh. Toda escrita é
mapeada para MUTATOR_ROOT ou para a cópia temporária do projeto. Um acesso de
arquivo não mapeável termina com 126 e é registrado em forbidden.log.
"""
from __future__ import annotations

import fcntl
import json
import os
import re
import shutil
import signal
import stat
import subprocess
import sys
import time
import xml.etree.ElementTree as ET
from contextlib import contextmanager
from pathlib import Path
from typing import Callable, Iterable

HARNESS = Path(os.environ["MUTATOR_HARNESS_DIR"]).resolve()
ROOT = Path(os.environ["MUTATOR_ROOT"]).resolve()
PROJECT = Path(os.environ["MUTATOR_PROJECT"]).resolve()
STATE = Path(os.environ["MUTATOR_STATE_DIR"]).resolve()
CALL_LOG = Path(os.environ["MUTATOR_CALL_LOG"])
FORBIDDEN_LOG = Path(os.environ["MUTATOR_FORBIDDEN_LOG"])
COMMAND = sys.argv[1] if len(sys.argv) > 1 else ""
ARGS = sys.argv[2:]

# Caminhos absolutos lógicos aceitos pelos mutadores são sempre materializados
# sob ROOT. Caminhos físicos já pertencentes ao próprio harness permanecem
# intactos. /tmp não integra esta allowlist: temporários devem chegar pelo
# TMPDIR físico do harness, o que torna /tmp/escape um canário de confinamento.
LOGICAL_ROOTS = tuple(
    Path(item)
    for item in (
        "/backup",
        "/boot",
        "/dev",
        "/etc",
        "/home",
        "/mnt",
        "/opt",
        "/proc",
        "/run",
        "/srv",
        "/sys",
        "/usr/local",
        "/var",
        "/vm",
    )
)


class ExternalPathError(ValueError):
    """Tentativa de acessar um caminho absoluto fora da sandbox."""


REAL = {
    "bash": "/usr/bin/bash",
    "chmod": "/usr/bin/chmod",
    "cmp": "/usr/bin/cmp",
    "cp": "/usr/bin/cp",
    "find": "/usr/bin/find",
    "grep": "/usr/bin/grep",
    "install": "/usr/bin/install",
    "mkdir": "/usr/bin/mkdir",
    "mktemp": "/usr/bin/mktemp",
    "mv": "/usr/bin/mv",
    "rm": "/usr/bin/rm",
    "sed": "/usr/bin/sed",
    "stat": "/usr/bin/stat",
    "test": "/usr/bin/test",
    "touch": "/usr/bin/touch",
}


def sanitize(value: str) -> str:
    return value.replace("\\", "\\\\").replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t").replace("|", "\\x7c")


def load_json(name: str, default: object) -> object:
    path = STATE / name
    if not path.exists():
        return default
    return json.loads(path.read_text(encoding="utf-8"))


def save_json(name: str, value: object) -> None:
    path = STATE / name
    tmp = path.with_name(f"{path.name}.{os.getpid()}.tmp")
    tmp.write_text(json.dumps(value, sort_keys=True), encoding="utf-8")
    os.replace(tmp, path)


@contextmanager
def counter_lock():
    lock_path = STATE / "counters.lock"
    with lock_path.open("a+") as lock_stream:
        fcntl.flock(lock_stream.fileno(), fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(lock_stream.fileno(), fcntl.LOCK_UN)


def log(kind: str, key: str, detail: str = "", status: int | str = "-") -> None:
    with counter_lock():
        counters = load_json("counters.json", {"sequence": 0, "effects": 0, "calls": {}})
        assert isinstance(counters, dict)
        counters["sequence"] = int(counters.get("sequence", 0)) + 1
        save_json("counters.json", counters)
        with CALL_LOG.open("a", encoding="utf-8") as stream:
            stream.write(f"{counters['sequence']}|{kind}|{sanitize(key)}|{sanitize(detail)}|{status}\n")


def forbidden(message: str) -> int:
    with FORBIDDEN_LOG.open("a", encoding="utf-8") as stream:
        stream.write(sanitize(message) + "\n")
    log("FORBIDDEN", COMMAND, message, 126)
    print(f"mutator-harness: acesso externo recusado: {message}", file=sys.stderr)
    return 126


def is_inside(path: Path, parent: Path) -> bool:
    try:
        path.relative_to(parent)
        return True
    except ValueError:
        return False


def map_path(value: str) -> str:
    if not value.startswith("/"):
        return value
    if value == "/dev/null":
        return value

    # Normalizar antes de testar a allowlist impede escapes como
    # /etc/../../tmp/escape. resolve(strict=False) também recusa um symlink já
    # existente que aponte para fora da sandbox.
    physical = Path(value).resolve(strict=False)
    if is_inside(physical, HARNESS):
        return str(physical)

    logical = Path(os.path.normpath(value))
    if not any(logical == prefix or is_inside(logical, prefix) for prefix in LOGICAL_ROOTS):
        raise ExternalPathError(f"caminho absoluto não autorizado: {value}")
    candidate = (ROOT / logical.relative_to("/")).resolve(strict=False)
    if not is_inside(candidate, ROOT):
        raise ExternalPathError(f"caminho escapou da raiz simulada: {value}")
    return str(candidate)


def unmap_output(value: str) -> str:
    prefix = str(ROOT)
    return value.replace(prefix, "")


def path_is_mutable(path: str) -> bool:
    resolved = Path(path)
    return is_inside(resolved, ROOT) or resolved == PROJECT / "passthrough.conf"


def call_occurrence(key: str) -> int:
    with counter_lock():
        counters = load_json("counters.json", {"sequence": 0, "effects": 0, "calls": {}})
        assert isinstance(counters, dict)
        calls = counters.setdefault("calls", {})
        assert isinstance(calls, dict)
        calls[key] = int(calls.get(key, 0)) + 1
        occurrence = calls[key]
        save_json("counters.json", counters)
        return occurrence


def spec_matches(spec: str, key: str, occurrence: int) -> bool:
    if not spec:
        return False
    if "@" in spec:
        wanted, raw = spec.rsplit("@", 1)
        return wanted == key and raw.isdigit() and int(raw) == occurrence
    return spec == key


def maybe_fail_call(key: str, occurrence: int) -> int | None:
    spec = os.environ.get("MUTATOR_FAIL_CALL", "")
    if spec_matches(spec, key, occurrence):
        log("CALL_FAIL", key, f"occurrence={occurrence}", 96)
        return 96
    return None


def apply_concurrent_change() -> None:
    for name in ("vm.xml", "network-persistent.xml", "network-active.xml"):
        path = STATE / name
        if not path.exists():
            continue
        try:
            tree = ET.parse(path)
            root = tree.getroot()
            metadata = root.find("metadata")
            if metadata is None:
                metadata = ET.SubElement(root, "metadata")
            node = ET.SubElement(metadata, "i0-external-change")
            node.set("token", str(time.time_ns()))
            tree.write(path, encoding="utf-8", xml_declaration=True)
        except ET.ParseError:
            pass


def effect(key: str, action: Callable[[], int]) -> int:
    with counter_lock():
        counters = load_json("counters.json", {"sequence": 0, "effects": 0, "calls": {}})
        assert isinstance(counters, dict)
        number = int(counters.get("effects", 0)) + 1
        counters["effects"] = number
        save_json("counters.json", counters)
    log("EFFECT", key, f"effect={number}")

    if os.environ.get("MUTATOR_CONCURRENT_EFFECT") == str(number):
        apply_concurrent_change()
        log("CONCURRENT", key, f"effect={number}")

    fail_number = os.environ.get("MUTATOR_FAIL_EFFECT", "")
    fail_mode = os.environ.get("MUTATOR_FAIL_MODE", "after")
    if fail_number == str(number) and fail_mode == "before":
        log("EFFECT_FAIL", key, f"effect={number};mode=before", 97)
        return 97

    if os.environ.get("MUTATOR_DIVERGE_EFFECT") == str(number):
        rc = 0
        log("DIVERGE", key, f"effect={number};action=skipped", 0)
    else:
        rc = action()
    if rc != 0:
        log("EFFECT_ERROR", key, f"effect={number}", rc)
        return rc

    signal_number = os.environ.get("MUTATOR_SIGNAL_EFFECT", "")
    if signal_number == str(number):
        signal_name = os.environ.get("MUTATOR_SIGNAL_NAME", "TERM")
        log("SIGNAL", key, f"effect={number};signal={signal_name}")
        if signal_name == "EXIT":
            # Simula uma falha sob `set -e` que chega diretamente ao trap EXIT,
            # sem converter o caso em INT/TERM.
            return 98
        signum = signal.SIGINT if signal_name == "INT" else signal.SIGTERM
        os.kill(os.getppid(), signum)
        time.sleep(0.02)
        # Ctrl-C/TERM reais atingem o grupo em foreground, não só o shell.
        # Encerrar também o wrapper evita o falso sucesso que ocorreria se o
        # comando filho retornasse 0 depois de sinalizar apenas o pai.
        signal.signal(signum, signal.SIG_DFL)
        os.kill(os.getpid(), signum)

    if fail_number == str(number) and fail_mode == "after":
        log("EFFECT_FAIL", key, f"effect={number};mode=after", 97)
        return 97
    return 0


def run_real(command: str, args: list[str], *, data: bytes | None = None, capture: bool = False) -> subprocess.CompletedProcess[bytes]:
    executable = REAL[command]
    return subprocess.run([executable, *args], input=data, stdout=subprocess.PIPE if capture else None, stderr=None, check=False)


def map_operands(args: list[str], *, all_absolute: bool = True) -> list[str]:
    if not all_absolute:
        return list(args)
    return [map_path(arg) if arg.startswith("/") else arg for arg in args]


def existing_targets(args: Iterable[str]) -> list[str]:
    return [arg for arg in args if arg.startswith("/") and Path(map_path(arg)).exists()]


def handle_cp(args: list[str]) -> int:
    operands = [arg for arg in args if arg != "--" and not arg.startswith("-")]
    if len(operands) < 2:
        return run_real("cp", map_operands(args)).returncode
    destination = map_path(operands[-1])
    mapped = [map_path(arg) if arg in operands else arg for arg in args]
    action = lambda: run_real("cp", mapped).returncode
    if path_is_mutable(destination):
        return effect(f"fs:cp:{unmap_output(destination)}", action)
    return action()


def handle_mv(args: list[str]) -> int:
    operands = [arg for arg in args if arg != "--" and not arg.startswith("-")]
    if len(operands) < 2:
        return run_real("mv", map_operands(args)).returncode
    destination = map_path(operands[-1])
    mapped = [map_path(arg) if arg in operands else arg for arg in args]
    action = lambda: run_real("mv", mapped).returncode
    if path_is_mutable(destination) and ".tmp." not in destination:
        return effect(f"fs:mv:{unmap_output(destination)}", action)
    return action()


def mirror_airlock_remove(originals: Iterable[str]) -> None:
    bind = os.environ.get("MUTATOR_AIRLOCK_BIND", "")
    transit = os.environ.get("MUTATOR_AIRLOCK_TRANSIT", "")
    if not bind or not transit:
        return
    for original in originals:
        if not original.startswith(bind + "/"):
            continue
        peer = Path(transit + original[len(bind):])
        if peer.is_dir() and not peer.is_symlink():
            shutil.rmtree(peer)
        else:
            peer.unlink(missing_ok=True)


def handle_rm(args: list[str]) -> int:
    operands = [arg for arg in args if arg != "--" and not arg.startswith("-")]
    mapped = map_operands(args)
    targets = existing_targets(operands)
    def action() -> int:
        rc = run_real("rm", mapped).returncode
        if rc == 0:
            mirror_airlock_remove(operands)
        return rc
    mutable = [map_path(target) for target in targets if path_is_mutable(map_path(target)) and ".tmp." not in target]
    return effect(f"fs:rm:{','.join(unmap_output(item) for item in mutable)}", action) if mutable else action()


def handle_mkdir(args: list[str]) -> int:
    return run_real("mkdir", map_operands(args)).returncode


def strip_owner_options(args: list[str]) -> list[str]:
    result: list[str] = []
    skip = False
    for arg in args:
        if skip:
            skip = False
            continue
        if arg in ("-o", "-g", "--owner", "--group"):
            skip = True
            continue
        if arg.startswith("--owner=") or arg.startswith("--group="):
            continue
        result.append(arg)
    return result


def handle_install(args: list[str]) -> int:
    clean = strip_owner_options(args)
    operands = [arg for arg in clean if arg != "--" and not arg.startswith("-") and not re.fullmatch(r"[0-7]{3,4}", arg)]
    mapped = [map_path(arg) if arg in operands else arg for arg in clean]
    destination = map_path(operands[-1]) if operands else ""
    action = lambda: run_real("install", mapped).returncode
    if destination and path_is_mutable(destination) and ".tmp." not in destination and not destination.endswith("/.vm-passthrough-backups"):
        return effect(f"fs:install:{unmap_output(destination)}", action)
    return action()


def handle_chmod(args: list[str]) -> int:
    mapped = list(args)
    for index, arg in enumerate(mapped):
        if arg.startswith("--reference="):
            mapped[index] = "--reference=" + map_path(arg.split("=", 1)[1])
        elif arg.startswith("/"):
            mapped[index] = map_path(arg)
    return run_real("chmod", mapped).returncode


def mirror_airlock_touch(originals: Iterable[str]) -> None:
    bind = os.environ.get("MUTATOR_AIRLOCK_BIND", "")
    transit = os.environ.get("MUTATOR_AIRLOCK_TRANSIT", "")
    if not bind or not transit:
        return
    for original in originals:
        if original.startswith(bind + "/"):
            peer = Path(transit + original[len(bind):])
            peer.parent.mkdir(parents=True, exist_ok=True)
            peer.touch()


def handle_touch(args: list[str]) -> int:
    operands = [arg for arg in args if arg != "--" and not arg.startswith("-")]
    mapped = [map_path(arg) if arg in operands else arg for arg in args]
    def action() -> int:
        rc = run_real("touch", mapped).returncode
        if rc == 0:
            # Simula a visibilidade da mesma mutação através do bindfs.
            mirror_airlock_touch(operands)
        return rc
    mutable = [map_path(arg) for arg in operands if path_is_mutable(map_path(arg))]
    return effect(f"fs:touch:{','.join(unmap_output(item) for item in mutable)}", action) if mutable else action()


def handle_tee(args: list[str], data: bytes) -> int:
    append = "-a" in args or "--append" in args
    files = [arg for arg in args if arg != "--" and not arg.startswith("-")]
    if not files:
        sys.stdout.buffer.write(data)
        return 0
    mapped = [map_path(arg) if arg in files else arg for arg in args]

    def action() -> int:
        completed = run_real("bash", ["-c", "exec /usr/bin/tee \"$@\"", "tee", *mapped], data=data, capture=True)
        if completed.stdout:
            sys.stdout.buffer.write(completed.stdout)
        return completed.returncode

    mutable = [map_path(item) for item in files if path_is_mutable(map_path(item))]
    if mutable:
        return effect(f"fs:tee:{','.join(unmap_output(item) for item in mutable)}", action)
    return action()


def handle_sed(args: list[str]) -> int:
    mapped = list(args)
    in_place = any(arg == "-i" or arg.startswith("-i") or arg.startswith("--in-place") for arg in args)
    if in_place:
        for index in range(len(mapped) - 1, -1, -1):
            if mapped[index].startswith("/"):
                mapped[index] = map_path(mapped[index])
                break
    return run_real("sed", mapped).returncode


def handle_grep(args: list[str]) -> int:
    mapped = list(args)
    positional: list[int] = []
    option_argument = False
    for index, arg in enumerate(args):
        if option_argument:
            option_argument = False
            continue
        if arg in ("-e", "-f", "--regexp", "--file"):
            option_argument = True
            continue
        if arg.startswith("-"):
            continue
        positional.append(index)
    # Primeiro posicional é o padrão; os demais são arquivos.
    for index in positional[1:]:
        if args[index].startswith("/"):
            mapped[index] = map_path(args[index])
    return run_real("grep", mapped).returncode


def handle_find(args: list[str]) -> int:
    mapped = list(args)
    if mapped and mapped[0].startswith("/"):
        mapped[0] = map_path(mapped[0])
    completed = run_real("find", mapped, capture=True)
    if completed.stdout:
        sys.stdout.write(unmap_output(completed.stdout.decode(errors="replace")))
    return completed.returncode


def handle_stat(args: list[str]) -> int:
    if any(arg in ("%u", "%g") for arg in args):
        print("0")
        return 0
    return run_real("stat", map_operands(args)).returncode


def handle_mktemp(args: list[str]) -> int:
    mapped = [map_path(arg) if arg.startswith("/") else arg for arg in args]
    completed = run_real("mktemp", mapped, capture=True)
    if completed.stdout:
        sys.stdout.write(unmap_output(completed.stdout.decode()))
    return completed.returncode


def handle_test(args: list[str]) -> int:
    return run_real("test", map_operands(args)).returncode


def handle_bash(args: list[str]) -> int:
    mapped = [map_path(arg) if arg.startswith("/") and not is_inside(Path(arg), HARNESS) else arg for arg in args]
    return run_real("bash", mapped).returncode


def handle_fs(command: str, args: list[str], data: bytes) -> int:
    if command == "cp":
        return handle_cp(args)
    if command == "mv":
        return handle_mv(args)
    if command == "rm":
        return handle_rm(args)
    if command == "mkdir":
        return handle_mkdir(args)
    if command == "install":
        return handle_install(args)
    if command == "chmod":
        return handle_chmod(args)
    if command == "cmp":
        return run_real("cmp", map_operands(args)).returncode
    if command in ("chown", "chgrp"):
        return 0
    if command == "touch":
        return handle_touch(args)
    if command == "tee":
        return handle_tee(args, data)
    if command == "sed":
        return handle_sed(args)
    if command == "grep":
        return handle_grep(args)
    if command == "find":
        return handle_find(args)
    if command == "stat":
        return handle_stat(args)
    if command == "mktemp":
        return handle_mktemp(args)
    if command == "test":
        return handle_test(args)
    if command == "bash":
        return handle_bash(args)
    raise AssertionError(command)


def strip_virsh_connection(args: list[str]) -> list[str]:
    result = list(args)
    if len(result) >= 2 and result[0] == "--connect":
        result = result[2:]
    return result


def copy_xml(source: str, destination: Path) -> int:
    try:
        ET.parse(source)
        shutil.copyfile(source, destination)
        return 0
    except (OSError, ET.ParseError) as exc:
        print(f"virsh fixture: {exc}", file=sys.stderr)
        return 1


def virsh_shape_is_modeled(command: str, rest: list[str]) -> bool:
    def scalar(value: str) -> bool:
        return bool(value) and not value.startswith("-")

    if command in ("dominfo", "domstate", "net-info", "net-start", "net-destroy", "net-undefine"):
        return len(rest) == 1 and scalar(rest[0])
    if command in ("dumpxml", "net-dumpxml"):
        return (
            (len(rest) == 1 and scalar(rest[0]))
            or (len(rest) == 2 and rest[0] == "--inactive" and scalar(rest[1]))
            or (len(rest) == 2 and scalar(rest[0]) and rest[1] == "--inactive")
        )
    if command == "define":
        return (
            (len(rest) == 1 and scalar(rest[0]))
            or (len(rest) == 2 and rest[0] == "--validate" and scalar(rest[1]))
        )
    if command == "attach-device":
        return len(rest) == 3 and scalar(rest[0]) and scalar(rest[1]) and rest[2] == "--config"
    if command == "help":
        return rest == ["define"]
    if command == "list":
        return rest in (["--name"], ["--all"], ["--all", "--name"])
    if command == "net-list":
        return rest == ["--all", "--name"]
    if command in ("net-define", "net-create"):
        return len(rest) == 1 and scalar(rest[0])
    if command == "net-autostart":
        return (
            (len(rest) == 1 and scalar(rest[0]))
            or (len(rest) == 2 and scalar(rest[0]) and rest[1] == "--disable")
            or (len(rest) == 2 and rest[0] == "--disable" and scalar(rest[1]))
        )
    return False


def handle_virsh(args: list[str]) -> int:
    if args[:1] == ["--connect"] and (len(args) < 3 or args[1] != "qemu:///system"):
        return forbidden(f"conexão virsh não modelada: {' '.join(args)}")
    args = strip_virsh_connection(args)
    if not args:
        return 64
    command = args[0]
    rest = args[1:]
    if not virsh_shape_is_modeled(command, rest):
        return forbidden(f"assinatura virsh não modelada: {command} {' '.join(rest)}".rstrip())
    key = f"virsh:{command}"
    occurrence = call_occurrence(key)
    failure = maybe_fail_call(key, occurrence)
    if failure is not None:
        return failure
    log("CALL", key, " ".join(rest))

    vm_xml = STATE / "vm.xml"
    persistent = STATE / "network-persistent.xml"
    active = STATE / "network-active.xml"
    autostart = STATE / "network-autostart"

    if command == "dominfo":
        print("Id:             -\nName:           fixture-win11\nState:          shut off")
        return 0
    if command == "domstate":
        print("shut off")
        return 0
    if command == "dumpxml":
        domains = [item for item in rest if not item.startswith("-")]
        source = STATE / "other-vm.xml" if domains and domains[-1] == "other-vm" else vm_xml
        if not source.exists():
            return 1
        sys.stdout.buffer.write(source.read_bytes())
        return 0
    if command == "define":
        files = [item for item in rest if not item.startswith("-")]
        if not files:
            return 1
        source = map_path(files[-1])
        return effect("virsh:define", lambda: copy_xml(source, vm_xml))
    if command == "attach-device":
        files = [item for item in rest[1:] if not item.startswith("-")]
        if not files:
            return 1
        fragment = map_path(files[0])

        def attach() -> int:
            try:
                tree = ET.parse(vm_xml)
                devices = tree.getroot().find("devices")
                if devices is None:
                    return 1
                devices.append(ET.parse(fragment).getroot())
                tree.write(vm_xml, encoding="utf-8", xml_declaration=True)
                return 0
            except (OSError, ET.ParseError):
                return 1

        return effect("virsh:attach-device", attach)
    if command == "help" and rest[:1] == ["define"]:
        print("define [--validate] FILE")
        return 0
    if command == "list":
        names = ["fixture-win11"]
        if (STATE / "other-vm.xml").exists() and ("--all" in rest or (STATE / "other-vm-active").exists()):
            names.append("other-vm")
        print("\n".join(names))
        return 0
    if command == "net-list":
        if persistent.exists() or active.exists():
            print("passthrough-nat")
        return 0
    if command == "net-info":
        if not persistent.exists() and not active.exists():
            return 1
        print("Name:           passthrough-nat")
        print(f"Active:         {'yes' if active.exists() else 'no'}")
        print(f"Persistent:     {'yes' if persistent.exists() else 'no'}")
        print(f"Autostart:      {'yes' if autostart.exists() else 'no'}")
        return 0
    if command == "net-dumpxml":
        use_persistent = "--inactive" in rest
        source = persistent if use_persistent else active
        if not source.exists():
            return 1
        sys.stdout.buffer.write(source.read_bytes())
        return 0
    if command in ("net-define", "net-create"):
        files = [item for item in rest if not item.startswith("-")]
        if not files:
            return 1
        source = map_path(files[-1])
        destination = persistent if command == "net-define" else active
        return effect(f"virsh:{command}", lambda: copy_xml(source, destination))
    if command == "net-start":
        return effect("virsh:net-start", lambda: copy_xml(str(persistent), active) if persistent.exists() else 1)
    if command == "net-destroy":
        def destroy() -> int:
            active.unlink(missing_ok=True)
            return 0
        return effect("virsh:net-destroy", destroy)
    if command == "net-undefine":
        def undefine() -> int:
            persistent.unlink(missing_ok=True)
            autostart.unlink(missing_ok=True)
            return 0
        return effect("virsh:net-undefine", undefine)
    if command == "net-autostart":
        disable = "--disable" in rest
        def set_autostart() -> int:
            if disable:
                autostart.unlink(missing_ok=True)
            else:
                autostart.touch()
            return 0
        return effect("virsh:net-autostart", set_autostart)
    return forbidden(f"operação virsh não modelada: {command} {' '.join(rest)}".rstrip())


def interface_nodes(root: ET.Element, expression: str) -> list[ET.Element]:
    devices = root.find("devices")
    if devices is None:
        return []
    nodes = devices.findall("interface")
    mac_match = re.search(r"translate\(mac/@address,'ABCDEF','abcdef'\)='([^']+)'", expression)
    if mac_match:
        wanted = mac_match.group(1).lower()
        nodes = [node for node in nodes if node.find("mac") is not None and node.find("mac").get("address", "").lower() == wanted]
    return nodes


def hostdev_count(root: ET.Element, expression: str) -> int:
    devices = root.find("devices")
    if devices is None:
        return 0
    values = dict(re.findall(r"@(domain|bus|slot|function)='([^']+)'", expression))
    exact_parent = "hostdev[@mode='subsystem'" in expression
    count = 0
    for hostdev in devices.findall("hostdev"):
        address = hostdev.find("source/address")
        if address is None or any(address.get(key) != value for key, value in values.items()):
            continue
        if exact_parent and not (hostdev.get("mode") == "subsystem" and hostdev.get("type") == "pci" and hostdev.get("managed") == "yes"):
            continue
        count += 1
    return count


def disk_count(root: ET.Element, expression: str) -> int:
    devices = root.find("devices")
    if devices is None:
        return 0
    dev_match = re.search(r"source/@dev='([^']+)'", expression)
    target_match = re.search(r"target\[@dev='([^']+)'\]", expression)
    count = 0
    for disk in devices.findall("disk"):
        source = disk.find("source")
        target = disk.find("target")
        driver = disk.find("driver")
        if dev_match and (source is None or source.get("dev") != dev_match.group(1)):
            continue
        if target_match and (target is None or target.get("dev") != target_match.group(1)):
            continue
        if "disk[@type='block'" in expression:
            if not (disk.get("type") == "block" and disk.get("device") == "disk" and driver is not None and driver.get("name") == "qemu" and driver.get("type") == "raw" and driver.get("cache") == "none" and target is not None and target.get("dev") == "vdb" and target.get("bus") == "virtio"):
                continue
        count += 1
    return count


def network_host_nodes(root: ET.Element, expression: str) -> list[ET.Element]:
    nodes = root.findall("./ip/dhcp/host")
    mac = re.search(r"translate\(@mac,'ABCDEF','abcdef'\)='([^']+)'", expression)
    ip = re.search(r"@ip='([^']+)'", expression)
    if mac:
        nodes = [node for node in nodes if node.get("mac", "").lower() == mac.group(1).lower()]
    if ip:
        nodes = [node for node in nodes if node.get("ip") == ip.group(1)]
    return nodes


def simple_string(root: ET.Element, expression: str) -> str:
    expression = expression.strip()
    if expression.startswith("string(") and expression.endswith(")"):
        expression = expression[7:-1]
    expression = expression.replace("[1]", "")
    if expression.startswith("/domain/devices/interface["):
        nodes = interface_nodes(root, expression)
        if not nodes:
            return ""
        node = nodes[0]
        if expression.endswith("/@type"):
            return node.get("type", "")
        source_attr = re.search(r"/source/@([A-Za-z0-9_-]+)$", expression)
        if source_attr:
            source = node.find("source")
            return source.get(source_attr.group(1), "") if source is not None else ""
    if expression.startswith("/network/ip/dhcp/host["):
        nodes = network_host_nodes(root, expression)
        if not nodes:
            return ""
        attr = re.search(r"/@([A-Za-z0-9_-]+)$", expression)
        return nodes[0].get(attr.group(1), "") if attr else (nodes[0].text or "")
    parts = [part for part in expression.strip("/").split("/") if part]
    if not parts or parts[0] != root.tag:
        return ""
    node = root
    for part in parts[1:]:
        if part.startswith("@"):
            return node.get(part[1:], "")
        child = node.find(part)
        if child is None:
            return ""
        node = child
    return (node.text or "").strip()


def eval_xpath(root: ET.Element, expression: str) -> str:
    expression = expression.strip()
    if expression.startswith("count(") and expression.endswith(")"):
        inner = expression[6:-1]
        if "/hostdev" in inner:
            return str(hostdev_count(root, inner))
        if "/disk" in inner:
            return str(disk_count(root, inner))
        if inner.startswith("/domain/devices/interface"):
            nodes = interface_nodes(root, inner)
            if "source/@network=" in inner or "source/@bridge=" in inner:
                values = re.findall(r"source/@(?:network|bridge|dev)='([^']+)'", inner)
                nodes = [node for node in nodes if node.find("source") is not None and any(value in node.find("source").attrib.values() for value in values)]
            return str(len(nodes))
        if inner.startswith("/network/ip/dhcp/host"):
            return str(len(network_host_nodes(root, inner)))
        path = inner.strip("/").split("/", 1)[-1]
        return str(len(root.findall(path)))
    return simple_string(root, expression)


def xml_source(args: list[str]) -> tuple[ET.ElementTree, str | None]:
    candidate: str | None = None
    if args and not args[-1].startswith("-") and Path(map_path(args[-1])).is_file():
        candidate = map_path(args[-1])
        return ET.parse(candidate), candidate
    data = sys.stdin.buffer.read()
    return ET.ElementTree(ET.fromstring(data)), None


def domain_interface_selector_is_modeled(expression: str) -> bool:
    return re.fullmatch(
        r"/domain/devices/interface\[translate\(mac/@address,'ABCDEF','abcdef'\)='[0-9a-f]{2}(?::[0-9a-f]{2}){5}'\]",
        expression,
    ) is not None


def network_host_selector_is_modeled(expression: str) -> bool:
    return re.fullmatch(
        r"/network/ip/dhcp/host\[translate\(@mac,'ABCDEF','abcdef'\)='[0-9a-f]{2}(?::[0-9a-f]{2}){5}'\]",
        expression,
    ) is not None


def xml_count_xpath_is_modeled(expression: str) -> bool:
    pci_address = (
        r"/source/address\[@domain='0x[0-9a-fA-F]+' and @bus='0x[0-9a-fA-F]+' "
        r"and @slot='0x[0-9a-fA-F]+' and @function='0x[0-7]'\]"
    )
    if re.fullmatch(r"/domain/devices/hostdev" + pci_address, expression):
        return True
    if re.fullmatch(
        r"/domain/devices/hostdev\[@mode='subsystem' and @type='pci' and @managed='yes'\]" + pci_address,
        expression,
    ):
        return True
    if re.fullmatch(r"/domain/devices/disk/source\[@dev='[^']+'\]", expression):
        return True
    if re.fullmatch(
        r"/domain/devices/disk\[@type='block' and @device='disk' and driver/@name='qemu' "
        r"and driver/@type='raw' and driver/@cache='none' and source/@dev='[^']+' "
        r"and target/@dev='vdb' and target/@bus='virtio'\]",
        expression,
    ):
        return True
    if expression == "/domain/devices/disk/target[@dev='vdb']":
        return True
    if domain_interface_selector_is_modeled(expression) or network_host_selector_is_modeled(expression):
        return True
    if re.fullmatch(
        r"/domain/devices/interface\[source/@network='[A-Za-z0-9_.:-]+' or "
        r"source/@bridge='[A-Za-z0-9_.:-]+' or source/@bridge='[A-Za-z0-9_.:-]+'\]",
        expression,
    ):
        return True
    if expression.endswith("[mac/@address]") and domain_interface_selector_is_modeled(expression[:-len("[mac/@address]")]):
        return True
    return re.fullmatch(r"/network/ip/dhcp/host\[@ip='(?:[0-9]{1,3}\.){3}[0-9]{1,3}'\]", expression) is not None


def xml_xpath_is_modeled(expression: str) -> bool:
    expression = expression.strip()
    wrapper = ""
    if expression.startswith("count(") and expression.endswith(")"):
        wrapper = "count"
        expression = expression[6:-1]
    elif expression.startswith("string(") and expression.endswith(")"):
        wrapper = "string"
        expression = expression[7:-1]

    if wrapper == "count":
        return xml_count_xpath_is_modeled(expression)
    if wrapper == "string":
        for suffix in ("/@type", "/source/@network", "/source/@bridge", "/source/@dev"):
            if expression.endswith(suffix) and domain_interface_selector_is_modeled(expression[:-len(suffix)]):
                return True
        for suffix in ("/@ip", "/@mac"):
            if expression.endswith(suffix) and network_host_selector_is_modeled(expression[:-len(suffix)]):
                return True
        return expression in {
            "/network/description",
            "/network/uuid",
            "/network/forward/@mode",
            "/network/forward/@dev",
            "/network/bridge/@name",
            "/network/ip/@address",
            "/network/ip/@prefix",
            "/network/ip/@netmask",
            "/network/ip[1]/@address",
            "/network/ip[1]/@prefix",
            "/network/ip[1]/@netmask",
            "/network/ip/dhcp/range/@start",
            "/network/ip/dhcp/range/@end",
        }
    return False


def xmlstarlet_shape_is_modeled(args: list[str]) -> bool:
    mode = args[0] if args else ""
    tokens = args[1:]
    if mode == "sel":
        if not tokens or tokens[0] != "-t":
            return False
        index = 1
        actions = 0
        match_expression = ""
        while index < len(tokens):
            token = tokens[index]
            if token in ("-v", "-o", "-c", "-m"):
                if index + 1 >= len(tokens):
                    return False
                operand = tokens[index + 1]
                if token == "-m":
                    if operand not in ("/domain/devices/interface", "/network/ip[@address]"):
                        return False
                    match_expression = operand
                elif token == "-c":
                    if operand not in ("/domain/features/hyperv", "/domain/features/kvm"):
                        return False
                elif token == "-v":
                    if match_expression == "/domain/devices/interface":
                        if operand not in (
                            "mac/@address", "@type", "source/@network",
                            "concat(source/@network,source/@bridge,source/@dev)",
                        ):
                            return False
                    elif match_expression == "/network/ip[@address]":
                        if operand not in ("@address", "@prefix", "@netmask"):
                            return False
                    elif not xml_xpath_is_modeled(operand):
                        return False
                actions += 1
                index += 2
            elif token == "-n":
                index += 1
            elif index == len(tokens) - 1 and not token.startswith("-"):
                index += 1
            else:
                return False
        return actions > 0
    if mode == "ed":
        if len(tokens) < 2 or tokens[-1].startswith("-"):
            return False
        operations = tokens[:-1]
        index = 0
        actions = 0
        while index < len(operations):
            token = operations[index]
            if token == "-L":
                index += 1
                continue
            if token == "-d":
                if index + 1 >= len(operations):
                    return False
                actions += 1
                index += 2
                continue
            if token in ("-i", "-s"):
                if index + 7 >= len(operations):
                    return False
                expected_type = "attr" if token == "-i" else "elem"
                if (
                    operations[index + 2:index + 4] != ["-t", expected_type]
                    or operations[index + 4] != "-n"
                    or operations[index + 6] != "-v"
                ):
                    return False
                actions += 1
                index += 8
                continue
            return False
        return actions > 0
    return False


def xml_edit_operation_is_modeled(kind: str, path: str, name: str, value: str) -> bool:
    disk_driver = re.fullmatch(
        r"/domain/devices/disk\[@device='disk'\]\[source/@file='[^']+'\]/driver",
        path.removesuffix("/@discard"),
    ) is not None
    if kind == "delete" and path.endswith("/driver/@discard"):
        return disk_driver
    if kind == "insert" and path.endswith("/driver"):
        return disk_driver and name == "discard" and value == "unmap"

    if kind == "delete":
        for suffix in ("/@type", "/source"):
            if path.endswith(suffix) and domain_interface_selector_is_modeled(path[:-len(suffix)]):
                return True
    if kind == "insert" and path.endswith("[not(@type)]"):
        base = path[:-len("[not(@type)]")]
        return domain_interface_selector_is_modeled(base) and name == "type"
    if kind == "subnode" and domain_interface_selector_is_modeled(path):
        return name == "source"
    if kind == "insert" and name in ("network", "bridge", "dev"):
        suffix = f"/source[not(@{name})]"
        return path.endswith(suffix) and domain_interface_selector_is_modeled(path[:-len(suffix)])

    if kind == "delete" and path in (
        "/domain/devices/graphics",
        "/domain/devices/video",
        "/domain/devices/channel[@type='spicevmc']",
        "/domain/devices/redirdev",
        "/domain/devices/sound",
        "/domain/devices/audio",
        "/domain/features/hyperv/vendor_id",
        "/domain/features/kvm/hidden",
    ):
        return True
    if kind == "subnode":
        return (path, name) in (
            ("/domain/features", "hyperv"),
            ("/domain/features", "kvm"),
            ("/domain/features/hyperv", "vendor_id"),
            ("/domain/features/kvm", "hidden"),
        )
    if kind == "insert" and path == "/domain/features/hyperv/vendor_id":
        return (name, value) in (("state", "on"), ("value", "randomid123"))
    if kind == "insert" and path == "/domain/features/kvm/hidden":
        return (name, value) == ("state", "on")
    return False


def handle_xmlstarlet(args: list[str]) -> int:
    if not args:
        return 64
    mode = args[0]
    if not xmlstarlet_shape_is_modeled(args):
        return forbidden(f"assinatura xmlstarlet não modelada: {' '.join(args)}")
    key = f"xmlstarlet:{mode}"
    occurrence = call_occurrence(key)
    failure = maybe_fail_call(key, occurrence)
    if failure is not None:
        return failure
    log("CALL", key, " ".join(args[1:]))
    try:
        tree, filename = xml_source(args[1:])
        root = tree.getroot()
        if mode == "sel":
            tokens = args[1:]
            if filename is not None:
                tokens = tokens[:-1]
            if "-m" in tokens:
                match_index = tokens.index("-m")
                match_expr = tokens[match_index + 1]
                if match_expr == "/domain/devices/interface":
                    nodes = root.findall("./devices/interface")
                elif match_expr == "/network/ip[@address]":
                    nodes = [node for node in root.findall("./ip") if node.get("address")]
                else:
                    return 1
                output = []
                for node in nodes:
                    index = match_index + 2
                    line = ""
                    while index < len(tokens):
                        token = tokens[index]
                        if token == "-v":
                            rel = tokens[index + 1]
                            if rel.startswith("@"):
                                line += node.get(rel[1:], "")
                            elif rel == "mac/@address":
                                child = node.find("mac"); line += child.get("address", "") if child is not None else ""
                            elif rel == "source/@network":
                                child = node.find("source"); line += child.get("network", "") if child is not None else ""
                            elif rel.startswith("concat("):
                                child = node.find("source"); line += next(iter(child.attrib.values()), "") if child is not None else ""
                            index += 2
                        elif token == "-o":
                            line += tokens[index + 1]; index += 2
                        elif token == "-n":
                            output.append(line); line = ""; index += 1
                        else:
                            index += 1
                    if line:
                        output.append(line)
                print("\n".join(output))
                return 0
            output = ""
            index = 0
            while index < len(tokens):
                token = tokens[index]
                if token == "-v":
                    output += eval_xpath(root, tokens[index + 1]); index += 2
                elif token == "-o":
                    output += tokens[index + 1]; index += 2
                elif token == "-n":
                    output += "\n"; index += 1
                elif token == "-c":
                    expression = tokens[index + 1]
                    if expression in ("/domain/features/hyperv", "/domain/features/kvm"):
                        node = root.find(expression.removeprefix("/domain/"))
                        if node is None:
                            return 1
                        output += ET.tostring(node, encoding="unicode")
                    else:
                        return 1
                    index += 2
                else:
                    index += 1
            sys.stdout.write(output)
            return 0
        if mode == "ed":
            if filename is None:
                return 1
            tokens = args[1:-1]
            operations: list[tuple[str, str, str, str]] = []
            index = 0
            while index < len(tokens):
                if tokens[index] in ("-L",):
                    index += 1; continue
                if tokens[index] == "-d":
                    operations.append(("delete", tokens[index + 1], "", "")); index += 2; continue
                if tokens[index] in ("-i", "-s"):
                    kind = "insert" if tokens[index] == "-i" else "subnode"
                    path = tokens[index + 1]
                    name = tokens[index + 5] if index + 5 < len(tokens) and tokens[index + 4] == "-n" else ""
                    value = tokens[index + 7] if index + 7 < len(tokens) and tokens[index + 6] == "-v" else ""
                    operations.append((kind, path, name, value)); index += 8; continue
                index += 1

            def target_interfaces(path: str) -> list[ET.Element]:
                return interface_nodes(root, path)

            for kind, path, name, value in operations:
                if not xml_edit_operation_is_modeled(kind, path, name, value):
                    return forbidden(f"edição xmlstarlet não modelada: {kind} {path} {name} {value}".rstrip())
                if kind == "delete" and "/disk[" in path and path.endswith("/driver/@discard"):
                    target = re.search(r"source/@file='([^']+)'", path)
                    for disk in root.findall("./devices/disk"):
                        source = disk.find("source"); driver = disk.find("driver")
                        if target and source is not None and source.get("file") == target.group(1) and driver is not None:
                            driver.attrib.pop("discard", None)
                elif kind == "insert" and "/disk[" in path and path.endswith("/driver") and name:
                    target = re.search(r"source/@file='([^']+)'", path)
                    for disk in root.findall("./devices/disk"):
                        source = disk.find("source"); driver = disk.find("driver")
                        if target and source is not None and source.get("file") == target.group(1) and driver is not None:
                            driver.set(name, value)
                elif "/domain/devices/interface[" in path:
                    nodes = target_interfaces(path)
                    if kind == "delete" and path.endswith("/@type"):
                        for node in nodes: node.attrib.pop("type", None)
                    elif kind == "delete" and path.endswith("/source"):
                        for node in nodes:
                            source = node.find("source")
                            if source is not None: node.remove(source)
                    elif kind == "insert" and path.endswith("[not(@type)]"):
                        for node in nodes: node.set(name, value)
                    elif kind == "subnode":
                        for node in nodes: ET.SubElement(node, name).text = value
                    elif kind == "insert" and "/source[not(@" in path:
                        for node in nodes:
                            source = node.find("source")
                            if source is not None: source.set(name, value)
                elif kind == "delete" and path.startswith("/domain/devices/"):
                    tag = path.split("/")[-1].split("[")[0]
                    devices = root.find("devices")
                    if devices is not None:
                        for node in list(devices):
                            if node.tag == tag: devices.remove(node)
                elif kind == "subnode" and path in ("/domain/features", "/domain/features/hyperv", "/domain/features/kvm"):
                    parent_path = path.removeprefix("/domain/")
                    parent = root.find(parent_path)
                    if parent is not None and name:
                        ET.SubElement(parent, name).text = value
                elif path.startswith("/domain/features/hyperv/vendor_id") or path.startswith("/domain/features/kvm/hidden"):
                    parent_path, child_name = (
                        ("features/hyperv", "vendor_id")
                        if "/hyperv/" in path
                        else ("features/kvm", "hidden")
                    )
                    parent = root.find(parent_path)
                    if parent is not None:
                        child = parent.find(child_name)
                        if kind == "delete" and child is not None:
                            parent.remove(child)
                        elif kind == "insert" and child is not None:
                            child.set(name, value)
            tree.write(filename, encoding="utf-8", xml_declaration=True)
            return 0
    except (ET.ParseError, OSError, ValueError) as exc:
        print(f"xmlstarlet fixture: {exc}", file=sys.stderr)
        return 1
    return 1


def handle_ip(args: list[str]) -> int:
    key = "ip:" + (args[0] if args else "")
    occurrence = call_occurrence(key)
    failure = maybe_fail_call(key, occurrence)
    if failure is not None:
        return failure
    log("CALL", key, " ".join(args))
    bridge_active = (STATE / "bridge-active").exists()

    if args == ["-4", "route", "get", "1.1.1.1"]:
        print("1.1.1.1 via 10.0.0.1 dev enp3s0 src 10.0.0.2 uid 1000")
        return 0
    if args == ["-4", "route", "show", "table", "all"]:
        if (STATE / "route-collision").exists():
            print("192.168.177.0/24 dev enp9s0 proto kernel scope link src 192.168.177.2")
        return 0
    if (
        len(args) in (6, 8)
        and args[:5] == ["-4", "-o", "addr", "show", "dev"]
        and (len(args) == 6 or args[6:] == ["scope", "global"])
    ):
        interface = args[5]
        if interface == "virbr-vmnat":
            print("7: virbr-vmnat    inet 192.168.177.1/24 brd 192.168.177.255 scope global virbr-vmnat")
        elif interface == "br0":
            print("8: br0    inet 10.0.0.2/24 brd 10.0.0.255 scope global br0")
        else:
            print(f"2: {interface}    inet 10.0.0.2/24 brd 10.0.0.255 scope global {interface}")
        return 0
    if len(args) in (3, 4) and args[:3] == ["-o", "link", "show"]:
        if len(args) == 3:
            print("2: enp3s0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 state UP")
            return 0
        interface = args[3]
        if interface == "br0":
            if not bridge_active:
                return 1
            print("8: br0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 state UP")
        elif interface == "enp3s0":
            suffix = " master br0" if bridge_active else ""
            print(f"2: enp3s0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500{suffix} state UP")
        else:
            print(f"7: {interface}: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 state UP")
        return 0
    if len(args) == 3 and args[:2] == ["link", "show"]:
        interface = args[2]
        print(f"2: {interface}: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500\n    link/ether 02:00:00:00:00:01")
        return 0
    if len(args) == 3 and args[:2] == ["addr", "show"]:
        interface = args[2]
        print(f"8: {interface}: <UP> mtu 1500\n    inet 10.0.0.2/24 scope global {interface}")
        return 0
    return forbidden(f"operação ip não modelada: {' '.join(args)}".rstrip())


GRUB_DEFAULT = "etc/default/grub"
GRUB_CFG = "boot/grub/grub.cfg"


def regenerate_grub_cfg() -> None:
    """Reescreve o grub.cfg simulado a partir de GRUB_CMDLINE_LINUX_DEFAULT.

    Mantém uma entrada normal, que herda a linha padrão, e uma de recuperação,
    que deliberadamente não herda: é o mesmo formato que a validação efetiva de
    `_grub_cfg_parametros_exatos` precisa tolerar em host real.
    """
    origem = ROOT / GRUB_DEFAULT
    destino = ROOT / GRUB_CFG
    parametros = ""
    if origem.is_file():
        for linha in origem.read_text(encoding="utf-8").splitlines():
            if linha.startswith("GRUB_CMDLINE_LINUX_DEFAULT="):
                valor = linha.partition("=")[2].strip()
                if len(valor) >= 2 and valor[0] == '"' and valor[-1] == '"':
                    parametros = valor[1:-1]
    destino.parent.mkdir(parents=True, exist_ok=True)
    destino.write_text(
        "menuentry normal {\n"
        " linux /vmlinuz root=/dev/fixture %s\n"
        "}\n"
        "menuentry recovery {\n"
        " linux /vmlinuz root=/dev/fixture recovery nomodeset\n"
        "}\n" % parametros,
        encoding="utf-8",
    )


def simple_effect(key: str, action: Callable[[], None] | None = None) -> int:
    def wrapped() -> int:
        if action:
            action()
        return 0
    return effect(key, wrapped)


def ipv4_fixture_scalar(value: str) -> bool:
    parts = value.split(".")
    return len(parts) == 4 and all(part.isdigit() and 0 <= int(part) <= 255 for part in parts)


def ufw_allow_shape_is_modeled(args: list[str]) -> bool:
    if len(args) == 11:
        return (
            args[0] == "allow"
            and args[1] == "from"
            and ipv4_fixture_scalar(args[2])
            and args[3:10] == ["to", "any", "port", "22", "proto", "tcp", "comment"]
            and bool(args[10])
        )
    if len(args) == 14:
        return (
            args[:3] == ["allow", "in", "on"]
            and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.:-]*", args[3]) is not None
            and args[4] == "from"
            and ipv4_fixture_scalar(args[5])
            and args[6:13] == ["to", "any", "port", "22", "proto", "tcp", "comment"]
            and bool(args[13])
        )
    return False


def systemd_unit_table() -> dict[str, tuple[str, str, str, str]]:
    """Estado declarado das unidades systemd, mantido pelo harness."""
    path = STATE / "systemd-units"
    table: dict[str, tuple[str, str, str, str]] = {}
    if not path.exists():
        return table
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line or line.startswith("#"):
            continue
        fields = line.split("|")
        if len(fields) != 5:
            continue
        table[fields[0]] = (fields[1], fields[2], fields[3], fields[4])
    return table


def systemctl_show(unit: str, options: list[str]) -> int:
    """Responde `systemctl show` a partir da tabela do harness.

    Sem entrada na tabela, a unidade é reportada como not-found, o que é
    exatamente o que o systemd faz e o que a resolução precisa distinguir.
    """
    load, active, sub, unit_file = systemd_unit_table().get(
        unit, ("not-found", "inactive", "dead", "")
    )
    values = {
        "LoadState": load,
        "ActiveState": active,
        "SubState": sub,
        "UnitFileState": unit_file,
    }
    wanted = [
        item[len("--property=") :]
        for item in options
        if item.startswith("--property=")
    ] or list(values)
    for name in wanted:
        if name not in values:
            return forbidden(f"propriedade systemd não modelada: {name}")
        print(f"{name}={values[name]}")
    return 0


def systemctl_is_active(unit: str) -> int:
    """Pós-condição de restart: ativa somente se a tabela declarar ativa."""
    load, active, _sub, _unit_file = systemd_unit_table().get(
        unit, ("not-found", "inactive", "dead", "")
    )
    return 0 if load == "loaded" and active in ("active", "activating") else 3


def handle_system(command: str, args: list[str], data: bytes) -> int:
    def reject_shape() -> int:
        detail = " ".join(args)
        return forbidden(f"operação {command} não modelada: {detail}".rstrip())

    if command == "virt-xml-validate":
        if len(args) not in (1, 2) or args[0].startswith("-") or (len(args) == 2 and args[1] != "domain"):
            return reject_shape()
        try:
            ET.parse(map_path(args[0]))
            return 0
        except (ET.ParseError, OSError):
            return 1
    if command == "systemctl":
        if len(args) == 2 and args[0] == "is-active" and not args[1].startswith("-"):
            return 0
        if len(args) == 3 and args[:2] == ["is-active", "--quiet"] and not args[2].startswith("-"):
            return systemctl_is_active(args[2])
        # Sondagem read-only usada pela resolução autoritativa do backend
        # libvirt. O estado vem do arquivo do harness, nunca do systemd real.
        if (
            len(args) >= 2
            and args[0] == "show"
            and not args[1].startswith("-")
            and all(
                item.startswith("--property=") or item == "--no-pager"
                for item in args[2:]
            )
        ):
            return systemctl_show(args[1], args[2:])
        if len(args) == 2 and args[0] in ("restart", "reload", "start") and not args[1].startswith("-"):
            return simple_effect(f"systemctl:{args[0]}:{args[1]}")
        if len(args) == 3 and args[:2] == ["enable", "--now"] and not args[2].startswith("-"):
            return simple_effect(f"systemctl:enable:{args[2]}")
        return reject_shape()
    if command == "netplan":
        if args == ["generate"]:
            return 0
        if args in (["try"], ["apply"]):
            def apply_netplan() -> None:
                netplan_dir = ROOT / "etc/netplan"
                configured = any(netplan_dir.glob("*.yaml")) or any(netplan_dir.glob("*.yml"))
                marker = STATE / "bridge-active"
                if configured:
                    marker.touch()
                else:
                    marker.unlink(missing_ok=True)
            return simple_effect(f"netplan:{args[0]}", apply_netplan)
        return reject_shape()
    if command == "ping":
        if args == ["-c", "2", "-W", "3", "8.8.8.8"]:
            return 0
        return reject_shape()
    if command == "dpkg":
        if len(args) == 2 and args[0] == "-s" and not args[1].startswith("-"):
            return 0
        return reject_shape()
    if command in ("apt", "apt-get"):
        return forbidden(f"instalação inesperada: {command} {' '.join(args)}")
    if command == "getent":
        if len(args) != 2 or args[0] not in ("passwd", "group") or args[1].startswith("-"):
            return reject_shape()
        database, name = args
        if database == "passwd" and name == "fixture":
            print(f"fixture:x:1000:1000:Fixture:{HARNESS / 'home'}:/bin/bash")
            return 0
        if database == "passwd" and name == "vmtransfer" and (STATE / "user-vmtransfer").exists():
            print("vmtransfer:x:998:998::/files:/usr/sbin/nologin")
            return 0
        if database == "group" and name == "airlock-transfer" and (STATE / "group-airlock-transfer").exists():
            print("airlock-transfer:x:998:")
            return 0
        return 2
    if command == "id":
        if args == ["vmtransfer"]:
            print("uid=998(vmtransfer) gid=998(airlock-transfer) groups=998(airlock-transfer)")
            return 0
        if len(args) not in (1, 2) or args[0] not in ("-u", "-g", "-un", "-nG"):
            return reject_shape()
        if args[0] == "-u":
            print("1000")
        elif args[0] == "-g":
            print("1000")
        elif args[0] == "-un":
            print("fixture")
        else:
            print("airlock-transfer")
        return 0
    if command in ("groupadd", "useradd", "userdel", "groupdel"):
        valid = (
            (command == "groupadd" and args == ["--system", "airlock-transfer"])
            or (
                command == "useradd"
                and args
                == [
                    "--system", "--no-create-home", "--home-dir", "/files",
                    "--shell", "/usr/sbin/nologin", "--gid", "airlock-transfer", "vmtransfer",
                ]
            )
            or (command == "userdel" and args == ["vmtransfer"])
            or (command == "groupdel" and args == ["airlock-transfer"])
        )
        if not valid:
            return reject_shape()
        marker = STATE / ("group-airlock-transfer" if "group" in command else "user-vmtransfer")
        def account_action() -> None:
            if command.endswith("del"):
                marker.unlink(missing_ok=True)
            else:
                marker.touch()
        return simple_effect(f"account:{command}", account_action)
    if command == "mountpoint":
        path = ""
        if len(args) == 2 and args[0] == "-q":
            path = args[1]
        elif len(args) == 3 and args[:2] == ["-q", "--"]:
            path = args[2]
        else:
            return reject_shape()
        map_path(path)
        return 0 if (STATE / "airlock-mounted").exists() else 1
    if command == "mount":
        if args != ["-a"] and not (len(args) == 1 and args[0].startswith("/")):
            return reject_shape()
        if args[0].startswith("/"):
            map_path(args[0])
        return simple_effect("mount:airlock", lambda: (STATE / "airlock-mounted").touch())
    if command == "umount":
        if len(args) != 1 or not args[0].startswith("/"):
            return reject_shape()
        map_path(args[0])
        return simple_effect("umount:airlock", lambda: (STATE / "airlock-mounted").unlink(missing_ok=True))
    if command == "findmnt":
        valid = False
        if args == ["-no", "SOURCE", "/"]:
            valid = True
        elif (
            len(args) == 6
            and args[:3] == ["-rn", "--raw", "--mountpoint"]
            and args[4] == "--output"
            and args[5] in ("TARGET", "SOURCE", "FSTYPE", "TARGET,SOURCE,FSTYPE,OPTIONS")
        ):
            map_path(args[3])
            valid = True
        if not valid:
            return reject_shape()
        print(f"{os.environ.get('MUTATOR_AIRLOCK_TRANSIT', ROOT / 'var/lib/vm-passthrough/airlock')} /dev/fixture ext4 rw")
        return 0
    if command == "sshd":
        if args == ["-t"] or (len(args) == 3 and args[:2] == ["-T", "-C"]):
            return 0
        return reject_shape()
    if command == "ssh-keygen":
        if len(args) != 3 or args[:2] != ["-l", "-f"]:
            return reject_shape()
        map_path(args[2])
        print("256 SHA256:fixture airlock (ED25519)")
        return 0
    if command == "ufw":
        rules_path = ROOT / "etc/ufw/added.rules"
        rules = rules_path.read_text(encoding="utf-8").splitlines() if rules_path.exists() else []
        if args in (["status"], ["status", "verbose"]):
            print("Status: active" if (STATE / "ufw-active").exists() else "Status: inactive")
            return 0
        if args == ["show", "added"]:
            print("\n".join(rules))
            return 0
        if args in (["--force", "enable"], ["--force", "disable"]):
            enabling = args[1] == "enable"
            action = (lambda: (STATE / "ufw-active").touch()) if enabling else (lambda: (STATE / "ufw-active").unlink(missing_ok=True))
            return simple_effect(f"ufw:{args[1]}", action)
        if len(args) == 16 and args[:3] == ["--force", "delete", "allow"] and ufw_allow_shape_is_modeled([args[2], *args[3:]]):
            marker = "SFTP airlock - somente VM Windows"
            def delete_rule() -> None:
                remaining = [line for line in rules if marker not in line]
                rules_path.write_text("\n".join(remaining) + ("\n" if remaining else ""), encoding="utf-8")
            return simple_effect("ufw:delete", delete_rule)
        if args in (["default", "deny", "incoming"], ["default", "allow", "outgoing"]):
            return simple_effect("ufw:default:" + ":".join(args[1:]))
        if ufw_allow_shape_is_modeled(args):
            idx = args.index("comment")
            comment = args[idx + 1]
            prefix = " ".join(["ufw", *args[:idx], "comment", f"'{comment}'"])
            def add_rule() -> None:
                new_rules = list(rules)
                if prefix not in new_rules:
                    new_rules.append(prefix)
                rules_path.write_text("\n".join(new_rules) + "\n", encoding="utf-8")
            return simple_effect("ufw:allow", add_rule)
        return reject_shape()
    if command == "lsblk":
        allowed_first = {
            "--discard", "-o", "-dn", "-dno", "-lnpo", "-s", "-nro",
            "-nlo", "-dnro", "-nrpo", "-bdnP",
        }
        if not args or args[0] not in allowed_first:
            return reject_shape()
        if any(item.startswith("-") and item != "--" for item in args[1:]):
            return reject_shape()
        for item in args:
            if item.startswith("/"):
                map_path(item)
        print("NAME PATH SIZE TYPE FSTYPE MOUNTPOINTS MODEL SERIAL\nfixture /dev/fixture 1T disk ext4 - Fixture SER001")
        return 0
    if command == "udevadm":
        if len(args) != 4 or args[:3] != ["info", "--query=property", "--name"]:
            return reject_shape()
        map_path(args[3])
        print("ID_SERIAL=FIXTURE-SERIAL\nID_WWN=0xfixture")
        return 0
    if command == "lscpu":
        if args and not (len(args) == 1 and (args[0].startswith("-p=") or args[0].startswith("-e="))):
            return reject_shape()
        if args:
            print("0,0,0,0,Y\n1,0,0,0,Y\n2,1,0,0,Y\n3,1,0,0,Y")
        else:
            print("Vendor ID: AuthenticAMD\nArchitecture: x86_64")
        return 0
    if command == "lsmod":
        if args:
            return reject_shape()
        print("vfio_pci 16384 0\nvfio 65536 1 vfio_pci")
        return 0
    if command == "lspci":
        valid = (
            not args
            or args in (["-nn"], ["-nnk"], ["-Dnn"], ["-Dnnk"], ["--version"])
            or (len(args) == 2 and args[0] == "-nns" and not args[1].startswith("-"))
        )
        if not valid:
            return reject_shape()
        print("0a:00.0 VGA compatible controller [0300]: Fixture [1234:5678]")
        return 0
    if command == "update-initramfs":
        if args != ["-u", "-k", "all"]:
            return reject_shape()
        # I5: o marcador passou a ser criado aqui, e não por um efeito
        # sintético. A etapa 30 executa a transação real de boot, então o
        # initramfs precisa ser observável pelo mesmo caminho de produção.
        return simple_effect(command, lambda: (STATE / "initramfs-updated").touch())
    if command == "update-grub":
        if args:
            return reject_shape()
        # Regenera o grub.cfg a partir da fonte, como o update-grub real: é
        # isso que permite ao harness provar a pós-condição efetiva (e não só
        # o retorno do comando) da transação de boot.
        return simple_effect(command, regenerate_grub_cfg)
    if command == "kernelstub":
        if len(args) != 2 or args[0] not in ("-a", "-d") or not args[1]:
            return reject_shape()
        return simple_effect(command)
    if command == "flock":
        if not (args == ["-n", "9"] or (len(args) == 3 and args[:2] == ["-w", "60"] and args[2] == "9")):
            return reject_shape()
        return 0
    if command == "logger":
        if len(args) < 3 or args[0] != "-t" or not args[1]:
            return reject_shape()
        return 0
    if command == "dmesg":
        if args:
            return reject_shape()
        print("AMD-Vi: IOMMU enabled (synthetic I0 fixture)")
        return 0
    return forbidden(f"comando stateful não modelado: {command} {' '.join(args)}".rstrip())


def handle_mutator_effect(args: list[str]) -> int:
    # config-publish não entra aqui: ele só pode ser registrado por
    # mutator-effect-exec, que substitui o próprio processo pelo interpretador e
    # portanto continua sendo filho direto do shell da etapa.
    if len(args) != 1 or args[0] not in ("kernel-param", "initramfs"):
        return forbidden(f"efeito sintético não modelado: {' '.join(args)}".rstrip())
    key = args[0]
    def action() -> None:
        if key == "kernel-param":
            path = STATE / "cmdline"
            current = path.read_text(encoding="utf-8") if path.exists() else "quiet splash"
            if "amd_iommu=on" not in current:
                current += " amd_iommu=on iommu=pt"
            path.write_text(current.strip() + "\n", encoding="utf-8")
        elif key == "initramfs":
            (STATE / "initramfs-updated").touch()
    return simple_effect(f"custom:{key}", action)


def handle_mutator_effect_exec(args: list[str]) -> int:
    # Variante de `mutator-effect` que, depois de registrar o efeito, substitui o
    # próprio processo pelo comando real. O wrapper de python3 a invoca com
    # `exec`, então este processo é filho direto do shell da etapa: é ele que
    # precisa receber INT/TERM para que os traps da transação disparem, como
    # acontecia quando a publicação da configuração ainda era um `mv` no PATH.
    # Registrar o efeito em um processo neto sinalizaria o wrapper intermediário
    # e o shell da etapa veria apenas um filho morto, sem trap.
    if len(args) < 2:
        return forbidden("mutator-effect-exec exige nome do efeito e executável")
    key, executable, *rest = args
    if key != "config-publish":
        return forbidden(f"efeito sintético não modelado: {key}")
    if not executable.startswith("/usr/") or not os.access(executable, os.X_OK):
        return forbidden(f"mutator-effect-exec recusou executável: {executable}")
    rc = simple_effect(f"custom:{key}")
    if rc != 0:
        return rc
    # A divergência sintética não é modelada aqui: suprimir a publicação deixaria
    # o core sem envelope e viraria erro de protocolo, não um falso sucesso.
    os.execv(executable, [executable, *rest])
    return 70  # inalcançável; execv só retorna levantando OSError


def handle_sudo(args: list[str], data: bytes) -> int:
    args = list(args)
    while args and args[0] in ("-n", "-v"):
        option = args.pop(0)
        if option == "-v" and not args:
            return 0
    if args[:1] == ["-u"] and len(args) >= 3:
        args = args[2:]
    if not args:
        return 0
    if args[0] == "true":
        return 0
    nested = args[0]
    nested_args = args[1:]
    return dispatch(nested, nested_args, data, elevated=True)


def dispatch(command: str, args: list[str], data: bytes, *, elevated: bool = False) -> int:
    key = f"{command}:{args[0] if args else ''}"
    if command not in ("virsh", "xmlstarlet", "ip"):
        occurrence = call_occurrence(key)
        failure = maybe_fail_call(key, occurrence)
        if failure is not None:
            return failure
        log("CALL", key, " ".join(args))
    if command == "sudo":
        return handle_sudo(args, data)
    if command == "virsh":
        return handle_virsh(args)
    if command == "xmlstarlet":
        return handle_xmlstarlet(args)
    if command == "ip":
        return handle_ip(args)
    if command == "mutator-effect":
        return handle_mutator_effect(args)
    if command == "mutator-effect-exec":
        return handle_mutator_effect_exec(args)
    if command in REAL or command in ("chown", "chgrp", "tee"):
        if not elevated and command in ("install", "chown", "chgrp"):
            return forbidden(f"{command} fora de sudo")
        return handle_fs(command, args, data)
    return handle_system(command, args, data)


def main() -> int:
    if (
        not COMMAND
        or os.environ.get("MUTATOR_SANDBOX_ACTIVE") != "1"
        or not HARNESS.is_dir()
        or not ROOT.is_dir()
        or not STATE.is_dir()
    ):
        print("mutator-harness: dispatcher recusado fora do sandbox ativo", file=sys.stderr)
        return 126
    needs_stdin = COMMAND == "tee" or (COMMAND == "sudo" and "tee" in ARGS)
    data = sys.stdin.buffer.read() if needs_stdin else b""
    try:
        return dispatch(COMMAND, ARGS, data)
    except ExternalPathError as exc:
        return forbidden(str(exc))
    except (AssertionError, OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"mutator-harness internal error: {exc}", file=sys.stderr)
        log("INTERNAL", COMMAND, str(exc), 70)
        return 70


if __name__ == "__main__":
    raise SystemExit(main())
