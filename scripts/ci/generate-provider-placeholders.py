#!/usr/bin/env python3
"""Draw original, font-free provider letter placeholders using only the stdlib.

These are generic labels, not official logos. Copyright 2026 Ammo contributors;
distributed under this project's Apache-2.0 license. No downloaded geometry,
font, provider logo, or third-party image participates in generation.
"""
import argparse
from pathlib import Path
import struct
import zlib

ROOT = Path(__file__).resolve().parents[2]
OUTPUT = ROOT / 'packages/QuotaDesign/Sources/QuotaDesign/Resources/ProviderMarks'
LABELS = {'workbuddy': 'WB', 'zcode': 'ZC', 'fal': 'F',
          'cloudflare': 'CF', 'vercel': 'V', 'replit': 'R'}
# Hand-authored generic uppercase strokes in a 4 by 6 coordinate grid.
STROKES = {
    'W': [[(0, 0), (0.8, 6), (2, 3.5), (3.2, 6), (4, 0)]],
    'B': [[(0, 0), (0, 6)], [(0, 0), (3, 0), (4, 1), (4, 2), (3, 3), (0, 3)],
          [(3, 3), (4, 4), (4, 5), (3, 6), (0, 6)]],
    'Z': [[(0, 0), (4, 0), (0, 6), (4, 6)]],
    'C': [[(4, 0.5), (3, 0), (1, 0), (0, 1), (0, 5), (1, 6), (3, 6), (4, 5.5)]],
    'F': [[(0, 6), (0, 0), (4, 0)], [(0, 3), (3, 3)]],
    'V': [[(0, 0), (2, 6), (4, 0)]],
    'R': [[(0, 6), (0, 0), (3, 0), (4, 1), (4, 2), (3, 3), (0, 3)],
          [(2, 3), (4, 6)]],
}


def png(label):
    size, sample = 192, 4
    edge = size * sample
    coverage = bytearray(edge * edge)
    unit = 16 if len(label) == 2 else 22
    gap = 1.25 * unit
    width = len(label) * 4 * unit + (len(label) - 1) * gap
    start_x, start_y = (size - width) / 2, (size - 6 * unit) / 2
    radius = (5 if len(label) == 2 else 6) * sample
    for index, letter in enumerate(label):
        for stroke in STROKES[letter]:
            points = [((start_x + index * (4 * unit + gap) + x * unit) * sample,
                       (start_y + y * unit) * sample) for x, y in stroke]
            for (ax, ay), (bx, by) in zip(points, points[1:]):
                dx, dy = bx - ax, by - ay
                length = dx * dx + dy * dy
                for y in range(max(0, int(min(ay, by) - radius)), min(edge, int(max(ay, by) + radius) + 1)):
                    for x in range(max(0, int(min(ax, bx) - radius)), min(edge, int(max(ax, bx) + radius) + 1)):
                        t = max(0, min(1, ((x + .5 - ax) * dx + (y + .5 - ay) * dy) / length))
                        if (x + .5 - ax - t * dx) ** 2 + (y + .5 - ay - t * dy) ** 2 <= radius ** 2:
                            coverage[y * edge + x] = 1
    raw = bytearray()
    for y in range(size):
        raw.append(0)  # PNG scanline filter: none
        for x in range(size):
            count = sum(coverage[(y * sample + sy) * edge + x * sample + sx]
                        for sy in range(sample) for sx in range(sample))
            raw.extend((255, 255, 255, round(255 * count / sample ** 2)))

    def chunk(kind, data):
        return struct.pack('!I', len(data)) + kind + data + struct.pack('!I', zlib.crc32(kind + data) & 0xffffffff)
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('!2I5B', size, size, 8, 6, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b''))


def pixels(image):
    """Validate our simple PNG format, independently of the zlib encoder version."""
    if not image.startswith(b'\x89PNG\r\n\x1a\n'):
        raise ValueError('Invalid PNG signature')
    offset, kinds, payloads = 8, [], []
    while offset < len(image):
        if len(image) - offset < 12:
            raise ValueError('Truncated PNG chunk')
        length = struct.unpack('!I', image[offset:offset + 4])[0]
        end = offset + 12 + length
        if end > len(image):
            raise ValueError('Truncated PNG payload')
        kind = image[offset + 4:offset + 8]
        data = image[offset + 8:offset + 8 + length]
        crc = struct.unpack('!I', image[end - 4:end])[0]
        if crc != zlib.crc32(kind + data) & 0xffffffff:
            raise ValueError('Invalid PNG checksum')
        kinds.append(kind)
        payloads.append(data)
        offset = end
    if kinds != [b'IHDR', b'IDAT', b'IEND'] or payloads[2]:
        raise ValueError('Unexpected PNG structure')
    if payloads[0] != struct.pack('!2I5B', 192, 192, 8, 6, 0, 0, 0):
        raise ValueError('Expected a transparent 192px RGBA image')
    decoder = zlib.decompressobj()
    raw = decoder.decompress(payloads[1]) + decoder.flush()
    if not decoder.eof or decoder.unused_data or decoder.unconsumed_tail:
        raise ValueError('Invalid PNG image stream')
    if len(raw) != 192 * (1 + 192 * 4) or any(raw[y * (1 + 192 * 4)] != 0 for y in range(192)):
        raise ValueError('Unexpected PNG scanlines')
    return raw


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='Validate committed images without rewriting them')
    args = parser.parse_args()
    for name, label in LABELS.items():
        path = OUTPUT / ('ProviderIcon-' + name + '.png')
        image = png(label)
        if args.check:
            if not path.is_file() or pixels(path.read_bytes()) != pixels(image):
                raise SystemExit('Placeholder differs from original generator: ' + name)
        else:
            path.write_bytes(image)
    print(('Verified' if args.check else 'Generated') + ' six original transparent 192px letter placeholders.')


if __name__ == '__main__':
    main()
