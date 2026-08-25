"""Despacho estrito da CLI interna do core (seções 2.4 e 3.8).

Responsabilidade única: validar `argv`, ler o transporte, chamar módulos puros
e mapear falhas para códigos internos. A CLI não implementa domínio, não abre
caminho arbitrário e não escreve em nenhum lugar além dos fluxos recebidos.

Regras de `argv` que este módulo aplica:

* somente subcomando, opções fixas na forma `--nome` ou `--nome=valor` e
  identificadores escalares validados;
* XML, JSON, configuração e snapshots nunca entram em `argv`: eles chegam por
  stdin ou por arquivo controlado criado pela ponte, com modo 0600;
* opção desconhecida, repetida, posicional solto ou transporte ambíguo é erro
  de uso, nunca comportamento implícito.
"""
from __future__ import annotations

import hashlib
import os
import re
import stat
import sys
from typing import Any, BinaryIO, Callable, Mapping

from . import (
    colors,
    config,
    cpu,
    domain_xml,
    inventory,
    network_xml,
    nvidia_lookup,
    protocol,
    qemu_image,
)
from .errors import (
    EXIT_INTERNAL,
    EXIT_OK,
    ConflictError,
    CoreError,
    DataError,
    InternalError,
    MissingInputError,
    PersistenceError,
    UsageError,
)

USAGE = (
    "Uso interno do core (chamado apenas por lib/python-core.sh):\n"
    "  passthrough_core_cli.py [--traceback] version [--format=json|pairs]\n"
    "  passthrough_core_cli.py [--traceback] payload-probe\n"
    "      (--stdin | --input-file=CAMINHO) [--operation-id=ID]\n"
    "      [--format=json|pairs]\n"
    "  passthrough_core_cli.py [--traceback] SUBCOMANDO-DE-DOMINIO\n"
    "      (--stdin | --input-file=CAMINHO) [--output-file=CAMINHO]\n"
    "      [--format=json|pairs]\n"
    "  Subcomandos de domínio: domain-disk-target, domain-disk-block,\n"
    "  domain-disk-snapshot-plan, domain-disk-backup-target,\n"
    "  domain-snapshot-internal, domain-hostdev-pci, domain-usb-hostdev,\n"
    "  domain-interfaces, domain-memory-backing, domain-validate-cpu,\n"
    "  domain-compare, domain-fingerprint, domain-metadata, domain-candidate,\n"
    "  network-inspect, network-overlap, nvidia-product-match,\n"
    "  nvidia-download-info, qemu-image-inspect,\n"
    "  cpu-topology, cpu-layout, cpu-plan, cpu-memory,\n"
    "  inventory-parse, inventory-diff, inventory-disk-plan,\n"
    "  inventory-usb-resolve, inventory-normalize\n"
    "  passthrough_core_cli.py [--traceback] SUBCOMANDO-DE-CONFIG\n"
    "      --dir-fd=N (--stdin | --input-file=CAMINHO) [--format=json|pairs]\n"
    "  Subcomandos de configuração: config-load, config-publish,\n"
    "  config-legacy-scan, config-schema, config-validate\n"
)

FORMATS = ("json", "pairs")
_READ_CHUNK = 1 << 16
_CONTROLLED_INPUT_MODE = 0o600
_CONTROLLED_OUTPUT_MODE = 0o600
MAX_OUTPUT_BYTES = protocol.MAX_PAYLOAD_BYTES


def _color_enabled(injected: BinaryIO | None) -> bool:
    """Decide cor para o diagnóstico humano; na dúvida, texto puro.

    Espelha a política de `lib/common.sh`, que só define as constantes quando
    há terminal. Fluxo injetado é teste, captura e redirecionamento não são
    terminal, e `NO_COLOR`/`TERM=dumb` desligam por convenção. Diagnóstico
    ilegível é pior que diagnóstico sem cor, então todo caminho duvidoso cai
    no texto puro.
    """
    if injected is not None:
        return False
    if os.environ.get("NO_COLOR", ""):
        return False
    if os.environ.get("TERM", "dumb") == "dumb":
        return False
    try:
        return bool(sys.stderr.isatty())
    except (AttributeError, ValueError):
        return False


