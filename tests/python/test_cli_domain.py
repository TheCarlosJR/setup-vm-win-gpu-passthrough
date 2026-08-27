"""CLI dos subcomandos de domínio: transporte, pares de entrada e candidatos.

Cobre o que I3 acrescentou à fronteira: os subcomandos novos, o canal de
entrada `chave\\0valor\\0` (para que o Bash nunca construa JSON) e a política do
arquivo controlado de saída onde o candidato é publicado.
"""
import hashlib
import io
import json
import os
import stat
import tempfile
import unittest

from passthrough_core import cli, errors, protocol

import fixtures_i3 as fx
import fixtures_i7 as pf

NUL = chr(0)
CANARIO = "CANARIO-SECRETO-I3-4b7f1e"


def executar(argv: list, entrada: bytes = b"") -> tuple:
    stdin = io.BytesIO(entrada)
    stdout = io.BytesIO()
    stderr = io.BytesIO()
    codigo = cli.main(argv, stdin=stdin, stdout=stdout, stderr=stderr)
    return codigo, stdout.getvalue(), stderr.getvalue()


def envelope(payload: dict) -> bytes:
    return json.dumps(
        {"protocol_version": 1, "payload": payload}, ensure_ascii=False
    ).encode("utf-8")


def pares(payload: dict) -> bytes:
    blocos = []
    for chave, valor in payload.items():
        blocos.append(chave.encode("utf-8") + b"\x00" + str(valor).encode("utf-8") + b"\x00")
    return b"".join(blocos)


def dados(saida: bytes) -> dict:
    return json.loads(saida.decode("utf-8"))["data"]


class SubcommandRegistryTests(unittest.TestCase):
    def test_todos_os_subcomandos_de_i3_existem(self) -> None:
        esperados = {
            "domain-candidate",
            "domain-compare",
            "domain-disk-backup-target",
            "domain-disk-block",
            "domain-disk-snapshot-plan",
            "domain-disk-target",
            "domain-fingerprint",
            "domain-hostdev-pci",
            "domain-interfaces",
            "domain-memory-backing",
            "domain-metadata",
            "domain-snapshot-internal",
            "domain-usb-hostdev",
            "domain-validate-cpu",
            "network-address-check",
            "network-consumers",
            "network-inspect",
            "network-nat-addresses",
            "network-overlap",
            "network-plan",
            "network-route-audit",
            "qemu-image-inspect",
        }
        self.assertTrue(esperados.issubset(set(cli.SUBCOMMANDS)))

    def test_usage_lista_os_subcomandos(self) -> None:
        for nome in ("domain-disk-target", "domain-candidate", "qemu-image-inspect"):
            self.assertIn(nome, cli.USAGE)

    def test_subcomando_desconhecido(self) -> None:
        codigo, saida, diagnostico = executar(["domain-inexistente", "--stdin"])
        self.assertEqual(codigo, errors.EXIT_USAGE)
        self.assertEqual(saida, b"")
        self.assertIn(b"Subcomando desconhecido", diagnostico)


