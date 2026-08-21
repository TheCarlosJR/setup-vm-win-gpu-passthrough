"""Topologia, partição de CPU e plano de memória (I5.1, I5.2, I5.3).

Módulo puro: recebe o snapshot textual que o Bash capturou (`lscpu -p=...`) e
devolve fatos tipados, planos declarativos e veredictos de validação. Ele não
lê `/proc`, não executa `lscpu`, não escreve arquivo, não altera boot e não
decide efeito algum.

Três responsabilidades, separadas de propósito:

* **snapshot** (`topology_snapshot`): canonicaliza a topologia observada e
  produz um `fingerprint` estável. É esse fingerprint que permite ao Bash
  provar, imediatamente antes de persistir ou aplicar, que o host não mudou
  desde a leitura (conflito TOCTOU da tarefa I5.4);
* **validação** (`validate_layout`): decide se um par CPUS_VM/CPUS_HOST é uma
  partição válida das CPUs online, com siblings inteiros, cardinalidade exata,
  produto de topologia coerente e ao menos um core físico inteiro reservado ao
  host. As mensagens são as mesmas da implementação Bash anterior, porque são
  API operacional (seção 3.1 do plano);
* **plano** (`plan_pinning`, `memory_plan`): calcula a proposta determinística
  de pinning e o teto de memória. A pergunta ao operador e a confirmação
  continuam no Bash; aqui só existe aritmética.

Convenção de erro deste módulo: entrada estruturalmente inválida (campo
obrigatório ausente, tipo errado) levanta `DataError`, porque é defeito de
chamada. Estado do host que simplesmente não satisfaz a política devolve
`valid=0` com `error` preenchido, porque é diagnóstico para o operador, não
falha do protocolo.
"""
from __future__ import annotations

import hashlib
import re
from typing import Any, Mapping

from .errors import DataError
from .protocol import safe_label

# Limites conservadores e explícitos: nada aqui trunca em silêncio.
MAX_CPU_INDEX = 65535
MAX_CPU_ENTRIES = 4096
MAX_TOPOLOGY_LINES = 8192
MAX_UNITS = 65536

_CPU_LIST = re.compile(r"^[0-9]+(-[0-9]+)?(,[0-9]+(-[0-9]+)?)*$")
_DIGITS = re.compile(r"^[0-9]{1,10}$")

_ONLINE_TRUE = ("Y", "yes", "YES", "1")
_ONLINE_FALSE = ("N", "no", "NO", "0")

# Reserva mínima do host: 25% do total, nunca abaixo de 4 GiB nem acima de 8.
RAM_RESERVE_FRACTION = 4
RAM_RESERVE_MIN_MIB = 4096
RAM_RESERVE_MAX_MIB = 8192
HUGEPAGE_MIB = 1024


class _LayoutRejected(Exception):
    """Rejeição de política, com mensagem destinada ao operador."""

    def __init__(self, message: str) -> None:
        super().__init__(message)
        self.message = message


# --- Coerção de payload -------------------------------------------------------
# Todos os valores chegam como texto pelo canal de pares. A coerção é explícita
# e fail-closed: nada é interpretado por `int()` direto sobre entrada crua.


def _require_text(payload: Mapping[str, Any], key: str) -> str:
    value = payload.get(key)
    if not isinstance(value, str) or not value:
        raise DataError(
            "O campo %s é obrigatório e precisa ser texto." % safe_label(key)
        )
    return value


def _optional_text(payload: Mapping[str, Any], key: str) -> str:
    value = payload.get(key, "")
    if value is None:
        return ""
    if not isinstance(value, str):
        raise DataError("O campo %s precisa ser texto." % safe_label(key))
    return value


def _integer_in_range(value: str, minimum: int, maximum: int) -> int | None:
    """Equivalente exato de `inteiro_na_faixa` do shell; None quando recusado."""
    if not isinstance(value, str) or _DIGITS.match(value) is None:
        return None
    number = int(value, 10)
    if number < minimum or number > maximum:
        return None
    return number