class Streams:
    """Fluxos binários injetáveis, para que os testes não dependam do processo."""

    def __init__(
        self,
        stdin: BinaryIO | None = None,
        stdout: BinaryIO | None = None,
        stderr: BinaryIO | None = None,
    ) -> None:
        self._stdin = stdin
        self._stdout = stdout
        self._stderr = stderr

    def read_stdin(self) -> bytes:
        stream = self._stdin if self._stdin is not None else sys.stdin.buffer
        blocks = []
        remaining = protocol.MAX_PAYLOAD_BYTES + 1
        while remaining > 0:
            block = stream.read(min(remaining, _READ_CHUNK))
            if not block:
                break
            blocks.append(block)
            remaining -= len(block)
        return b"".join(blocks)

    def write_output(self, data: bytes) -> None:
        stream = self._stdout if self._stdout is not None else sys.stdout.buffer
        stream.write(data)
        stream.flush()

    def write_error(self, message: str, exception: BaseException | None, traceback_enabled: bool) -> None:
        stream = self._stderr if self._stderr is not None else sys.stderr.buffer
        text = colors.diagnostic_line(message, _color_enabled(self._stderr))
        if traceback_enabled and exception is not None:
            import traceback

            text += "".join(
                traceback.format_exception(
                    type(exception), exception, exception.__traceback__
                )
            )
        stream.write(text.encode("utf-8", "backslashreplace"))
        stream.flush()


def _parse_options(
    arguments: list[str],
    flags_allowed: frozenset[str],
    values_allowed: frozenset[str],
) -> tuple[frozenset[str], dict[str, str]]:
    flags: set[str] = set()
    values: dict[str, str] = {}
    for argument in arguments:
        if not argument.startswith("--") or argument == "--":
            raise UsageError(
                "Argumento posicional não é aceito: %s.\n%s"
                % (protocol.safe_label(argument), USAGE)
            )
        if "=" in argument:
            name, _, value = argument.partition("=")
            if name not in values_allowed:
                raise UsageError(
                    "Opção desconhecida: %s.\n%s" % (protocol.safe_label(name), USAGE)
                )
            if name in values:
                raise UsageError("Opção repetida: %s." % protocol.safe_label(name))
            values[name] = value
        else:
            if argument not in flags_allowed:
                raise UsageError(
                    "Opção desconhecida: %s.\n%s"
                    % (protocol.safe_label(argument), USAGE)
                )
            if argument in flags:
                raise UsageError("Opção repetida: %s." % protocol.safe_label(argument))
            flags.add(argument)
    return frozenset(flags), values


def _resolve_format(values: Mapping[str, str]) -> str:
    chosen = values.get("--format", "json")
    if chosen not in FORMATS:
        raise UsageError(
            "Formato de saída inválido: %s; use json ou pairs."
            % protocol.safe_label(chosen)
        )
    return chosen


def _render(response: Mapping[str, Any], chosen_format: str) -> bytes:
    if chosen_format == "pairs":
        return protocol.pairs_from_response(response)
    protocol.validate_response(response)
    return protocol.serialize(response)


def _split_controlled_path(path: str, role: str) -> tuple[str, str]:
    """Valida o localizador recebido em `argv` e devolve (raiz privada, nome)."""
    if not path.startswith("/"):
        raise UsageError(
            "O arquivo de %s precisa ser um caminho absoluto." % role
        )
    components = path.split("/")[1:]
    for component in components:
        if component in ("", ".", ".."):
            raise UsageError("Caminho de %s não é canônico." % role)
    if len(components) < 2:
        raise UsageError(
            "A %s controlada precisa estar sob uma raiz privada." % role
        )
    return "/" + "/".join(components[:-1]), components[-1]


def _open_private_root(parent: str, role: str) -> int:
    """Abre a raiz privada exigindo dono correto e negação de grupo/outros."""
    parent_flags = (
        os.O_RDONLY
        | getattr(os, "O_DIRECTORY", 0)
        | os.O_NOFOLLOW
        | getattr(os, "O_CLOEXEC", 0)
    )
    try:
        descriptor = os.open(parent, parent_flags)
    except FileNotFoundError as error:
        raise MissingInputError(
            "Raiz privada da %s controlada não existe." % role
        ) from error
    except OSError as error:
        raise UsageError(
            "Raiz privada da %s controlada recusada." % role
        ) from error
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISDIR(info.st_mode):
            raise UsageError(
                "Raiz privada da %s controlada não é diretório." % role
            )
        if info.st_uid != os.getuid():
            raise UsageError(
                "Raiz privada da %s controlada não pertence a este processo." % role
            )
        if stat.S_IMODE(info.st_mode) & 0o077:
            raise UsageError(
                "Raiz privada da %s controlada precisa negar grupo e outros." % role
            )
    except BaseException:
        os.close(descriptor)
        raise
    return descriptor


def _read_controlled_input(path: str) -> bytes:
    """Lê o arquivo controlado que a ponte criou, sem seguir link.

    A política é a da seção 3.2 aplicada à entrada, somada à exigência da
    seção 3.9 de que um caminho em `argv` só localize arquivo sob raiz privada:
    caminho absoluto canônico, diretório pai do próprio processo negando grupo
    e outros, arquivo regular com um único link, dono igual ao processo e modo
    exatamente 0600. Tipo, modo, dono e link count são revalidados pelo
    descritor obtido com `dir_fd`, para que uma troca concorrente do componente
    final não seja lida como legítima.
    """
    parent, name = _split_controlled_path(path, "entrada")
    parent_descriptor = _open_private_root(parent, "entrada")
    try:
        raw = _read_from_private_root(parent_descriptor, name)
    finally:
        os.close(parent_descriptor)
    return raw