class TransportTests(unittest.TestCase):
    def test_json_por_stdin(self) -> None:
        codigo, saida, diagnostico = executar(
            ["domain-disk-target", "--stdin"],
            envelope({"xml": fx.domain(), "qcow2_path": fx.QCOW2}),
        )
        self.assertEqual(codigo, errors.EXIT_OK)
        self.assertEqual(diagnostico, b"")
        self.assertEqual(dados(saida)["state"], "ausente")

    def test_pares_por_stdin(self) -> None:
        codigo, saida, _ = executar(
            ["domain-disk-target", "--stdin", "--payload-format=pairs"],
            pares({"xml": fx.domain(discard="unmap"), "qcow2_path": fx.QCOW2}),
        )
        self.assertEqual(codigo, errors.EXIT_OK)
        self.assertEqual(dados(saida)["state"], "ativo")

    def test_pares_com_xml_contendo_aspas_e_barras(self) -> None:
        # O canal de pares existe justamente para não exigir escape manual.
        xml = fx.domain(
            interfaces="<interface type='network'><mac address='%s'/>"
            "<source network='default'/>"
            '<alias name="net0&amp;&quot;\\"/></interface>' % fx.NIC_MAC
        )
        codigo, saida, _ = executar(
            ["domain-fingerprint", "--stdin", "--payload-format=pairs"],
            pares({"xml": xml}),
        )
        self.assertEqual(codigo, errors.EXIT_OK)
        self.assertRegex(dados(saida)["fingerprint"], r"^[0-9a-f]{64}$")

    def test_pares_com_unicode(self) -> None:
        xml = fx.domain().replace(
            "<name>fixture-win11</name>", "<name>fixture-instalação</name>"
        )
        codigo, _saida, _ = executar(
            ["domain-fingerprint", "--stdin", "--payload-format=pairs"],
            pares({"xml": xml}),
        )
        self.assertEqual(codigo, errors.EXIT_OK)

    def test_pares_sem_nul_final(self) -> None:
        codigo, saida, diagnostico = executar(
            ["domain-fingerprint", "--stdin", "--payload-format=pairs"],
            b"xml\x00<domain/>",
        )
        self.assertEqual(codigo, errors.EXIT_DATA)
        self.assertEqual(saida, b"")
        self.assertIn("terminar em NUL".encode("utf-8"), diagnostico)

    def test_pares_com_paridade_invalida(self) -> None:
        codigo, _saida, diagnostico = executar(
            ["domain-fingerprint", "--stdin", "--payload-format=pairs"],
            b"xml\x00<domain/>\x00extra\x00",
        )
        self.assertEqual(codigo, errors.EXIT_DATA)
        self.assertIn(b"paridade", diagnostico)

    def test_pares_com_chave_maiuscula_recusada(self) -> None:
        codigo, _saida, diagnostico = executar(
            ["domain-fingerprint", "--stdin", "--payload-format=pairs"],
            b"XML\x00<domain/>\x00",
        )
        self.assertEqual(codigo, errors.EXIT_DATA)
        self.assertIn("Chave inv".encode("utf-8"), diagnostico)

    def test_pares_com_chave_duplicada(self) -> None:
        codigo, _saida, diagnostico = executar(
            ["domain-fingerprint", "--stdin", "--payload-format=pairs"],
            b"xml\x00<a/>\x00xml\x00<b/>\x00",
        )
        self.assertEqual(codigo, errors.EXIT_DATA)
        self.assertIn(b"duplicada", diagnostico)

    def test_pares_vazio(self) -> None:
        codigo, _saida, _ = executar(
            ["domain-fingerprint", "--stdin", "--payload-format=pairs"], b""
        )
        self.assertEqual(codigo, errors.EXIT_MISSING_INPUT)

    def test_pares_acima_do_limite_de_campos(self) -> None:
        muitos = {}
        for indice in range(protocol.MAX_REQUEST_PAIRS + 1):
            muitos["campo_%d" % indice] = "x"
        codigo, _saida, diagnostico = executar(
            ["domain-fingerprint", "--stdin", "--payload-format=pairs"], pares(muitos)
        )
        self.assertEqual(codigo, errors.EXIT_DATA)
        self.assertIn(b"pares", diagnostico)

    def test_formato_de_payload_invalido(self) -> None:
        codigo, _saida, diagnostico = executar(
            ["domain-fingerprint", "--stdin", "--payload-format=yaml"], b"x"
        )
        self.assertEqual(codigo, errors.EXIT_USAGE)
        self.assertIn("Formato de payload".encode("utf-8"), diagnostico)

    def test_transporte_ambiguo(self) -> None:
        codigo, _saida, diagnostico = executar(
            ["domain-fingerprint", "--stdin", "--input-file=/tmp/x"], b"x"
        )
        self.assertEqual(codigo, errors.EXIT_USAGE)
        self.assertIn("exatamente um transporte".encode("utf-8"), diagnostico)

    def test_sem_transporte(self) -> None:
        codigo, _saida, _ = executar(["domain-fingerprint"])
        self.assertEqual(codigo, errors.EXIT_USAGE)

    def test_xml_nunca_entra_em_argv(self) -> None:
        # O XML só é aceito por stdin/arquivo: passá-lo como posicional é uso.
        codigo, _saida, diagnostico = executar(
            ["domain-fingerprint", fx.domain(), "--stdin"], envelope({"xml": fx.domain()})
        )
        self.assertEqual(codigo, errors.EXIT_USAGE)
        self.assertIn(b"posicional", diagnostico)

    def test_canario_nao_vaza_no_diagnostico(self) -> None:
        xml = fx.domain().replace(
            "<name>fixture-win11</name>", "<name>%s</name>" % CANARIO
        )
        codigo, saida, diagnostico = executar(
            ["domain-disk-target", "--stdin", "--payload-format=pairs"],
            pares({"xml": xml, "qcow2_path": "/vm/inexistente.qcow2"}),
        )
        self.assertEqual(codigo, errors.EXIT_DATA)
        self.assertEqual(saida, b"")
        self.assertNotIn(CANARIO.encode("utf-8"), diagnostico)

    def test_saida_em_pares_projeta_todos_os_campos(self) -> None:
        codigo, saida, _ = executar(
            ["domain-disk-target", "--stdin", "--format=pairs"],
            envelope({"xml": fx.domain(), "qcow2_path": fx.QCOW2}),
        )
        self.assertEqual(codigo, errors.EXIT_OK)
        campos = saida.decode("utf-8").split(NUL)[:-1]
        chaves = campos[0::2]
        self.assertIn("STATE", chaves)
        self.assertIn("FINGERPRINT", chaves)
        self.assertIn("SUBCOMMAND", chaves)

    def test_lista_indexada_no_canal_de_pares(self) -> None:
        codigo, saida, _ = executar(
            ["domain-interfaces", "--stdin", "--format=pairs"],
            envelope({"xml": fx.domain(), "nic_mac": fx.NIC_MAC}),
        )
        self.assertEqual(codigo, errors.EXIT_OK)
        campos = saida.decode("utf-8").split(NUL)[:-1]
        mapa = dict(zip(campos[0::2], campos[1::2]))
        self.assertEqual(mapa["NIC_COUNT"], "1")
        self.assertEqual(mapa["NIC_0_MAC"], fx.NIC_MAC.lower())