def _require_integer(payload: Mapping[str, Any], key: str, minimum: int, maximum: int) -> int:
    number = _integer_in_range(_require_text(payload, key), minimum, maximum)
    if number is None:
        raise DataError(
            "O campo %s precisa ser inteiro entre %d e %d."
            % (safe_label(key), minimum, maximum)
        )
    return number


# --- Listas de CPU ------------------------------------------------------------


def parse_cpu_list(text: str) -> list[int] | None:
    """Expande `0-2,5` preservando a ordem declarada; None se inválida.

    Mesmas recusas de `lista_cpus_valida`/`expandir_lista_cpus`: sintaxe fora
    do formato, intervalo invertido, índice absurdo, duplicação e cardinalidade
    acima do limite.
    """
    if not isinstance(text, str) or _CPU_LIST.match(text) is None:
        return None
    expanded: list[int] = []
    seen: set[int] = set()
    for part in text.split(","):
        if "-" in part:
            start_text, _, end_text = part.partition("-")
            start = _integer_in_range(start_text, 0, MAX_CPU_INDEX)
            end = _integer_in_range(end_text, 0, MAX_CPU_INDEX)
            if start is None or end is None or start > end:
                return None
        else:
            start = _integer_in_range(part, 0, MAX_CPU_INDEX)
            if start is None:
                return None
            end = start
        for cpu in range(start, end + 1):
            if cpu in seen:
                return None
            seen.add(cpu)
            expanded.append(cpu)
            if len(expanded) > MAX_CPU_ENTRIES:
                return None
    return expanded


def render_cpu_list(cpus: list[int]) -> str:
    return ",".join(str(cpu) for cpu in cpus)


def _normalized(cpus: list[int]) -> str:
    return render_cpu_list(sorted(cpus))


# --- Topologia ----------------------------------------------------------------


class _Topology:
    """Topologia canônica das CPUs **online**, derivada do CSV do `lscpu`."""

    __slots__ = ("online", "core_cpus", "order")

    def __init__(self) -> None:
        self.online: set[int] = set()
        # chave "socket:core" -> siblings online, na ordem em que apareceram.
        self.core_cpus: dict[str, list[int]] = {}
        self.order: list[str] = []

    @property
    def keys_sorted(self) -> list[str]:
        def sort_key(key: str) -> tuple[int, int]:
            socket_text, _, core_text = key.partition(":")
            return (int(socket_text, 10), int(core_text, 10))

        return sorted(self.core_cpus, key=sort_key)

    def canonical_text(self) -> str:
        parts = []
        for key in self.keys_sorted:
            parts.append("%s=%s" % (key, _normalized(self.core_cpus[key])))
        return ";".join(parts)

    def fingerprint(self) -> str:
        return hashlib.sha256(self.canonical_text().encode("utf-8")).hexdigest()


def _parse_topology(csv_text: str) -> _Topology:
    """Interpreta `lscpu -p=CPU,CORE,SOCKET,NODE,ONLINE`, recusando o ambíguo.

    CPU offline é ignorada de propósito: ela não pode ser alocada nem contada,
    mas também não invalida a leitura. Estado ONLINE desconhecido, coluna extra
    e CPU repetida são recusados, porque nenhum dos três permite decidir a
    partição sem adivinhar.
    """
    topology = _Topology()
    lines = csv_text.splitlines()
    if len(lines) > MAX_TOPOLOGY_LINES:
        raise _LayoutRejected(
            "A topologia declara %d linhas, acima do limite de %d."
            % (len(lines), MAX_TOPOLOGY_LINES)
        )
    for raw_line in lines:
        line = raw_line.strip("\r")
        if not line.strip():
            continue
        if line.lstrip().startswith("#"):
            continue
        fields = line.split(",")
        if len(fields) != 5:
            raise _LayoutRejected("Linha de topologia possui colunas inesperadas.")
        cpu_text, core_text, socket_text, _node_text, online_text = (
            field.strip("\r") for field in fields
        )
        if online_text in _ONLINE_FALSE:
            continue
        if online_text not in _ONLINE_TRUE:
            raise _LayoutRejected(
                "Estado ONLINE desconhecido para CPU %s: '%s'."
                % (cpu_text or "?", online_text or "vazio")
            )
        cpu = _integer_in_range(cpu_text, 0, MAX_CPU_INDEX)
        if cpu is None:
            raise _LayoutRejected("ID de CPU online inválido: '%s'." % cpu_text)
        core = _integer_in_range(core_text, 0, MAX_CPU_INDEX)
        if core is None:
            raise _LayoutRejected(
                "CORE inválido para a CPU %d: '%s'." % (cpu, core_text)
            )
        socket = _integer_in_range(socket_text, 0, MAX_CPU_INDEX)
        if socket is None:
            raise _LayoutRejected(
                "SOCKET inválido para a CPU %d: '%s'." % (cpu, socket_text)
            )
        if cpu in topology.online:
            raise _LayoutRejected("A CPU %d aparece mais de uma vez na topologia." % cpu)
        topology.online.add(cpu)
        key = "%d:%d" % (socket, core)
        if key not in topology.core_cpus:
            topology.core_cpus[key] = []
            topology.order.append(key)
        topology.core_cpus[key].append(cpu)
    if not topology.online:
        raise _LayoutRejected("Nenhuma CPU online foi encontrada.")
    return topology