def _write_controlled_output(path: str, text: str) -> int:
    """Publica o candidato no arquivo controlado que a ponte já criou.

    A seção 2.2 autoriza o core a escrever candidatos e temporários; nada mais.
    Por isso a escrita exige um arquivo pré-existente sob raiz privada, com
    dono correto, um único link e modo 0600, e a validação acontece pelo
    descritor (não pelo caminho) imediatamente antes de truncar. Assim uma
    troca concorrente do componente final não redireciona a escrita.
    """
    parent, name = _split_controlled_path(path, "saída")
    parent_descriptor = _open_private_root(parent, "saída")
    flags = os.O_WRONLY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0)
    try:
        try:
            descriptor = os.open(name, flags, dir_fd=parent_descriptor)
        except FileNotFoundError as error:
            raise MissingInputError(
                "Arquivo de saída controlado não existe; a ponte precisa criá-lo."
            ) from error
        except OSError as error:
            raise UsageError(
                "Arquivo de saída controlado recusado na abertura."
            ) from error
        try:
            info = os.fstat(descriptor)
            if not stat.S_ISREG(info.st_mode):
                raise UsageError("A saída controlada não é arquivo regular.")
            if info.st_nlink != 1:
                raise UsageError("A saída controlada possui mais de um link.")
            if info.st_uid != os.getuid():
                raise UsageError("A saída controlada não pertence a este processo.")
            if stat.S_IMODE(info.st_mode) != _CONTROLLED_OUTPUT_MODE:
                raise UsageError("A saída controlada precisa estar em modo 0600.")
            encoded = text.encode("utf-8")
            if len(encoded) > MAX_OUTPUT_BYTES:
                raise DataError(
                    "Candidato maior que o limite de %d bytes." % MAX_OUTPUT_BYTES
                )
            os.ftruncate(descriptor, 0)
            written = 0
            while written < len(encoded):
                written += os.write(descriptor, encoded[written:])
            os.fsync(descriptor)
            return written
        except OSError as error:
            raise PersistenceError(
                "Não foi possível publicar o candidato no arquivo controlado."
            ) from error
        finally:
            os.close(descriptor)
    finally:
        os.close(parent_descriptor)


def _read_from_private_root(parent_descriptor: int, name: str) -> bytes:
    """Abre e revalida o arquivo pelo descritor do diretório privado.

    O uso de `dir_fd` fecha a janela em que o componente final poderia ser
    trocado entre a inspeção do diretório e a abertura do arquivo.
    """
    flags = os.O_RDONLY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0)
    try:
        descriptor = os.open(name, flags, dir_fd=parent_descriptor)
    except FileNotFoundError as error:
        raise MissingInputError(
            "Arquivo de entrada controlado não existe."
        ) from error
    except IsADirectoryError as error:
        raise UsageError("A entrada controlada não é arquivo regular.") from error
    except OSError as error:
        raise UsageError(
            "Arquivo de entrada controlado recusado na abertura."
        ) from error
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode):
            raise UsageError("A entrada controlada não é arquivo regular.")
        if info.st_nlink != 1:
            raise UsageError("A entrada controlada possui mais de um link.")
        if info.st_uid != os.getuid():
            raise UsageError("A entrada controlada não pertence a este processo.")
        if stat.S_IMODE(info.st_mode) != _CONTROLLED_INPUT_MODE:
            raise UsageError("A entrada controlada precisa estar em modo 0600.")
        if info.st_size > protocol.MAX_PAYLOAD_BYTES:
            raise DataError(
                "Payload maior que o limite de %d bytes."
                % protocol.MAX_PAYLOAD_BYTES
            )
        blocks = []
        remaining = protocol.MAX_PAYLOAD_BYTES + 1
        while remaining > 0:
            block = os.read(descriptor, min(remaining, _READ_CHUNK))
            if not block:
                break
            blocks.append(block)
            remaining -= len(block)
        return b"".join(blocks)
    finally:
        os.close(descriptor)


def _command_version(arguments: list[str], streams: Streams) -> bytes:
    """Read-only absoluto: nenhuma leitura de arquivo, nenhum acesso ao host."""
    _flags, values = _parse_options(arguments, frozenset(), frozenset({"--format"}))
    response = protocol.build_response("version", {})
    return _render(response, _resolve_format(values))


