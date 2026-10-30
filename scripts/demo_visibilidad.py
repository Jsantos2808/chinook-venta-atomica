"""Coordina las sesiones A y B de la prueba de visibilidad.

A confirma una venta nueva, pero deja la transacción abierta hasta que B
haya podido consultar. B no adivina el invoice_id: busca la marca.

Uso:
    python scripts/demo_visibilidad.py
    python scripts/demo_visibilidad.py PRACTICA-VISIBILIDAD-2
"""

from __future__ import annotations

import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EVIDENCIA = ROOT / "evidencia"
MARCA = sys.argv[1] if len(sys.argv) > 1 else "PRACTICA-VISIBILIDAD"


def usuario() -> str:
    for line in (ROOT / ".env").read_text(encoding="utf-8").splitlines():
        if line.startswith("POSTGRES_USER="):
            return line.split("=", 1)[1].strip()
    return "chinook"


def compose(*args: str, log: Path | None = None) -> subprocess.CompletedProcess[str]:
    command = ["docker", "compose", "exec", "-T", "db", *args]
    if log is None:
        return subprocess.run(
            command,
            cwd=ROOT,
            check=False,
            text=True,
            encoding="utf-8",
            errors="replace",
            capture_output=True,
        )
    with log.open("w", encoding="utf-8", newline="\n") as handle:
        return subprocess.run(
            command,
            cwd=ROOT,
            check=False,
            text=True,
            encoding="utf-8",
            errors="replace",
            stdout=handle,
            stderr=subprocess.STDOUT,
        )


def esperar_archivo(ruta: str, proceso: subprocess.Popen[str], segundos: float) -> None:
    limite = time.time() + segundos
    while time.time() < limite:
        if proceso.poll() is not None:
            raise RuntimeError(
                f"La sesion A termino con codigo {proceso.returncode} "
                f"antes de crear {ruta}."
            )
        probe = compose("test", "-f", ruta)
        if probe.returncode == 0:
            return
        time.sleep(0.25)
    raise TimeoutError(f"No aparecio {ruta} en {segundos:.0f} s.")


def main() -> int:
    EVIDENCIA.mkdir(exist_ok=True)
    user = usuario()
    compose("rm", "-f", "/tmp/a_lista.txt", "/tmp/a_commit.txt")

    log_a = EVIDENCIA / "visibilidad_a.txt"
    handle = log_a.open("w", encoding="utf-8", newline="\n")
    sesion_a = subprocess.Popen(
        [
            "docker",
            "compose",
            "exec",
            "-T",
            "db",
            "psql",
            "-U",
            user,
            "-d",
            "chinook_serial",
            "-v",
            "modo_visibilidad=1",
            "-v",
            f"marca={MARCA}",
            "-P",
            "pager=off",
            "-f",
            "/sql/01_venta_exitosa.sql",
        ],
        cwd=ROOT,
        stdout=handle,
        stderr=subprocess.STDOUT,
        text=True,
        encoding="utf-8",
        errors="replace",
    )

    try:
        esperar_archivo("/tmp/a_lista.txt", sesion_a, 30)
        antes = compose(
            "psql",
            "-U",
            user,
            "-d",
            "chinook_serial",
            "-v",
            "fase=antes",
            "-v",
            f"marca={MARCA}",
            "-P",
            "pager=off",
            "-f",
            "/sql/04_validaciones.sql",
            log=EVIDENCIA / "visibilidad_b_antes.txt",
        )
        if antes.returncode != 0:
            raise RuntimeError("La consulta de B antes del COMMIT fallo.")

        esperar_archivo("/tmp/a_commit.txt", sesion_a, 60)
        despues = compose(
            "psql",
            "-U",
            user,
            "-d",
            "chinook_serial",
            "-v",
            "fase=despues",
            "-v",
            f"marca={MARCA}",
            "-P",
            "pager=off",
            "-f",
            "/sql/04_validaciones.sql",
            log=EVIDENCIA / "visibilidad_b_despues.txt",
        )
        if despues.returncode != 0:
            raise RuntimeError("La consulta de B despues del COMMIT fallo.")
    finally:
        codigo = sesion_a.wait(timeout=90)
        handle.close()

    if codigo != 0:
        print(log_a.read_text(encoding="utf-8"))
        raise RuntimeError(f"La sesion A termino con codigo {codigo}.")

    print(f"Visibilidad registrada para la marca {MARCA}.")
    print(f"Sesion A: {log_a}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(exc, file=sys.stderr)
        raise SystemExit(1)