def _boot_core(topology: _Topology) -> str:
    for key in topology.keys_sorted:
        if 0 in topology.core_cpus[key]:
            return key
    return ""


def _threads_per_core(topology: _Topology) -> int:
    """Threads por core quando o host é homogêneo; 0 quando não é."""
    counts = {len(cpus) for cpus in topology.core_cpus.values()}
    if len(counts) != 1:
        return 0
    return counts.pop()


def topology_snapshot(payload: Mapping[str, Any]) -> dict:
    """Canonicaliza a topologia observada e devolve o fingerprint estável.

    O fingerprint cobre apenas o que importa para a decisão: quais CPUs estão
    online e como elas se agrupam por socket/core. Reordenar as linhas do
    `lscpu` não muda o fingerprint; colocar uma CPU offline, mudar o
    agrupamento de siblings ou trocar a contagem muda.
    """
    csv_text = _require_text(payload, "csv")
    try:
        topology = _parse_topology(csv_text)
    except _LayoutRejected as rejection:
        return {
            "valid": 0,
            "error": rejection.message,
            "online_count": 0,
            "online_set": "",
            "core_count": 0,
            "socket_count": 0,
            "threads_per_core": 0,
            "homogeneous": 0,
            "boot_core": "",
            "boot_core_cpus": "",
            "fingerprint": "",
        }
    sockets = {key.partition(":")[0] for key in topology.core_cpus}
    boot_core = _boot_core(topology)
    threads = _threads_per_core(topology)
    return {
        "valid": 1,
        "error": "",
        "online_count": len(topology.online),
        "online_set": _normalized(sorted(topology.online)),
        "core_count": len(topology.core_cpus),
        "socket_count": len(sockets),
        "threads_per_core": threads,
        "homogeneous": 1 if threads else 0,
        "boot_core": boot_core,
        "boot_core_cpus": (
            _normalized(topology.core_cpus[boot_core]) if boot_core else ""
        ),
        "fingerprint": topology.fingerprint(),
    }


# --- Validação relacional da partição -----------------------------------------