def _command_payload_probe(arguments: list[str], streams: Streams) -> bytes:
    """Prova o transporte de payload sem implementar domínio algum.

    Devolve apenas medidas do que chegou (tamanho, quantidade de chaves e
    digest), nunca o conteúdo: assim um canário de teste não pode vazar por
    stdout enquanto o transporte continua verificável byte a byte.
    """
    flags, values = _parse_options(
        arguments,
        frozenset({"--stdin"}),
        frozenset({"--format", "--input-file", "--operation-id"}),
    )
    chosen_format = _resolve_format(values)
    operation_id = ""
    if "--operation-id" in values:
        operation_id = protocol.validate_scalar_identifier(
            values["--operation-id"], "--operation-id"
        )
    used_stdin = "--stdin" in flags
    used_file = "--input-file" in values
    if used_stdin == used_file:
        raise UsageError(
            "Informe exatamente um transporte: --stdin ou --input-file=CAMINHO."
        )
    raw = streams.read_stdin() if used_stdin else _read_controlled_input(
        values["--input-file"]
    )
    payload = protocol.decode_request(raw)
    data = {
        "byte_length": len(raw),
        "key_count": len(payload),
        "operation_id": operation_id,
        "sha256": hashlib.sha256(raw).hexdigest(),
    }
    response = protocol.build_response("payload-probe", data)
    return _render(response, chosen_format)


# --- Arquivo sensível localizado por descritor de diretório -------------------
# A configuração do operador é a única exceção de escrita autorizada ao core
# (seção 2.2). O caminho dela é um `LOCAL_IDENTIFIER` e, pela seção 3.9, não
# pode entrar em `argv`: a ponte abre o diretório do alvo e passa o **descritor**
# (`--dir-fd=N`, um escalar), enquanto o basename fixo vem no payload. Assim o
# core nunca resolve caminho vindo de dado e toda a política de arquivo tem uma
# implementação só.

_SENSITIVE_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
# Recusa é para escrita por "outros": é a linha que realmente separa o operador
# de terceiros. Escrita por grupo não é recusada porque em distribuições com
# grupo privado por usuário (o caso deste projeto) ela equivale ao próprio dono,
# e um umask 002 produz 0664/0775 legitimamente. Contra a troca concorrente do
# alvo por alguém do grupo, a proteção real é a revalidação de device, inode,
# tipo, modo, dono e link count imediatamente antes do rename.
_SENSITIVE_MODE_MASK = 0o002
# Na publicação o modo converge para o padrão da seção 3.9 (arquivo do projeto
# em 0600) sem apagar a intenção do operador: grupo perde escrita e "outros"
# perdem tudo. Assim 0640 continua 0640, 0664 vira 0640 e um 0755 herdado de
# cópia manual vira 0750, deixando de expor identidade local a terceiros. O modo
# nunca é afrouxado.
_SENSITIVE_TIGHTEN_MASK = 0o027
# Máscara de exposição a terceiros, usada apenas para avisar na carga.
_SENSITIVE_OTHERS_MASK = 0o007
_CONFIG_FALLBACK_MODE = 0o600
_TEMP_ATTEMPTS = 8


def _resolve_dir_fd(values: Mapping[str, str]) -> int:
    """Valida o descritor recebido e confirma que ele é um diretório usável."""
    raw = values.get("--dir-fd")
    if raw is None:
        raise UsageError("Este subcomando exige --dir-fd=N herdado da ponte.")
    if not raw.isdigit() or len(raw) > 4:
        raise UsageError("O descritor de diretório precisa ser inteiro decimal.")
    descriptor = int(raw, 10)
    if descriptor < 3:
        raise UsageError("O descritor de diretório não pode ser 0, 1 ou 2.")
    try:
        info = os.fstat(descriptor)
    except OSError as error:
        raise UsageError(
            "O descritor de diretório informado não está aberto neste processo."
        ) from error
    if not stat.S_ISDIR(info.st_mode):
        raise UsageError("O descritor informado não é de um diretório.")
    if info.st_uid != os.getuid():
        raise UsageError("O diretório do alvo não pertence a este processo.")
    if stat.S_IMODE(info.st_mode) & _SENSITIVE_MODE_MASK:
        raise UsageError("O diretório do alvo é gravável por outros; recusado.")
    return descriptor


def _sensitive_name(payload: Mapping[str, Any]) -> str:
    name = payload.get("name")
    if not isinstance(name, str) or _SENSITIVE_NAME.match(name) is None:
        raise UsageError("Nome de arquivo sensível fora do formato aceito.")
    return name


