"""Writes ../manifest.csv: every PNG with its pixel size and SHA-256."""
import hashlib, struct
from pathlib import Path
d = Path(__file__).resolve().parent.parent
rows = ["file,width,height,sha256"]
for f in sorted(d.glob("*.png")):
    b = f.read_bytes(); w, h = struct.unpack(">II", b[16:24])
    rows.append(f"{f.name},{w},{h},{hashlib.sha256(b).hexdigest()}")
(d / "manifest.csv").write_text("\n".join(rows) + "\n")
print(len(rows) - 1, "images")