class CandidateOutputTests(unittest.TestCase):
    def setUp(self) -> None:
        self.raiz = tempfile.mkdtemp(prefix="i3-candidato.")
        os.chmod(self.raiz, 0o700)
        self.destino = os.path.join(self.raiz, "candidato")
        with open(self.destino, "wb"):
            pass
        os.chmod(self.destino, 0o600)

    def tearDown(self) -> None:
        for nome in os.listdir(self.raiz):
            caminho = os.path.join(self.raiz, nome)
            if os.path.islink(caminho) or os.path.isfile(caminho):
                os.unlink(caminho)
            else:
                os.rmdir(caminho)
        os.rmdir(self.raiz)

    def gerar(self, payload: dict, saida: str | None = None) -> tuple:
        return executar(
            [
                "domain-candidate",
                "--stdin",
                "--output-file=%s" % (saida if saida is not None else self.destino),
            ],
            envelope(payload),
        )

    def test_publica_candidato_e_mede(self) -> None:
        codigo, saida, diagnostico = self.gerar(
            {
                "xml": fx.domain(),
                "operations": [
                    {"op": "disk-discard", "options": {"qcow2_path": fx.QCOW2}}
                ],
            }
        )
        self.assertEqual(codigo, errors.EXIT_OK)
        self.assertEqual(diagnostico, b"")
        medidas = dados(saida)
        with open(self.destino, "rb") as fluxo:
            conteudo = fluxo.read()
        self.assertEqual(medidas["bytes_written"], len(conteudo))
        self.assertEqual(medidas["sha256"], hashlib.sha256(conteudo).hexdigest())
        self.assertEqual(medidas["changed"], 1)
        self.assertIn(b'discard="unmap"', conteudo)
        # stdout carrega somente medidas: o XML não aparece no canal de máquina.
        self.assertNotIn(b"<domain", saida)

    def test_modo_do_destino_preservado(self) -> None:
        self.gerar(
            {"xml": fx.domain(), "operations": [{"op": "remove-video"}]}
        )
        info = os.stat(self.destino)
        self.assertEqual(stat.S_IMODE(info.st_mode), 0o600)
        self.assertEqual(info.st_nlink, 1)

    def test_reescrita_trunca(self) -> None:
        with open(self.destino, "wb") as fluxo:
            fluxo.write(b"x" * 5000)
        codigo, saida, _ = self.gerar(
            {"xml": fx.domain(), "operations": [{"op": "remove-video"}]}
        )
        self.assertEqual(codigo, errors.EXIT_OK)
        self.assertEqual(os.path.getsize(self.destino), dados(saida)["bytes_written"])

    def test_sem_output_file(self) -> None:
        codigo, _saida, diagnostico = executar(
            ["domain-candidate", "--stdin"],
            envelope({"xml": fx.domain(), "operations": [{"op": "remove-video"}]}),
        )
        self.assertEqual(codigo, errors.EXIT_USAGE)
        self.assertIn(b"--output-file", diagnostico)

    def test_destino_relativo(self) -> None:
        codigo, _saida, diagnostico = self.gerar(
            {"xml": fx.domain(), "operations": [{"op": "remove-video"}]},
            saida="candidato",
        )
        self.assertEqual(codigo, errors.EXIT_USAGE)
        self.assertIn(b"absoluto", diagnostico)

    def test_destino_nao_canonico(self) -> None:
        codigo, _saida, _ = self.gerar(
            {"xml": fx.domain(), "operations": [{"op": "remove-video"}]},
            saida=os.path.join(self.raiz, "..", os.path.basename(self.raiz), "candidato"),
        )
        self.assertEqual(codigo, errors.EXIT_USAGE)

    def test_destino_inexistente(self) -> None:
        codigo, _saida, diagnostico = self.gerar(
            {"xml": fx.domain(), "operations": [{"op": "remove-video"}]},
            saida=os.path.join(self.raiz, "ausente"),
        )
        self.assertEqual(codigo, errors.EXIT_MISSING_INPUT)
        self.assertIn("precisa criá-lo".encode("utf-8"), diagnostico)

    def test_destino_simbolico(self) -> None:
        alvo = os.path.join(self.raiz, "real")
        with open(alvo, "wb"):
            pass
        os.chmod(alvo, 0o600)
        link = os.path.join(self.raiz, "link")
        os.symlink(alvo, link)
        codigo, _saida, _ = self.gerar(
            {"xml": fx.domain(), "operations": [{"op": "remove-video"}]}, saida=link
        )
        self.assertEqual(codigo, errors.EXIT_USAGE)
        self.assertEqual(os.path.getsize(alvo), 0)

    def test_destino_com_dois_links(self) -> None:
        outro = os.path.join(self.raiz, "hardlink")
        os.link(self.destino, outro)
        codigo, _saida, diagnostico = self.gerar(
            {"xml": fx.domain(), "operations": [{"op": "remove-video"}]}
        )
        self.assertEqual(codigo, errors.EXIT_USAGE)
        self.assertIn("mais de um link".encode("utf-8"), diagnostico)
        self.assertEqual(os.path.getsize(outro), 0)

    def test_destino_com_modo_permissivo(self) -> None:
        os.chmod(self.destino, 0o644)
        codigo, _saida, diagnostico = self.gerar(
            {"xml": fx.domain(), "operations": [{"op": "remove-video"}]}
        )
        self.assertEqual(codigo, errors.EXIT_USAGE)
        self.assertIn(b"0600", diagnostico)

    def test_destino_e_diretorio(self) -> None:
        pasta = os.path.join(self.raiz, "pasta")
        os.mkdir(pasta, 0o700)
        codigo, _saida, _ = self.gerar(
            {"xml": fx.domain(), "operations": [{"op": "remove-video"}]}, saida=pasta
        )
        self.assertNotEqual(codigo, errors.EXIT_OK)

    def test_raiz_permissiva(self) -> None:
        os.chmod(self.raiz, 0o755)
        try:
            codigo, _saida, diagnostico = self.gerar(
                {"xml": fx.domain(), "operations": [{"op": "remove-video"}]}
            )
        finally:
            os.chmod(self.raiz, 0o700)
        self.assertEqual(codigo, errors.EXIT_USAGE)
        self.assertIn("negar grupo".encode("utf-8"), diagnostico)

    def test_raiz_inexistente(self) -> None:
        codigo, _saida, _ = self.gerar(
            {"xml": fx.domain(), "operations": [{"op": "remove-video"}]},
            saida="/nao-existe-i3/candidato",
        )
        self.assertEqual(codigo, errors.EXIT_MISSING_INPUT)

    def test_candidato_recusado_nao_toca_o_destino(self) -> None:
        with open(self.destino, "wb") as fluxo:
            fluxo.write(b"CONTEUDO-ANTERIOR")
        codigo, _saida, _ = self.gerar(
            {"xml": fx.domain(), "operations": [{"op": "operacao-inexistente"}]}
        )
        self.assertEqual(codigo, errors.EXIT_DATA)
        with open(self.destino, "rb") as fluxo:
            self.assertEqual(fluxo.read(), b"CONTEUDO-ANTERIOR")

    def test_candidato_por_pares(self) -> None:
        codigo, saida, _ = executar(
            [
                "domain-candidate",
                "--stdin",
                "--payload-format=pairs",
                "--output-file=%s" % self.destino,
            ],
            pares(
                {
                    "xml": fx.domain(),
                    "op_count": "1",
                    "op_0": "disk-discard",
                    "op_0_qcow2_path": fx.QCOW2,
                }
            ),
        )
        self.assertEqual(codigo, errors.EXIT_OK)
        self.assertEqual(dados(saida)["changed"], 1)

    def test_candidato_em_pares_na_saida(self) -> None:
        codigo, saida, _ = executar(
            [
                "domain-candidate",
                "--stdin",
                "--format=pairs",
                "--output-file=%s" % self.destino,
            ],
            envelope({"xml": fx.domain(), "operations": [{"op": "remove-video"}]}),
        )
        self.assertEqual(codigo, errors.EXIT_OK)
        campos = saida.decode("utf-8").split(NUL)[:-1]
        mapa = dict(zip(campos[0::2], campos[1::2]))
        self.assertEqual(mapa["CHANGED"], "1")
        self.assertIn("FINGERPRINT_BEFORE", mapa)
        self.assertIn("BYTES_WRITTEN", mapa)