class _SensitiveState:
    """Identidade observada de um arquivo sensível, para revalidação TOCTOU."""

    __slots__ = ("device", "inode", "mode", "nlink", "uid", "gid", "exists")

    def __init__(self, info: os.stat_result | None) -> None:
        self.exists = info is not None
        if info is None:
            self.device = self.inode = self.nlink = self.uid = self.gid = -1
            self.mode = _CONFIG_FALLBACK_MODE
            return
        self.device = info.st_dev
        self.inode = info.st_ino
        self.mode = stat.S_IMODE(info.st_mode)
        self.nlink = info.st_nlink
        self.uid = info.st_uid
        self.gid = info.st_gid

    def matches(self, other: "_SensitiveState") -> bool:
        if self.exists != other.exists:
            return False
        if not self.exists:
            return True
        return (
            self.device == other.device
            and self.inode == other.inode
            and self.mode == other.mode
            and self.nlink == other.nlink
            and self.uid == other.uid
            and self.gid == other.gid
        )


def _check_sensitive(info: os.stat_result) -> None:
    """Aplica a política da seção 3.2 ao arquivo sensível já aberto."""
    if not stat.S_ISREG(info.st_mode):
        raise UsageError("O arquivo sensível precisa ser regular.")
    if info.st_nlink != 1:
        raise ConflictError(
            "O arquivo sensível possui mais de um link; publicação recusada."
        )
    if info.st_uid != os.getuid():
        raise UsageError("O arquivo sensível não pertence a este processo.")
    if stat.S_IMODE(info.st_mode) & _SENSITIVE_MODE_MASK:
        raise UsageError("O arquivo sensível é gravável por outros; recusado.")


def _read_sensitive(
    dir_fd: int, name: str, *, required: bool
) -> tuple[str, _SensitiveState]:
    """Lê o arquivo sensível pelo descritor do diretório, sem seguir link."""
    flags = os.O_RDONLY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0)
    try:
        descriptor = os.open(name, flags, dir_fd=dir_fd)
    except FileNotFoundError as error:
        if required:
            raise MissingInputError(
                "O arquivo sensível não existe no diretório informado."
            ) from error
        return "", _SensitiveState(None)
    except PermissionError as error:
        # Distinguir permissão de link é o que torna o diagnóstico acionável:
        # o operador precisa saber se corrige com chmod ou se removeu o link.
        raise UsageError(
            "O arquivo sensível existe mas não pode ser lido: permissão negada."
        ) from error
    except OSError as error:
        raise UsageError(
            "O arquivo sensível foi recusado na abertura (link simbólico ou tipo inválido)."
        ) from error
    try:
        info = os.fstat(descriptor)
        _check_sensitive(info)
        if info.st_size > config.MAX_DOCUMENT_BYTES:
            raise DataError(
                "O arquivo sensível excede %d bytes." % config.MAX_DOCUMENT_BYTES
            )
        blocks = []
        while True:
            block = os.read(descriptor, _READ_CHUNK)
            if not block:
                break
            blocks.append(block)
        raw = b"".join(blocks)
    finally:
        os.close(descriptor)
    try:
        return raw.decode("utf-8"), _SensitiveState(info)
    except UnicodeDecodeError as error:
        raise DataError("O arquivo sensível não está em UTF-8 válido.") from error


def _observe_sensitive(dir_fd: int, name: str) -> _SensitiveState:
    """Reobserva a identidade do alvo imediatamente antes do rename."""
    flags = os.O_RDONLY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0)
    try:
        descriptor = os.open(name, flags, dir_fd=dir_fd)
    except FileNotFoundError:
        return _SensitiveState(None)
    except OSError as error:
        raise ConflictError(
            "O alvo deixou de ser um arquivo regular acessível antes do rename."
        ) from error
    try:
        return _SensitiveState(os.fstat(descriptor))
    finally:
        os.close(descriptor)


