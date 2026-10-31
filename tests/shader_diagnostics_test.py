import json
from pathlib import Path
import struct
import tempfile
import unittest

from quadra.shader_diagnostics import dump, gradient_sources


def fixture(name=b"UIFS", source=b"uniform sampler2D GradientAtlasTexture;\nvoid main(){}"):
    header = struct.pack("<4s6HI", b"RBXS", 11, 1, 0, 0, 1, 2, 0)
    prefix = header + b"default".ljust(64, b"\0") + name.ljust(68, b"\0")
    start = len(prefix) + 2 * 64
    entry = bytes(16) + struct.pack("<IIIBBH", start, len(source), 0, ord('p'), 0, 0) + bytes(32)
    return prefix + entry * 2 + source


class ShaderDiagnosticsTests(unittest.TestCase):
    def test_shared_sources_are_deduplicated(self):
        found = gradient_sources(fixture())
        self.assertEqual(len(found), 1)
        self.assertEqual(found[0][:2], (0, 'UIFS'))

    def test_truncated_descriptor_or_source_is_rejected(self):
        for data in (b"RBXS", fixture()[:150], fixture()[:-1]):
            with self.assertRaises(ValueError):
                gradient_sources(data)

    def test_unrelated_sources_are_not_selected(self):
        self.assertEqual(gradient_sources(fixture(source=b"void main(){}")), [])

    def test_names_cannot_escape_capture_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            pack = root / 'test.pack'
            pack.write_bytes(fixture(name=b'../../outside'))
            output = root / 'capture'
            self.assertEqual(dump(pack, output), 1)
            manifest = json.loads((output / 'manifest.json').read_text())
            filename = manifest['shaders'][0]['file']
            self.assertEqual(Path(filename).name, filename)
            self.assertTrue((output / filename).is_file())
            with self.assertRaises(FileExistsError):
                dump(pack, output)


if __name__ == '__main__':
    unittest.main()
