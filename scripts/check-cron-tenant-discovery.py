#!/usr/bin/env python3
"""SKIRM-188 C3 — los CronJobs de despliegue descubren las empresas activas.

Lint sin dependencias (no PyYAML: el runner de CI no lo tiene): extrae el
Python embebido de cada ConfigMap `data: *.py: |` por indentación, lo compila
(py_compile) y comprueba el patrón de descubrimiento de
k8s/reconcile-sweep-cron.yaml:48-57 elevado con SET LOCAL
app.is_platform_admin (la RLS de 0045 devuelve 0 filas sin elevacion, medido
en prod 17-10) y fail-open al listado `tenants:` del config.
"""
import pathlib
import py_compile
import re
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent / "k8s"

# fichero -> (nombre del script embebido esperado, comprobaciones extra)
FILES = {
    "classifier-sweep-cron.yaml": None,
    "deh-poll-cron.yaml": None,
    "accounting-sweep-cron.yaml": None,
    "banking-daily-sync-cron.yaml": None,
    "tax-modelo-sweep-cron.yaml": None,
    "sii-import-recibidas-cron.yaml": None,
    "facturas-cron.yaml": None,
    "reconcile-sweep-cron.yaml": None,  # referencia: no se toca, debe seguir compilando
}

ELEVATION = "app.is_platform_admin"
ACTIVE_FILTER = "status='active'"
FAILOPEN = 'cfg.get("tenants")'

failures = []


def extract_embedded(text):
    """Devuelve [(nombre, codigo)] de los block scalars `data: x.py: |`."""
    out = []
    lines = text.splitlines()
    i = 0
    while i < len(lines):
        m = re.match(r"^  (\S+\.py): \|\s*$", lines[i])
        if m:
            name, body, i = m.group(1), [], i + 1
            while i < len(lines) and (lines[i].startswith("    ") or not lines[i].strip()):
                body.append(lines[i][4:] if lines[i].startswith("    ") else "")
                i += 1
            out.append((name, "\n".join(body)))
        else:
            i += 1
    return out


def check_file(fname):
    path = ROOT / fname
    if not path.exists():
        failures.append(f"{fname}: no existe")
        return
    text = path.read_text()
    scripts = extract_embedded(text)
    if not scripts:
        failures.append(f"{fname}: sin Python embebido (¿cambió el formato del ConfigMap?)")
        return
    allcode = "\n".join(code for _, code in scripts)
    for name, code in scripts:
        with tempfile.NamedTemporaryFile(suffix=".py", mode="w", delete=False) as f:
            f.write(code)
            tmp = f.name
        try:
            py_compile.compile(tmp, doraise=True)
        except py_compile.PyCompileError as e:
            failures.append(f"{fname}/{name}: NO compila: {e}")
    # patron de descubrimiento: elevado + activo + fail-open (en ficheros con BD)
    if fname != "reconcile-sweep-cron.yaml":
        if ELEVATION not in allcode:
            failures.append(f"{fname}: falta la elevacion RLS ({ELEVATION}) del descubrimiento")
        if ACTIVE_FILTER not in allcode:
            failures.append(f"{fname}: el descubrimiento no filtra {ACTIVE_FILTER}")
        if FAILOPEN not in allcode:
            failures.append(f"{fname}: no cae al listado `tenants:` del config (fail-open)")
    # comprobaciones por fichero
    if fname == "classifier-sweep-cron.yaml":
        if re.search(r'==\s*"skirmshop"', allcode):
            failures.append("classifier-sweep-cron.yaml: sigue el filtro == \"skirmshop\"")
    if fname == "deh-poll-cron.yaml":
        if 'notifications.{t}.deh.poll' not in allcode:
            failures.append("deh-poll-cron.yaml: no publica por empresa (notifications.<t>.deh.poll)")
    if fname == "accounting-sweep-cron.yaml":
        if "shopify_sii" not in allcode or "modules" not in allcode:
            failures.append("accounting-sweep-cron.yaml: la fase SII no filtra por modulo shopify_sii")
    if fname == "facturas-cron.yaml":
        # el wrapper por-empresa vive en el script embebido del ConfigMap
        if "FACTURAS_TENANT" not in text or "FACTURAS_TENANTS_EXCLUDE" not in text:
            failures.append("facturas-cron.yaml: no itera por empresa descubierta (wrapper FACTURAS_TENANT)")


def main():
    for fname in FILES:
        check_file(fname)
    if failures:
        print("FAIL:")
        for f in failures:
            print("  -", f)
        return 1
    print("PASS: los CronJobs descubren las empresas activas (elevado + status=active + fail-open)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