def _publish_sensitive(
    dir_fd: int, name: str, text: str, original: _SensitiveState
) -> int:
    """Publica o texto por substituição atômica no mesmo diretório.

    A ordem é a exigida pela seção 3.2: temporário no mesmo filesystem, escrita
    completa, `fsync` do arquivo, metadados reaplicados, revalidação de device,
    inode, tipo e link count imediatamente antes do rename, rename e `fsync` do
    diretório. Qualquer divergência na revalidação é conflito (75), não
    sobrescrita.
    """
    encoded = text.encode("utf-8")
    if len(encoded) > config.MAX_DOCUMENT_BYTES:
        raise DataError("O candidato de configuração excede o limite de bytes.")
    mode = original.mode if original.exists else _CONFIG_FALLBACK_MODE
    mode &= ~_SENSITIVE_TIGHTEN_MASK
    flags = (
        os.O_WRONLY
        | os.O_CREAT
        | os.O_EXCL
        | os.O_NOFOLLOW
        | getattr(os, "O_CLOEXEC", 0)
    )
    temporary = ""
    descriptor = -1
    for _attempt in range(_TEMP_ATTEMPTS):
        candidate = "%s.tmp.%s" % (name, os.urandom(8).hex())
        try:
            descriptor = os.open(candidate, flags, 0o600, dir_fd=dir_fd)
        except FileExistsError:
            continue
        except OSError as error:
            raise PersistenceError(
                "Não foi possível criar o temporário ao lado do alvo."
            ) from error
        temporary = candidate
        break
    if not temporary:
        raise PersistenceError(
            "Não foi possível reservar um nome de temporário ao lado do alvo."
        )
    try:
        written = 0
        while written < len(encoded):
            written += os.write(descriptor, encoded[written:])
        os.fchmod(descriptor, mode)
        if original.exists and original.gid != os.getgid():
            # Reaplicar grupo só é possível quando o processo já pertence a ele;
            # falhar aqui seria pior que preservar o grupo padrão, então a
            # tentativa é explícita e tolerante.
            try:
                os.fchown(descriptor, -1, original.gid)
            except OSError:
                pass
        os.fsync(descriptor)
    except OSError as error:
        os.close(descriptor)
        _discard_temporary(dir_fd, temporary)
        raise PersistenceError(
            "Falha ao escrever o candidato de configuração."
        ) from error
    else:
        os.close(descriptor)
    observed = _observe_sensitive(dir_fd, name)
    if not original.matches(observed):
        _discard_temporary(dir_fd, temporary)
        raise ConflictError(
            "O alvo mudou entre a leitura e a publicação (device, inode, tipo, "
            "modo, dono ou link count); nada foi sobrescrito."
        )
    try:
        os.rename(temporary, name, src_dir_fd=dir_fd, dst_dir_fd=dir_fd)
    except OSError as error:
        _discard_temporary(dir_fd, temporary)
        raise PersistenceError("Falha ao publicar a configuração por rename.") from error
    try:
        os.fsync(dir_fd)
    except OSError as error:
        raise PersistenceError(
            "A configuração foi publicada, mas o diretório não pôde ser "
            "sincronizado; confirme o conteúdo antes de continuar."
        ) from error
    return len(encoded)


def _discard_temporary(dir_fd: int, name: str) -> None:
    try:
        os.unlink(name, dir_fd=dir_fd)
    except OSError:
        pass


# --- Subcomandos de domínio ---------------------------------------------------
# Todos seguem o mesmo contrato: payload por stdin ou arquivo controlado, uma
# função pura de domínio, resposta no envelope fechado. Nenhum deles abre
# caminho vindo do payload, executa comando ou escreve fora do arquivo
# controlado de candidato.

_PURE_COMMANDS: dict[str, Callable[[Mapping[str, Any]], Mapping[str, Any]]] = {
    "cpu-layout": cpu.validate_layout,
    "cpu-memory": cpu.memory_plan,
    "cpu-plan": cpu.plan_pinning,
    "cpu-topology": cpu.topology_snapshot,
    "domain-compare": domain_xml.compare_documents,
    "domain-disk-backup-target": domain_xml.disk_backup_target,
    "domain-disk-block": domain_xml.disk_block_state,
    "domain-disk-snapshot-plan": domain_xml.disk_snapshot_plan,
    "domain-disk-target": domain_xml.disk_target_state,
    "domain-fingerprint": domain_xml.fingerprint_document,
    "domain-hostdev-pci": domain_xml.hostdev_pci_state,
    "domain-interfaces": domain_xml.interface_state,
    "domain-memory-backing": domain_xml.memory_backing_state,
    "domain-metadata": domain_xml.metadata_state,
    "domain-snapshot-internal": domain_xml.snapshot_internal_state,
    "domain-usb-hostdev": domain_xml.usb_hostdev_list,
    "domain-validate-cpu": domain_xml.validate_cpu_pinning,
    "inventory-diff": inventory.diff_command,
    "inventory-disk-plan": inventory.disk_plan_command,
    "inventory-parse": inventory.parse_command,
    "inventory-usb-resolve": inventory.usb_resolve_command,
    "network-inspect": network_xml.inspect_network,
    "network-overlap": network_xml.network_overlap,
    "nvidia-download-info": nvidia_lookup.download_info,
    "nvidia-product-match": nvidia_lookup.product_match,
    "config-validate": config.validate_pair,
    "qemu-image-inspect": qemu_image.inspect_image,
}


PAYLOAD_FORMATS = ("json", "pairs")


