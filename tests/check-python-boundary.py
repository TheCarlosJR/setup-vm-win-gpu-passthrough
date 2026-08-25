#!/usr/bin/env python3
"""Gate AST da fronteira pura Python/Bash.

Recusa processo, rede, elevação e execução dinâmica no package do core. A CLI
pode usar primitivas de arquivo controlado; módulos de domínio, especialmente
inventory.py, não podem abrir caminhos nem sondar o host.
"""
from __future__ import annotations

import argparse
import ast
from pathlib import Path

FORBIDDEN_MODULES = {
    "subprocess", "socket", "urllib", "http", "ctypes", "multiprocessing",
    "pty", "libvirt", "requests",
}
FORBIDDEN_OS_ATTRIBUTES = {
    "system", "popen", "execv", "execve", "execvp", "execl", "execle",
    "execlp", "spawnv", "spawnve", "spawnl", "spawnlp", "fork", "forkpty",
    "posix_spawn", "posix_spawnp", "setuid", "seteuid", "setgid", "setegid",
}
DYNAMIC_NAMES = {"eval", "exec", "compile", "__import__"}
INVENTORY_FORBIDDEN_NAMES = {"open", "input"}
INVENTORY_FORBIDDEN_MODULES = {"os", "pathlib", "shutil", "sys", "tempfile"}


def inspect(path: Path) -> list[str]:
    failures: list[str] = []
    tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
    is_inventory = path.name == "inventory.py"
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                base = alias.name.split(".")[0]
                if base in FORBIDDEN_MODULES or is_inventory and base in INVENTORY_FORBIDDEN_MODULES:
                    failures.append(f"{path}:{node.lineno}: import proibido {alias.name}")
        elif isinstance(node, ast.ImportFrom):
            base = (node.module or "").split(".")[0]
            if base in FORBIDDEN_MODULES or is_inventory and base in INVENTORY_FORBIDDEN_MODULES:
                failures.append(f"{path}:{node.lineno}: import proibido {node.module}")
        elif isinstance(node, ast.Attribute):
            if isinstance(node.value, ast.Name) and node.value.id == "os" and node.attr in FORBIDDEN_OS_ATTRIBUTES:
                failures.append(f"{path}:{node.lineno}: os.{node.attr} proibido")
        elif isinstance(node, ast.Name):
            if node.id in DYNAMIC_NAMES or is_inventory and node.id in INVENTORY_FORBIDDEN_NAMES:
                failures.append(f"{path}:{node.lineno}: nome proibido {node.id}")
    return failures


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True)
    args = parser.parse_args()
    root = Path(args.root).resolve()
    package = root / "libexec" / "passthrough_core"
    failures: list[str] = []
    for path in sorted(package.glob("*.py")):
        failures.extend(inspect(path))
    for failure in failures:
        print(failure)
    if failures:
        return 1
    print("OK: fronteira Python pura sem processo, rede, elevação ou probes no inventory.py")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