def _validate_layout(
    cpus_vm_text: str,
    cpus_host_text: str,
    vcpus_text: str,
    cores_text: str,
    threads_text: str,
    topology: _Topology,
) -> dict:
    vcpus = _integer_in_range(vcpus_text, 1, MAX_UNITS)
    if vcpus is None:
        raise _LayoutRejected("VM_VCPUS inválido: '%s'." % (vcpus_text or "vazio"))
    cores = _integer_in_range(cores_text, 1, MAX_UNITS)
    if cores is None:
        raise _LayoutRejected("VM_CORES inválido: '%s'." % (cores_text or "vazio"))
    threads = _integer_in_range(threads_text, 1, MAX_UNITS)
    if threads is None:
        raise _LayoutRejected("VM_THREADS inválido: '%s'." % (threads_text or "vazio"))
    if cores * threads != vcpus:
        raise _LayoutRejected(
            "VM_CORES x VM_THREADS precisa ser igual a VM_VCPUS (%d x %d != %d)."
            % (cores, threads, vcpus)
        )
    vm_cpus = parse_cpu_list(cpus_vm_text)
    if vm_cpus is None:
        raise _LayoutRejected(
            "CPUS_VM possui sintaxe, intervalo ou duplicação inválida."
        )
    host_cpus = parse_cpu_list(cpus_host_text)
    if host_cpus is None:
        raise _LayoutRejected(
            "CPUS_HOST possui sintaxe, intervalo ou duplicação inválida."
        )

    allocation: dict[int, str] = {}
    for cpu in vm_cpus:
        if cpu not in topology.online:
            raise _LayoutRejected(
                "CPUS_VM inclui a CPU %d, que não está online." % cpu
            )
        allocation[cpu] = "vm"
    for cpu in host_cpus:
        if cpu not in topology.online:
            raise _LayoutRejected(
                "CPUS_HOST inclui a CPU %d, que não está online." % cpu
            )
        if cpu in allocation:
            raise _LayoutRejected(
                "A CPU %d aparece simultaneamente em CPUS_VM e CPUS_HOST." % cpu
            )
        allocation[cpu] = "host"
    if len(allocation) != len(topology.online):
        raise _LayoutRejected(
            "As listas cobrem %d de %d CPUs online; não pode haver omissões."
            % (len(allocation), len(topology.online))
        )
    for cpu in sorted(topology.online):
        if cpu not in allocation:
            raise _LayoutRejected(
                "A CPU online %d não pertence a CPUS_VM nem a CPUS_HOST." % cpu
            )
    if len(vm_cpus) != vcpus:
        raise _LayoutRejected(
            "CPUS_VM contém %d CPUs, mas VM_VCPUS=%d." % (len(vm_cpus), vcpus)
        )

    core_owner: dict[str, str] = {}
    vm_core_count = 0
    host_core_count = 0
    for key in topology.keys_sorted:
        siblings = topology.core_cpus[key]
        owner = allocation[siblings[0]]
        for sibling in siblings:
            if allocation[sibling] != owner:
                raise _LayoutRejected(
                    "O core físico %s foi dividido entre VM e host (siblings: %s)."
                    % (key, " ".join(str(cpu) for cpu in siblings))
                )
        core_owner[key] = owner
        if owner == "vm":
            if len(siblings) != threads:
                raise _LayoutRejected(
                    "O core da VM %s tem %d thread(s) online, mas VM_THREADS=%d."
                    % (key, len(siblings), threads)
                )
            vm_core_count += 1
        else:
            host_core_count += 1
    if vm_core_count != cores:
        raise _LayoutRejected(
            "CPUS_VM ocupa %d cores físicos, mas VM_CORES=%d."
            % (vm_core_count, cores)
        )
    if host_core_count < 1:
        raise _LayoutRejected(
            "Nenhum core físico completo foi preservado para o host."
        )

    # A ordem também é contrato: no XML virtual, threads adjacentes pertencem
    # ao mesmo core. Cada grupo socket:core precisa aparecer contíguo, ordenado
    # por socket/core e por ID lógico do sibling.
    canonical: list[int] = []
    for key in topology.keys_sorted:
        if core_owner[key] != "vm":
            continue
        canonical.extend(sorted(topology.core_cpus[key]))
    expected = render_cpu_list(canonical)
    declared = render_cpu_list(vm_cpus)
    if declared != expected:
        raise _LayoutRejected(
            "CPUS_VM precisa agrupar siblings na ordem canônica socket:core: "
            "esperado [%s], recebido [%s]." % (expected, declared)
        )

    return {
        "valid": 1,
        "error": "",
        "online_set": _normalized(sorted(topology.online)),
        "online_count": len(topology.online),
        "vm_cpu_count": len(vm_cpus),
        "vm_core_count": vm_core_count,
        "host_core_count": host_core_count,
        "fingerprint": topology.fingerprint(),
    }