def _read_transport(
    flags: frozenset[str], values: Mapping[str, str], streams: Streams
) -> dict:
    """Lê o payload pelo único transporte declarado e valida o envelope.

    Dois formatos de entrada são aceitos e ambos passam por schema fechado:
    `json` (envelope versionado) e `pairs` (`chave\\0valor\\0`, usado pela
    ponte para que o Bash nunca construa JSON à mão).
    """
    payload_format = values.get("--payload-format", "json")
    if payload_format not in PAYLOAD_FORMATS:
        raise UsageError(
            "Formato de payload inválido: %s; use json ou pairs."
            % protocol.safe_label(payload_format)
        )
    used_stdin = "--stdin" in flags
    used_file = "--input-file" in values
    if used_stdin == used_file:
        raise UsageError(
            "Informe exatamente um transporte: --stdin ou --input-file=CAMINHO."
        )
    raw = (
        streams.read_stdin()
        if used_stdin
        else _read_controlled_input(values["--input-file"])
    )
    if payload_format == "pairs":
        return protocol.decode_request_pairs(raw)
    return protocol.decode_request(raw)


def _make_pure_command(
    name: str, handler: Callable[[Mapping[str, Any]], Mapping[str, Any]]
) -> Callable[[list[str], Streams], bytes]:
    def command(arguments: list[str], streams: Streams) -> bytes:
        flags, values = _parse_options(
            arguments,
            frozenset({"--stdin"}),
            frozenset({"--format", "--input-file", "--payload-format"}),
        )
        chosen_format = _resolve_format(values)
        payload = _read_transport(flags, values, streams)
        data = handler(payload)
        if not isinstance(data, Mapping):
            raise InternalError("O módulo de domínio devolveu resposta inválida.")
        return _render(protocol.build_response(name, data), chosen_format)

    return command


def _command_file_output(
    name: str,
    producer: Callable[[Mapping[str, Any]], tuple[Mapping[str, Any], str]],
    arguments: list[str],
    streams: Streams,
) -> bytes:
    """Executa um produtor puro e publica seu texto em saída controlada."""
    flags, values = _parse_options(
        arguments,
        frozenset({"--stdin"}),
        frozenset(
            {"--format", "--input-file", "--output-file", "--payload-format"}
        ),
    )
    chosen_format = _resolve_format(values)
    if "--output-file" not in values:
        raise UsageError(
            "%s exige --output-file=CAMINHO controlado pela ponte." % name
        )
    payload = _read_transport(flags, values, streams)
    data, candidate = producer(payload)
    if not isinstance(data, Mapping) or not isinstance(candidate, str):
        raise InternalError("O produtor de arquivo devolveu resposta inválida.")
    written = _write_controlled_output(values["--output-file"], candidate)
    enriched = dict(data)
    enriched["bytes_written"] = written
    enriched["sha256"] = hashlib.sha256(candidate.encode("utf-8")).hexdigest()
    return _render(protocol.build_response(name, enriched), chosen_format)


def _command_inventory_normalize(arguments: list[str], streams: Streams) -> bytes:
    return _command_file_output(
        "inventory-normalize", inventory.render_report, arguments, streams
    )


def _command_domain_candidate(arguments: list[str], streams: Streams) -> bytes:
    """Gera o XML candidato e o publica no arquivo controlado da ponte.

    O texto do candidato nunca vai para stdout: stdout carrega só medidas
    (mudou ou não, quantas operações, fingerprints antes/depois e digest), de
    modo que o Bash valide o arquivo com `virt-xml-validate` e compare
    fingerprints sem precisar interpretar XML.
    """
    return _command_file_output(
        "domain-candidate", domain_xml.build_candidate, arguments, streams
    )


def _command_config_schema(arguments: list[str], streams: Streams) -> bytes:
    """Publica o schema e a classe de dado de cada chave; não lê arquivo algum."""
    _flags, values = _parse_options(arguments, frozenset(), frozenset({"--format"}))
    data = config.schema_report({})
    return _render(protocol.build_response("config-schema", data), _resolve_format(values))


def _config_file_options() -> tuple[frozenset[str], frozenset[str]]:
    return (
        frozenset({"--stdin"}),
        frozenset({"--format", "--input-file", "--payload-format", "--dir-fd"}),
    )


def _command_config_load(arguments: list[str], streams: Streams) -> bytes:
    """Lê e valida a configuração pelo descritor do diretório do alvo."""
    flags, values = _parse_options(arguments, *_config_file_options())
    chosen_format = _resolve_format(values)
    dir_fd = _resolve_dir_fd(values)
    payload = _read_transport(flags, values, streams)
    name = _sensitive_name(payload)
    text, state = _read_sensitive(dir_fd, name, required=False)
    if not state.exists:
        data: dict[str, Any] = {
            "exists": 0,
            "key_count": len(config.SCHEMA),
            "present_count": 0,
            "final_newline": 0,
            "line_count": 0,
        }
        for key in config.KEYS:
            data["value_%s" % key.lower()] = ""
            data["present_%s" % key.lower()] = 0
    else:
        data = dict(config.inspect_config({"text": text}))
        data["exists"] = 1
    data["mode_octal"] = "%04o" % state.mode if state.exists else ""
    data["mode_exposes_others"] = (
        1 if state.exists and (state.mode & _SENSITIVE_OTHERS_MASK) else 0
    )
    return _render(protocol.build_response("config-load", data), chosen_format)


