#!/usr/bin/env python3
"""Materializa BIOGRID MVP sobre Mi Mapa del Tiempo 1.0.43, de forma idempotente."""
from pathlib import Path
import base64, gzip, hashlib

root = Path(__file__).resolve().parents[1]
sources = root / "Sources"
tools = root / "tools"
expected = {
    "BioGridEngine.swift": "708348e527f9ce3f8893b840c67ecdda10c22b73f1c15241ee79a7b45a890004",
    "BioGridView.swift": "6255de6c4578b589286ac80d51098f5af41321a4b6cfd74b8e55bed6ce42df63",
}
for file, sha in expected.items():
    key = "biogrid_engine_v1.gz.b64" if file == "BioGridEngine.swift" else "biogrid_view_v1.gz.b64"
    data = gzip.decompress(base64.b64decode((tools / key).read_text().strip()))
    assert hashlib.sha256(data).hexdigest() == sha, "Carga de codigo BIOGRID alterada"
    (sources / file).write_bytes(data)

discover = sources / "TimeDiscoveryViews.swift"
s = discover.read_text()
anchor = "                Section {\n                    NavigationLink {\n                        TimeWhereWasIView(model:model)"
addition = """                Section {
                    NavigationLink {
                        BioGridView(model:model)
                    } label: {
                        Label {
                            VStack(alignment:.leading,spacing:4) {
                                Text("BIOGRID").font(.headline)
                                Text("Siete familias de bacterias; colonización a partir de tu tiempo GPS.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: { Image(systemName:"circle.hexagongrid.fill").foregroundStyle(.teal) }
                    }
                } header: {
                    Text("BIOGRID")
                }
"""
if "BioGridView(model:model)" not in s:
    assert anchor in s, "No se encuentra la pantalla Descubrir que debia ampliarse"
    discover.write_text(s.replace(anchor, addition + anchor, 1))

project = root / "project.yml"
spec = project.read_text()
if 'CFBundleShortVersionString: "1.0.43"' in spec:
    spec = spec.replace('CFBundleShortVersionString: "1.0.43"', 'CFBundleShortVersionString: "1.0.44"')
    spec = spec.replace('CFBundleVersion: "44"', 'CFBundleVersion: "45"')
    project.write_text(spec)
assert spec.count('CFBundleShortVersionString: "1.0.44"') == 2
assert spec.count('CFBundleVersion: "45"') == 2
print("BIOGRID 1.0.44: motor y pantalla integrados en Descubrir; identificadores originales intactos")
