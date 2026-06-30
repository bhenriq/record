#!/usr/bin/env python3
"""Generate AppIcon.icns for Rec.app — a red recording dot.

Run:  python3 Scripts/generate-app-icon.py
Output: Sources/RecMenu/Resources/AppIcon.icns
"""
import struct, zlib, os, sys, math, subprocess

def create_png(width, height, draw_fn):
    def make_chunk(chunk_type, data):
        c = chunk_type + data
        crc = struct.pack('>I', zlib.crc32(c) & 0xffffffff)
        return struct.pack('>I', len(data)) + c + crc

    header = struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0)
    ihdr = make_chunk(b'IHDR', header)

    raw = bytearray()
    for y in range(height):
        raw.append(0)
        for x in range(width):
            r, g, b = draw_fn(x, y, width, height)
            raw.extend([r, g, b])

    deflate = zlib.compress(bytes(raw))
    idat = make_chunk(b'IDAT', deflate)
    iend = make_chunk(b'IEND', b'')
    return b'\x89PNG\r\n\x1a\n' + ihdr + idat + iend

def draw_icon(x, y, w, h):
    cx, cy = w / 2, h / 2
    outer_r = w * 0.44
    inner_r = w * 0.12

    dx, dy = x - cx, y - cy
    dist = math.sqrt(dx*dx + dy*dy)

    if dist > outer_r:
        return (248, 248, 248)  # near-white background

    if dist < inner_r:
        return (230, 50, 50)  # solid bright center

    t = (dist - inner_r) / (outer_r - inner_r)
    t = max(0, min(1, t))
    edge_shadow = max(0, (t - 0.85) / 0.15) * 0.3 if t > 0.85 else 0.0

    angle = math.atan2(dy, dx)
    hx = cx + outer_r * 0.3 * math.cos(angle - 0.5)
    hy = cy + outer_r * 0.3 * math.sin(angle - 0.5)
    hdist = math.sqrt((x - hx)**2 + (y - hy)**2)
    highlight = max(0, 1 - hdist / (outer_r * 0.5))

    r = int(200 * (1 - t) + 50 * t - edge_shadow * 200 + highlight * 40)
    g = int(30 * (1 - t) + 10 * t - edge_shadow * 100 + highlight * 20)
    b = int(30 * (1 - t) + 10 * t - edge_shadow * 100 + highlight * 20)
    return (max(0, min(255, r)), max(0, min(255, g)), max(0, min(255, b)))

def main():
    project_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    iconset_dir = os.path.join(project_dir, '.build', 'AppIcon.iconset')
    output_path = os.path.join(project_dir, 'Sources', 'RecMenu', 'Resources', 'AppIcon.icns')

    os.makedirs(iconset_dir, exist_ok=True)

    for s in [16, 32, 64, 128, 256, 512, 1024]:
        png_data = create_png(s, s, draw_icon)
        with open(os.path.join(iconset_dir, f'icon_{s}x{s}.png'), 'wb') as f:
            f.write(png_data)

    # Create @2x copies for the iconset
    for s, d in [(16, 32), (32, 64), (128, 256), (256, 512), (512, 1024)]:
        src = os.path.join(iconset_dir, f'icon_{d}x{d}.png')
        dst = os.path.join(iconset_dir, f'icon_{s}x{s}@2x.png')
        if os.path.exists(src):
            os.symlink(src, dst) if sys.platform != 'win32' else None

    # Also copy explicit files for sizes that don't have @2x counterparts
    import shutil
    shutil.copy(
        os.path.join(iconset_dir, 'icon_16x16.png'),
        os.path.join(iconset_dir, 'icon_16x16.png'),
    )

    subprocess.run(['iconutil', '-c', 'icns', '-o', output_path, iconset_dir], check=True)
    print(f"Created {output_path} ({os.path.getsize(output_path) // 1024} KB)")

if __name__ == '__main__':
    main()
