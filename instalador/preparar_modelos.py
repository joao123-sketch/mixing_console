"""Baixa de uma vez os modelos de IA, para a primeira música não ficar esperando o download.

Rodado pelo instalador, de dentro da pasta instalada:  python\\python.exe instalador\\preparar_modelos.py
"""

import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import server  # noqa: E402

print("\n  -> Modelo de separação principal (Demucs htdemucs_6s, ~55 MB)\n")
server.get_model()
print("\n  -> Modelo de sopros (UVR 17_HP-Wind_Inst, ~225 MB)\n")
with tempfile.TemporaryDirectory() as tmp:
    server.get_winds_model(Path(tmp))
print("\n  Modelos prontos.")
