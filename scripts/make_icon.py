import math, sys
from PIL import Image, ImageDraw, ImageFilter

S = 4096  # supersampled canvas
out_dir = sys.argv[1]

def lerp(a, b, t): return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))

def background(size):
    top, bottom = (240, 88, 92), (122, 82, 238)  # coral -> violet
    img = Image.new("RGB", (size, size))
    px = img.load()
    for y in range(size):
        for x in range(size):
            t = (x * 0.35 + y * 0.65) / size
            px[x, y] = lerp(top, bottom, min(1, max(0, t)))
    return img

def artwork(size):
    bg = background(256).resize((size, size), Image.BICUBIC).convert("RGBA")
    s = size / 4096

    # Soft light in the upper left.
    glow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    ImageDraw.Draw(glow).ellipse([int(-600*s), int(-700*s), int(2600*s), int(2300*s)], fill=(255, 255, 255, 60))
    bg = Image.alpha_composite(bg, glow.filter(ImageFilter.GaussianBlur(500 * s)))

    # Faint loom weave behind the web.
    weave = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(weave)
    for i in range(1, 12):
        p = int(i * size / 12)
        d.line([(p, 0), (p, size)], fill=(255, 255, 255, 22), width=int(14 * s))
        d.line([(0, p), (size, p)], fill=(255, 255, 255, 22), width=int(14 * s))
    bg = Image.alpha_composite(bg, weave)

    c = (2048, 2048)
    ring = []
    for k in range(7):
        a = -math.pi / 2 + k * 2 * math.pi / 7 + 0.15
        r = 1250 + (110 if k % 2 else -60)
        ring.append((c[0] + r * math.cos(a), c[1] + r * math.sin(a)))
    mids = []
    for k in range(7):
        a = -math.pi / 2 + (k + 0.5) * 2 * math.pi / 7 + 0.15
        r = 720
        mids.append((c[0] + r * math.cos(a), c[1] + r * math.sin(a)))

    edges = []
    for k in range(7):
        edges += [(c, ring[k]), (ring[k], ring[(k + 1) % 7]), (mids[k], ring[k]), (mids[k], ring[(k + 1) % 7]), (mids[k], mids[(k + 1) % 7])]

    def sp(p): return (p[0] * s, p[1] * s)

    # Glow under the threads, then the threads.
    lines = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    ld = ImageDraw.Draw(lines)
    for a, b in edges:
        ld.line([sp(a), sp(b)], fill=(255, 255, 255, 255), width=int(34 * s))
    shadow = lines.filter(ImageFilter.GaussianBlur(60 * s))
    shadow_tint = Image.new("RGBA", (size, size), (255, 255, 255, 0))
    shadow_tint.putalpha(shadow.getchannel("A").point(lambda v: int(v * 0.5)))
    bg = Image.alpha_composite(bg, shadow_tint)
    faint = Image.new("RGBA", (size, size), (255, 255, 255, 0))
    faint.putalpha(lines.getchannel("A").point(lambda v: int(v * 0.78)))
    bg = Image.alpha_composite(bg, faint)

    # Nodes.
    nodes = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    nd = ImageDraw.Draw(nodes)
    def dot(p, r, fill=(255, 255, 255, 255)):
        x, y = sp(p); r *= s
        nd.ellipse([x - r, y - r, x + r, y + r], fill=fill)
    for p in ring: dot(p, 150)
    for p in mids: dot(p, 95)
    dot(c, 400)
    node_glow = nodes.filter(ImageFilter.GaussianBlur(90 * s))
    ng = Image.new("RGBA", (size, size), (255, 255, 255, 0))
    ng.putalpha(node_glow.getchannel("A").point(lambda v: int(v * 0.6)))
    bg = Image.alpha_composite(bg, ng)
    bg = Image.alpha_composite(bg, nodes)

    # Coloured cores: the center and a few "concepts".
    cores = ImageDraw.Draw(bg)
    def core(p, r, col):
        x, y = sp(p); r *= s
        cores.ellipse([x - r, y - r, x + r, y + r], fill=col)
    core(c, 250, (232, 79, 97, 255))
    core(ring[0], 78, (122, 82, 238, 255))
    core(ring[2], 78, (247, 150, 60, 255))
    core(ring[4], 78, (60, 160, 240, 255))
    core(ring[6], 78, (40, 180, 125, 255))
    return bg

art = artwork(S)

# iOS: full-bleed square (the system rounds the corners).
ios = art.resize((1024, 1024), Image.LANCZOS).convert("RGB")
ios.save(f"{out_dir}/icon-ios-1024.png")

# macOS: rounded square on a transparent canvas with a soft shadow, per Apple's icon grid.
def mac_icon(px):
    canvas = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    body = int(S * 824 / 1024)
    off = (S - body) // 2
    radius = int(body * 0.2237)
    mask = Image.new("L", (body, body), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, body - 1, body - 1], radius=radius, fill=255)
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle([off, off + int(S * 0.012), off + body, off + body + int(S * 0.012)], radius=radius, fill=(0, 0, 0, 110))
    canvas = Image.alpha_composite(canvas, shadow.filter(ImageFilter.GaussianBlur(S * 0.012)))
    art_body = art.resize((body, body), Image.LANCZOS)
    canvas.paste(art_body, (off, off), mask)
    return canvas.resize((px, px), Image.LANCZOS)

for px in [16, 32, 64, 128, 256, 512, 1024]:
    mac_icon(px).save(f"{out_dir}/icon-mac-{px}.png")
print("done")