class NetworkAddressCommandTests(unittest.TestCase):
    """Subcomandos puros de I7.2, no mesmo contrato de `network-inspect`."""

    def test_usage_lista_os_subcomandos_de_i7(self) -> None:
        for nome in (
            "network-address-check",
            "network-nat-addresses",
            "network-plan",
            "network-route-audit",
        ):
            with self.subTest(nome=nome):
                self.assertIn(nome, cli.USAGE)

    def test_nat_por_stdin_em_json(self) -> None:
        codigo, saida, diagnostico = executar(
            ["network-nat-addresses", "--stdin"],
            envelope({"cidr": "192.168.177.0/24"}),
        )
        self.assertEqual(codigo, errors.EXIT_OK)
        self.assertEqual(diagnostico, b"")
        campos = dados(saida)
        self.assertEqual(campos["nat_gateway"], "192.168.177.1")
        self.assertEqual(campos["nat_vm_ip"], "192.168.177.10")
        self.assertEqual(campos["nat_dhcp_inicio"], "192.168.177.100")
        self.assertEqual(campos["nat_dhcp_fim"], "192.168.177.254")
        self.assertEqual(campos["nat_broadcast"], "192.168.177.255")
        self.assertEqual(campos["nat_host_ip"], "192.168.177.1")

    def test_nat_por_pares_nos_dois_sentidos(self) -> None:
        codigo, saida, _ = executar(
            [
                "network-nat-addresses",
                "--stdin",
                "--payload-format=pairs",
                "--format=pairs",
            ],
            pares({"cidr": "10.0.0.0/24"}),
        )
        self.assertEqual(codigo, errors.EXIT_OK)
        campos = saida.decode("utf-8").split(NUL)[:-1]
        mapa = dict(zip(campos[0::2], campos[1::2]))
        # As chaves projetadas são exatamente as variáveis que
        # `derivar_parametros_nat` exporta hoje.
        self.assertEqual(mapa["NAT_GATEWAY"], "10.0.0.1")
        self.assertEqual(mapa["NAT_VM_IP"], "10.0.0.10")
        self.assertEqual(mapa["NAT_DHCP_INICIO"], "10.0.0.100")
        self.assertEqual(mapa["NAT_DHCP_FIM"], "10.0.0.254")
        self.assertEqual(mapa["SUBCOMMAND"], "network-nat-addresses")

    def test_address_check_por_pares(self) -> None:
        codigo, saida, _ = executar(
            [
                "network-address-check",
                "--stdin",
                "--payload-format=pairs",
                "--format=pairs",
            ],
            pares(
                {
                    "cidr": "192.168.0.7/24",
                    "host_ip": "192.168.0.7",
                    "vm_ip": "192.168.0.55",
                }
            ),
        )
        self.assertEqual(codigo, errors.EXIT_OK)
        campos = saida.decode("utf-8").split(NUL)[:-1]
        mapa = dict(zip(campos[0::2], campos[1::2]))
        self.assertEqual(mapa["ACCEPTED"], "1")
        self.assertEqual(mapa["BROADCAST"], "192.168.0.255")

    def test_route_audit_por_stdin(self) -> None:
        rota = {
            "destination": "192.168.177.0/24",
            "device": "virbr9",
            "gateway": "",
            "metric": None,
            "protocol": "kernel",
            "scope": "link",
            "source": "192.168.177.1",
            "table": "main",
            "type": "unicast",
        }
        codigo, saida, diagnostico = executar(
            ["network-route-audit", "--stdin"],
            envelope(
                {
                    "candidate_cidr": "192.168.177.0/24",
                    "managed": {
                        "present": True,
                        "family": "ipv4",
                        "cidr": "192.168.177.0/24",
                        "gateway": "192.168.177.1",
                        "bridge": "virbr9",
                    },
                    "routes": [rota],
                }
            ),
        )
        self.assertEqual(codigo, errors.EXIT_OK)
        self.assertEqual(diagnostico, b"")
        campos = dados(saida)
        self.assertEqual(campos["route_count"], 1)
        self.assertEqual(campos["exception_count"], 1)
        self.assertEqual(campos["collision_count"], 0)
        self.assertEqual(campos["route_0_kernel_exception"], 1)

    def test_recusa_tipada_nao_escreve_em_stdout(self) -> None:
        casos = (
            (["network-nat-addresses", "--stdin"], {"cidr": "fd00::/64"}),
            (["network-nat-addresses", "--stdin"], {"cidr": "192.168.177.0/25"}),
            (
                ["network-address-check", "--stdin"],
                {"cidr": "192.168.0.7/24", "host_ip": "192.168.0.7"},
            ),
            (
                ["network-route-audit", "--stdin"],
                {"candidate_cidr": "10.0.0.0/24", "routes": []},
            ),
        )
        for argv, payload in casos:
            with self.subTest(argv=argv[0], payload=sorted(payload)):
                codigo, saida, diagnostico = executar(argv, envelope(payload))
                self.assertEqual(codigo, errors.EXIT_DATA)
                self.assertEqual(saida, b"")
                self.assertTrue(diagnostico)

    def test_saida_repetida_e_identica(self) -> None:
        argv = ["network-nat-addresses", "--stdin"]
        entrada = envelope({"cidr": "172.16.0.0/24"})
        self.assertEqual(executar(argv, entrada), executar(argv, entrada))


