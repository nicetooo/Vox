"""Generate Vox app icon — 3-bar waveform on dark gradient background."""
from PIL import Image, ImageDraw
import os, subprocess

SIZE = 1024
PAD = 120  # padding inside rounded rect

def rounded_rect(draw, rect, radius, fill):
    """Draw a rounded rectangle."""
    x0, y0, x1, y1 = rect
    draw.rounded_rectangle(rect, radius=radius, fill=fill)

def draw_bar(draw, cx, cy, width, height, fill, radius=None):
    """Draw a vertical rounded bar centered at (cx, cy)."""
    if radius is None:
        radius = width / 2
    x0 = cx - width / 2
    y0 = cy - height / 2
    x1 = cx + width / 2
    y1 = cy + height / 2
    draw.rounded_rectangle([x0, y0, x1, y1], radius=radius, fill=fill)

def create_icon(size=SIZE):
    img = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    # Background: dark rounded square with subtle gradient feel
    # macOS icon shape: rounded rect with ~22% corner radius
    corner_r = int(size * 0.22)

    # Draw gradient background (dark blue-gray to slightly lighter)
    # Use layered rounded rects for gradient effect
    for i in range(size):
        t = i / size
        # Dark gradient: top darker, bottom slightly lighter
        r = int(25 + t * 15)
        g = int(25 + t * 12)
        b = int(35 + t * 20)
        y = i
        draw.line([(0, y), (size, y)], fill=(r, g, b, 255))

    # Apply rounded rect mask
    mask = Image.new('L', (size, size), 0)
    mask_draw = ImageDraw.Draw(mask)
    mask_draw.rounded_rectangle([0, 0, size, size], radius=corner_r, fill=255)
    img.putalpha(mask)

    # Redraw on the masked image
    draw = ImageDraw.Draw(img)

    # Draw 3 waveform bars — white with slight transparency
    cx = size / 2
    cy = size / 2 + 10  # slightly below center for visual balance
    bar_width = int(size * 0.11)
    spacing = int(size * 0.17)
    bar_color = (255, 255, 255, 230)

    # Heights: left=medium, center=tall, right=medium-short
    bar_heights = [
        int(size * 0.28),   # left bar
        int(size * 0.52),   # center bar (tallest)
        int(size * 0.38),   # right bar
    ]

    for i, h in enumerate(bar_heights):
        bx = cx + (i - 1) * spacing
        draw_bar(draw, bx, cy, bar_width, h, bar_color)

    return img

def save_iconset(img, out_dir):
    """Save all required sizes for macOS .iconset."""
    iconset_dir = os.path.join(out_dir, 'Vox.iconset')
    os.makedirs(iconset_dir, exist_ok=True)

    sizes = [
        ('icon_16x16.png', 16),
        ('icon_16x16@2x.png', 32),
        ('icon_32x32.png', 32),
        ('icon_32x32@2x.png', 64),
        ('icon_128x128.png', 128),
        ('icon_128x128@2x.png', 256),
        ('icon_256x256.png', 256),
        ('icon_256x256@2x.png', 512),
        ('icon_512x512.png', 512),
        ('icon_512x512@2x.png', 1024),
    ]

    for name, sz in sizes:
        resized = img.resize((sz, sz), Image.LANCZOS)
        resized.save(os.path.join(iconset_dir, name))

    return iconset_dir

if __name__ == '__main__':
    out_dir = os.path.dirname(os.path.abspath(__file__))
    print("Generating icon...")
    img = create_icon()

    # Save full-size preview
    img.save(os.path.join(out_dir, 'icon_preview.png'))
    print(f"Preview saved: {out_dir}/icon_preview.png")

    # Save iconset and convert to .icns
    iconset_dir = save_iconset(img, out_dir)
    icns_path = os.path.join(out_dir, 'Vox.icns')
    subprocess.run(['iconutil', '-c', 'icns', iconset_dir, '-o', icns_path], check=True)
    print(f"Icon created: {icns_path}")
