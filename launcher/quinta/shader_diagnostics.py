"""Extract UI gradient shaders locally for driver/compiler investigation."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import struct


def gradient_sources(data):
    if len(data) < 20:
        raise ValueError("Truncated shader pack")
    magic, version, variants, defines, options, names, shaders, _ = struct.unpack_from(
        "<4s6HI", data)
    if magic != b"RBXS" or version != 11 or not variants or not names or not shaders:
        raise ValueError("Expected an RBXS version 11 shader pack")
    names_start = 20 + variants * 64
    table = names_start + names * 68 + defines * 64 + options * 65
    sources_start = table + shaders * 64
    if sources_start >= len(data):
        raise ValueError("Truncated descriptor tables")
    found = []
    seen = set()
    for index in range(shaders):
        entry = table + index * 64
        offset, size = struct.unpack_from("<II", data, entry + 16)
        kind, variant, name_index = struct.unpack_from("<BBH", data, entry + 28)
        if (kind not in b"vpc" or variant >= variants or name_index >= names
                or not 0 < size <= 1024 * 1024 or offset < sources_start
                or offset + size > len(data)):
            raise ValueError(f"Invalid shader descriptor {index}")
        source = data[offset:offset + size]
        if b"uniform sampler2D GradientAtlasTexture;" not in source:
            continue
        if (offset, size) in seen:
            continue
        seen.add((offset, size))
        start = names_start + name_index * 68
        name = data[start:start + 64].split(b"\0", 1)[0].decode("ascii", "replace")
        name = re.sub(r"[^A-Za-z0-9_-]", "_", name) or "unnamed"
        found.append((index, name, source))
    return found


def dump(pack, destination):
    pack, destination = Path(pack), Path(destination)
    if pack.stat().st_size > 64 * 1024 * 1024:
        raise ValueError("Shader pack exceeds 64 MiB diagnostic limit")
    data = pack.read_bytes()
    sources = gradient_sources(data)  # Validate completely before writing.
    if not sources:
        raise ValueError("No gradient-atlas shaders found")
    # Never overwrite an earlier capture or a user-supplied directory.
    destination.mkdir(parents=True, exist_ok=False)
    entries = []
    for index, name, source in sources:
        filename = f"{index:04d}-{name}.frag"
        (destination / filename).write_bytes(source)
        entries.append({"descriptor": index, "name": name, "file": filename,
                        "sha256": hashlib.sha256(source).hexdigest()})
    manifest = {"pack_sha256": hashlib.sha256(data).hexdigest(), "shaders": entries}
    (destination / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    return len(entries)


def main(arguments=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", type=Path, help="New directory for local shader capture")
    parser.add_argument("--pack", type=Path, help="Override the installed GLSL pack")
    args = parser.parse_args(arguments)
    pack = args.pack
    if pack is None:
        from .core import APP_BUNDLE
        pack = APP_BUNDLE / "Contents/Resources/shaders/shaders_glsl3.pack"
    try:
        count = dump(pack, args.destination)
    except (OSError, ValueError) as error:
        parser.exit(1, f"Could not capture gradient shaders: {error}\n")
    print(f"Captured {count} gradient shaders and manifest in {args.destination}")
    return 0
