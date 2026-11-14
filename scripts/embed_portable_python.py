#!/usr/bin/env python3
"""Copy the prepared Python runtime into a temporary product and seal its code."""
from pathlib import Path
import hashlib
import json
import shutil
import subprocess
import sys


def embed(source: Path, target: Path) -> None:
    project = Path(__file__).resolve().parents[1]
    products = project / "Products.noindex"
    source = source.resolve(strict=True)
    expected_source = (project / "Dependencies.noindex/client-python").resolve(strict=True)
    if source != expected_source or not source.is_dir():
        raise ValueError("Only the prepared project Python runtime can be embedded")
    if target.name != "Python" or target.parent.name != "Resources" or target.parent.parent.name != "Contents":
        raise ValueError("Invalid product resource destination")
    if not target.parent.resolve(strict=True).is_relative_to(products.resolve(strict=True)):
        raise ValueError("Python may only be embedded in a temporary product")
    if target.is_symlink():
        raise ValueError("Refusing a symlink product destination")
    for path in source.rglob("*"):
        if path.is_symlink() and not path.resolve(strict=True).is_relative_to(source):
            raise ValueError("Runtime symlink leaves its package")
    if target.exists():
        # This is the exact generated resource in Products.noindex, never an
        # installation, application backup, user profile or interpreter cache.
        shutil.rmtree(target)
    shutil.copytree(source, target, symlinks=True)
    macho = {bytes.fromhex(value) for value in (
        "feedface", "cefaedfe", "feedfacf", "cffaedfe",
        "cafebabe", "bebafeca", "cafebabf", "bfbafeca",
    )}
    signed = []
    for path in sorted(target.rglob("*")):
        if path.is_symlink() or not path.is_file():
            continue
        with path.open("rb") as stream:
            header = stream.read(4)
        if header in macho:
            subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none", str(path)], check=True)
            signed.append(str(path.relative_to(target)))
    hashes = {
        str(path.relative_to(target)): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in target.rglob("*") if path.is_file() and not path.is_symlink()
    }
    (target / "playmelt-embedded-code.json").write_text(json.dumps({
        "schema": 1, "signedMachO": signed, "sha256": hashes,
        "signing": "ad-hoc integrity; no Developer ID or notarization claim",
    }, sort_keys=True) + "\n")
    print(f"Embedded portable Python: {len(hashes)} files, {len(signed)} sealed Mach-O files")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("Usage: embed_portable_python.py SOURCE PRODUCT/Contents/Resources/Python")
    embed(Path(sys.argv[1]), Path(sys.argv[2]))
