"""The placeholder check must accept valid encoders but reject changed pixels."""
import importlib.util
from pathlib import Path
import struct
import unittest
import zlib

SPEC = importlib.util.spec_from_file_location('placeholders', Path(__file__).with_name('generate-provider-placeholders.py'))
PLACEHOLDERS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PLACEHOLDERS)


def reencode(image, raw, level):
    data = zlib.compress(raw, level)
    chunk = struct.pack('!I', len(data)) + b'IDAT' + data + struct.pack('!I', zlib.crc32(b'IDAT' + data) & 0xffffffff)
    return image[:33] + chunk + image[-12:]


class PlaceholderTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.image = PLACEHOLDERS.png('WB')
        cls.raw = PLACEHOLDERS.pixels(cls.image)

    def test_equivalent_pixels_with_different_compression(self):
        for level in (0, 1, 6, 9):
            with self.subTest(level=level):
                self.assertEqual(PLACEHOLDERS.pixels(reencode(self.image, self.raw, level)), self.raw)

    def test_changed_pixels_do_not_match(self):
        raw = bytearray(self.raw)
        raw[4] ^= 1
        self.assertNotEqual(PLACEHOLDERS.pixels(reencode(self.image, raw, 9)), self.raw)

    def test_corrupt_and_truncated_files_are_rejected(self):
        corrupt = bytearray(self.image)
        corrupt[42] ^= 1
        for image in (bytes(corrupt), self.image[:-1], self.image + b'garbage'):
            with self.subTest(length=len(image)):
                with self.assertRaises(ValueError):
                    PLACEHOLDERS.pixels(image)


if __name__ == '__main__':
    unittest.main()