def validate_layout(payload: Mapping[str, Any]) -> dict:
    """Veredicto sobre a partição declarada, com a mensagem exata do shell."""
    csv_text = _require_text(payload, "csv")
    cpus_vm = _optional_text(payload, "cpus_vm")
    cpus_host = _optional_text(payload, "cpus_host")
    vcpus = _optional_text(payload, "vcpus")
    cores = _optional_text(payload, "cores")
    threads = _optional_text(payload, "threads")
    try:
        topology = _parse_topology(csv_text)
        return _validate_layout(cpus_vm, cpus_host, vcpus, cores, threads, topology)
    except _LayoutRejected as rejection:
        return {
            "valid": 0,
            "error": rejection.message,
            "online_set": "",
            "online_count": 0,
            "vm_cpu_count": 0,
            "vm_core_count": 0,
            "host_core_count": 0,
            "fingerprint": "",
        }


# --- Plano de pinning ---------------------------------------------------------


def _plan_pinning(topology: _Topology, vm_cores_text: str) -> dict:
    total_cores = len(topology.core_cpus)
    if total_cores < 2:
        raise _LayoutRejected(
            "Só encontrei %d core(s) físico(s) online; um precisa ficar "
            "integralmente com o host." % total_cores
        )
    threads = _threads_per_core(topology)
    if threads == 0:
        divergent = ""
        reference = len(topology.core_cpus[topology.keys_sorted[0]])
        for key in topology.keys_sorted:
            if len(topology.core_cpus[key]) != reference:
                divergent = key
                break
        raise _LayoutRejected(
            "Topologia SMT heterogênea/offline: core %s tem %d thread(s), "
            "esperado %d. Reative CPUs ou configure manualmente."
            % (divergent, len(topology.core_cpus[divergent]), reference)
        )
    boot_core = _boot_core(topology)
    if not boot_core:
        raise _LayoutRejected(
            "A CPU lógica 0 não aparece online na topologia; não é seguro gerar "
            "um mapa pronto para nohz_full."
        )
    # Teto: o host mantém ao menos um core completo (dois quando há folga).
    max_vm = total_cores - 1
    if total_cores >= 6:
        max_vm = total_cores - 2

    data: dict[str, Any] = {
        "valid": 1,
        "error": "",
        "total_cores": total_cores,
        "threads_per_core": threads,
        "max_vm_cores": max_vm,
        "default_vm_cores": max_vm,
        "boot_core": boot_core,
        "boot_core_cpus": _normalized(topology.core_cpus[boot_core]),
        "online_set": _normalized(sorted(topology.online)),
        "fingerprint": topology.fingerprint(),
        "planned": 0,
        "cpus_vm": "",
        "cpus_host": "",
        "vcpus": 0,
        "vm_cores": 0,
    }
    if not vm_cores_text:
        return data

    vm_cores = _integer_in_range(vm_cores_text, 1, max_vm)
    if vm_cores is None:
        raise _LayoutRejected(
            "Cores físicos dedicados à VM precisam ser um inteiro entre 1 e %d."
            % max_vm
        )
    host_cores_remaining = (total_cores - vm_cores) - 1
    vm_list: list[int] = []
    host_list: list[int] = sorted(topology.core_cpus[boot_core])
    assigned_host = 0
    for key in topology.keys_sorted:
        if key == boot_core:
            continue
        siblings = sorted(topology.core_cpus[key])
        if assigned_host < host_cores_remaining:
            host_list.extend(siblings)
            assigned_host += 1
        else:
            vm_list.extend(siblings)
    data["planned"] = 1
    data["vm_cores"] = vm_cores
    data["cpus_vm"] = render_cpu_list(vm_list)
    data["cpus_host"] = render_cpu_list(host_list)
    data["vcpus"] = len(vm_list)

    # O plano proposto é validado pelo mesmo validador que o shell usa depois:
    # nenhuma proposta sai daqui sem passar na política que será reaplicada.
    verdict = _validate_layout(
        data["cpus_vm"],
        data["cpus_host"],
        str(len(vm_list)),
        str(vm_cores),
        str(threads),
        topology,
    )
    data["host_core_count"] = verdict["host_core_count"]
    return data