class NetworkPlanCommandTests(unittest.TestCase):
    """`network-plan` (I7.3): entrada estruturada, saída escalar determinística."""

    def test_plano_nat_por_stdin_em_json(self) -> None:
        codigo, saida, diagnostico = executar(
            ["network-plan", "--stdin"], envelope(pf.pedido_nat())
        )
        self.assertEqual(codigo, errors.EXIT_OK)
        self.assertEqual(diagnostico, b"")
        campos = dados(saida)
        self.assertEqual(campos["accepted"], 1)
        self.assertEqual(campos["mode"], "nat")
        self.assertEqual(campos["operation_count"], 11)
        self.assertEqual(campos["rollback_count"], 4)
        self.assertEqual(campos["blocking_precondition"], "")
        # A projeção é indexada a partir de zero; a operação 5 do plano é
        # `operation_4_*` no canal escalar.
        self.assertEqual(campos["operation_4_verb"], "network-define")
        self.assertEqual(campos["operation_4_id"], "OP-05-NETWORK_DEFINE")
        self.assertRegex(campos["plan_sha256"], r"^[0-9a-f]{64}$")

    def test_plano_bridge_por_pares_na_saida(self) -> None:
        codigo, saida, _ = executar(
            ["network-plan", "--stdin", "--format=pairs"],
            envelope(pf.pedido_bridge()),
        )
        self.assertEqual(codigo, errors.EXIT_OK)
        campos = saida.decode("utf-8").split(NUL)[:-1]
        mapa = dict(zip(campos[0::2], campos[1::2]))
        self.assertEqual(mapa["SUBCOMMAND"], "network-plan")
        self.assertEqual(mapa["MODE"], "bridge")
        self.assertEqual(mapa["OPERATION_COUNT"], "10")
        self.assertEqual(mapa["ROLLBACK_COUNT"], "4")
        self.assertEqual(
            mapa["ROLLBACK_IDS"].split("\n"),
            [
                "RB-01-HOST_PROFILE_DISCARD",
                "RB-02-HOST_NETWORK_ACTIVATE",
                "RB-03-DOMAIN_RESTORE",
                "RB-04-CONFIGURATION_RESTORE",
            ],
        )
        self.assertEqual(mapa["OPERATION_0_ARGUMENT_KEY"], "REDE_BRIDGE")

    def test_plano_recusado_nao_traz_operacao(self) -> None:
        codigo, saida, diagnostico = executar(
            ["network-plan", "--stdin"],
            envelope(pf.pedido_nat(target=pf.alvo(active=True))),
        )
        self.assertEqual(codigo, errors.EXIT_OK)
        self.assertEqual(diagnostico, b"")
        campos = dados(saida)
        self.assertEqual(campos["accepted"], 0)
        self.assertEqual(campos["blocking_precondition"], "P-DOMAIN-STOPPED")
        self.assertEqual(campos["operation_count"], 0)
        self.assertEqual(campos["rollback_count"], 0)

    def test_recusa_tipada_nao_escreve_em_stdout(self) -> None:
        casos = (
            {},
            {"schema_version": 1},
            dict(pf.pedido_nat(), schema_version=2),
        )
        for indice, payload in enumerate(casos):
            with self.subTest(caso=indice):
                codigo, saida, diagnostico = executar(
                    ["network-plan", "--stdin"], envelope(payload)
                )
                self.assertEqual(codigo, errors.EXIT_DATA)
                self.assertEqual(saida, b"")
                self.assertTrue(diagnostico)

    def test_saida_repetida_e_identica(self) -> None:
        argv = ["network-plan", "--stdin"]
        entrada = envelope(pf.pedido_bridge())
        self.assertEqual(executar(argv, entrada), executar(argv, entrada))

    def test_nenhum_token_de_ferramenta_na_resposta(self) -> None:
        for payload in (pf.pedido_nat(), pf.pedido_bridge()):
            codigo, saida, _ = executar(["network-plan", "--stdin"], envelope(payload))
            self.assertEqual(codigo, errors.EXIT_OK)
            texto = saida.decode("utf-8").lower()
            for token in pf.TOKENS_DE_FERRAMENTA:
                self.assertNotIn(token, texto)