def _command_config_publish(arguments: list[str], streams: Streams) -> bytes:
    """Aplica atualizações e publica a configuração por substituição atômica."""
    flags, values = _parse_options(arguments, *_config_file_options())
    chosen_format = _resolve_format(values)
    dir_fd = _resolve_dir_fd(values)
    payload = _read_transport(flags, values, streams)
    name = _sensitive_name(payload)
    text, state = _read_sensitive(dir_fd, name, required=False)
    document_payload = dict(payload)
    document_payload["text"] = text
    data, rendered = config.build_document(document_payload)
    enriched = dict(data)
    if int(data["changed"]) == 0 and state.exists:
        # Convergido: não republica. Isso mantém conteúdo, metadados e mtime
        # invariantes, como a regra de idempotência do plano exige.
        enriched["published"] = 0
        enriched["bytes_written"] = 0
        enriched["sha256"] = hashlib.sha256(text.encode("utf-8")).hexdigest()
        return _render(
            protocol.build_response("config-publish", enriched), chosen_format
        )
    written = _publish_sensitive(dir_fd, name, rendered, state)
    enriched["published"] = 1
    enriched["created"] = 0 if state.exists else 1
    enriched["bytes_written"] = written
    enriched["sha256"] = hashlib.sha256(rendered.encode("utf-8")).hexdigest()
    return _render(protocol.build_response("config-publish", enriched), chosen_format)


def _command_config_legacy_scan(arguments: list[str], streams: Streams) -> bytes:
    """Classifica as chaves de ISO antes do parser estrito (REQ-CONF-ISO)."""
    flags, values = _parse_options(arguments, *_config_file_options())
    chosen_format = _resolve_format(values)
    dir_fd = _resolve_dir_fd(values)
    payload = _read_transport(flags, values, streams)
    name = _sensitive_name(payload)
    text, state = _read_sensitive(dir_fd, name, required=False)
    if not state.exists:
        data: dict[str, Any] = {
            "exists": 0,
            "needs_migration": 0,
            "scanned_keys": len(config.LEGACY_SCAN_KEYS),
        }
        for key in config.LEGACY_SCAN_KEYS:
            data["iso_%s_state" % key.lower().replace("iso_", "")] = "ausente"
    else:
        data = dict(config.legacy_scan({"text": text}))
        data["exists"] = 1
    return _render(
        protocol.build_response("config-legacy-scan", data), chosen_format
    )


SUBCOMMANDS: dict[str, Callable[[list[str], Streams], bytes]] = {
    "config-legacy-scan": _command_config_legacy_scan,
    "config-load": _command_config_load,
    "config-publish": _command_config_publish,
    "config-schema": _command_config_schema,
    "domain-candidate": _command_domain_candidate,
    "inventory-normalize": _command_inventory_normalize,
    "payload-probe": _command_payload_probe,
    "version": _command_version,
}
for _name, _handler in _PURE_COMMANDS.items():
    SUBCOMMANDS[_name] = _make_pure_command(_name, _handler)


def main(
    argv: list[str],
    stdin: BinaryIO | None = None,
    stdout: BinaryIO | None = None,
    stderr: BinaryIO | None = None,
) -> int:
    """Executa um subcomando e devolve o código interno.

    Em erro nada é escrito em stdout: a resposta só é emitida depois que todo
    o processamento terminou com sucesso.
    """
    streams = Streams(stdin, stdout, stderr)
    traceback_enabled = False
    try:
        arguments = list(argv)
        if arguments and arguments[0] == "--traceback":
            traceback_enabled = True
            arguments = arguments[1:]
        if not arguments:
            raise UsageError("Subcomando ausente.\n%s" % USAGE)
        name = arguments[0]
        handler = SUBCOMMANDS.get(name)
        if handler is None:
            raise UsageError(
                "Subcomando desconhecido: %s.\n%s" % (protocol.safe_label(name), USAGE)
            )
        rendered = handler(arguments[1:], streams)
    except CoreError as error:
        streams.write_error(error.message, error, traceback_enabled)
        return error.exit_code
    except Exception as error:  # noqa: BLE001 - traceback só em modo explícito
        streams.write_error(
            "Falha interna do core (%s)." % type(error).__name__,
            error,
            traceback_enabled,
        )
        return EXIT_INTERNAL
    streams.write_output(rendered)
    return EXIT_OK