def plan_pinning(payload: Mapping[str, Any]) -> dict:
    """Calcula teto, padrão e (quando pedido) a proposta de partição.

    Sem `vm_cores`, devolve apenas os limites, para que o Bash pergunte ao
    operador. Com `vm_cores`, devolve a proposta determinística já validada.
    """
    csv_text = _require_text(payload, "csv")
    vm_cores_text = _optional_text(payload, "vm_cores")
    try:
        topology = _parse_topology(csv_text)
        return _plan_pinning(topology, vm_cores_text)
    except _LayoutRejected as rejection:
        return {
            "valid": 0,
            "error": rejection.message,
            "total_cores": 0,
            "threads_per_core": 0,
            "max_vm_cores": 0,
            "default_vm_cores": 0,
            "boot_core": "",
            "boot_core_cpus": "",
            "online_set": "",
            "fingerprint": "",
            "planned": 0,
            "cpus_vm": "",
            "cpus_host": "",
            "vcpus": 0,
            "vm_cores": 0,
        }


# --- Plano de memória e HugePages ---------------------------------------------


def memory_plan(payload: Mapping[str, Any]) -> dict:
    """Deriva reserva do host, teto da VM e a contagem de páginas de 1 GiB.

    A relação entre `VM_RAM_MB` e `HUGEPAGES_1G` é a mesma que as etapas 3 e
    16 exigiam em Bash: múltiplo exato de 1 GiB, contagem derivada por divisão
    e teto respeitado. Aqui ela tem uma implementação só.
    """
    total = _require_integer(payload, "total_mib", 0, 1 << 30)
    reserve = total // RAM_RESERVE_FRACTION
    if reserve < RAM_RESERVE_MIN_MIB:
        reserve = RAM_RESERVE_MIN_MIB
    if reserve > RAM_RESERVE_MAX_MIB:
        reserve = RAM_RESERVE_MAX_MIB
    maximum = total - reserve
    if maximum < 0:
        maximum = 0
    maximum = (maximum // HUGEPAGE_MIB) * HUGEPAGE_MIB
    if maximum < HUGEPAGE_MIB:
        maximum = 0

    data: dict[str, Any] = {
        "valid": 1,
        "error": "",
        "total_mib": total,
        "reserve_mib": reserve,
        "max_vm_mib": maximum,
        "max_vm_gib": maximum // HUGEPAGE_MIB,
        "checked": 0,
        "vm_ram_mib": 0,
        "hugepages_1g": 0,
    }

    vm_ram_text = _optional_text(payload, "vm_ram_mib")
    hugepages_text = _optional_text(payload, "hugepages_1g")
    if not vm_ram_text and not hugepages_text:
        return data

    data["checked"] = 1
    vm_ram = _integer_in_range(vm_ram_text, 1024, 1048576)
    if vm_ram is None:
        data["valid"] = 0
        data["error"] = "VM_RAM_MB inválido: '%s'." % (vm_ram_text or "vazio")
        return data
    data["vm_ram_mib"] = vm_ram
    if vm_ram % HUGEPAGE_MIB != 0:
        data["valid"] = 0
        data["error"] = (
            "VM_RAM_MB=%d não é múltiplo de %d MiB." % (vm_ram, HUGEPAGE_MIB)
        )
        return data
    derived = vm_ram // HUGEPAGE_MIB
    data["hugepages_1g"] = derived
    if hugepages_text:
        declared = _integer_in_range(hugepages_text, 1, 1048576)
        if declared is None:
            data["valid"] = 0
            data["error"] = "HUGEPAGES_1G precisa ser um inteiro positivo."
            return data
        if declared != derived:
            data["valid"] = 0
            data["error"] = (
                "HUGEPAGES_1G=%d diverge de VM_RAM_MB/%d; corrija conscientemente "
                "na etapa 3." % (declared, HUGEPAGE_MIB)
            )
            return data
    if vm_ram > maximum:
        data["valid"] = 0
        data["error"] = (
            "VM_RAM_MB=%d excede o teto seguro atual de %d MiB." % (vm_ram, maximum)
        )
        return data
    return data