class NetworkConsumerCommandTests(unittest.TestCase):
    """`network-consumers` (I7.4): inventário estruturado, saída escalar."""

    def test_usage_e_registro(self) -> None:
        self.assertIn("network-consumers", cli.USAGE)
        self.assertIn("network-consumers", cli.SUBCOMMANDS)

    def test_consumidor_definido_por_stdin_em_json(self) -> None:
        codigo, saida, diagnostico = executar(
            ["network-consumers", "--stdin"], envelope(pf.inventario())
        )
        self.assertEqual(codigo, errors.EXIT_OK)
        self.assertEqual(diagnostico, b"")
        campos = dados(saida)
        self.assertEqual(campos["defined_consumer_count"], 1)
        self.assertEqual(campos["defined_consumer_names"], pf.OUTRA_VM)
        self.assertEqual(campos["active_consumer_count"], 0)
        self.assertEqual(campos["network_owned"], 1)
        self.assertEqual(campos["consumer_0_name"], pf.OUTRA_VM)
        self.assertEqual(campos["parity_consumer_count"], 1)
        self.assertRegex(campos["report_sha256"], r"^[0-9a-f]{64}$")

    def test_consumidor_ativo_por_pares_na_saida(self) -> None:
        pedido = pf.inventario(
            domains=[pf.dominio(pf.VM), pf.dominio(pf.OUTRA_VM, active=True)]
        )
        codigo, saida, _ = executar(
            ["network-consumers", "--stdin", "--format=pairs"], envelope(pedido)
        )
        self.assertEqual(codigo, errors.EXIT_OK)
        campos = saida.decode("utf-8").split(NUL)[:-1]
        mapa = dict(zip(campos[0::2], campos[1::2]))
        self.assertEqual(mapa["SUBCOMMAND"], "network-consumers")
        self.assertEqual(mapa["ACTIVE_CONSUMER_NAMES"], pf.OUTRA_VM)
        self.assertEqual(mapa["DEFINED_CONSUMER_NAMES"], pf.OUTRA_VM)
        self.assertEqual(mapa["ACTIVE_CONSUMER_COUNT"], "1")

    def test_recusa_tipada_nao_escreve_em_stdout(self) -> None:
        casos = (
            {},
            {"schema_version": 1},
            dict(pf.inventario(), schema_version=2),
            dict(pf.inventario(), marker=""),
        )
        for indice, payload in enumerate(casos):
            with self.subTest(caso=indice):
                codigo, saida, diagnostico = executar(
                    ["network-consumers", "--stdin"], envelope(payload)
                )
                self.assertEqual(codigo, errors.EXIT_DATA)
                self.assertEqual(saida, b"")
                self.assertTrue(diagnostico)

    def test_saida_repetida_e_identica(self) -> None:
        argv = ["network-consumers", "--stdin"]
        entrada = envelope(pf.inventario())
        self.assertEqual(executar(argv, entrada), executar(argv, entrada))



if __name__ == "__main__":
    unittest.main()
