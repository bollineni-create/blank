import math, sys
from PIL import Image, ImageDraw, ImageFilter, ImageChops

S = 4096  # supersampled canvas
out_dir = sys.argv[1]

PAPER = (250, 248, 245)
CORAL, VIOLET, ORANGE = (232, 79, 97), (140, 97, 242), (250, 115, 74)

# Letter shapes are drawn on a 2048 grid: baseline and x-height.
B, T = 1180, 870

def arc(cx, cy, rx, ry, a0, a1, n=80):
    return [(cx + rx * math.cos(math.radians(a0 + (a1 - a0) * i / n)), cy + ry * math.sin(math.radians(a0 + (a1 - a0) * i / n))) for i in range(n + 1)]

def o(cx):
    # Enter at the top heading right, go round clockwise and come back out over the top.
    return arc(cx, (B + T) / 2, 118, (B - T) / 2, -100, 250, 140)

def word():
    # Cursive "loom" as one continuous stroke.
    p = [(150, 1200), (240, 1150), (340, 1000), (420, 800), (450, 640), (430, 545), (385, 525), (350, 560),
         (340, 680), (345, 900), (360, 1100), (400, 1185), (470, 1190), (540, 1090), (600, 930)]
    p += o(690)
    p += [(770, 900), (850, 870), (900, 880)]
    p += o(1000)
    p += [(1080, 900), (1150, 880), (1190, 930), (1196, 1060), (1192, B - 30), (1205, B)]
    # m: each stem dips to the baseline in a narrow V rather than reversing on the spot,
    # so the braid turns instead of pinching into a blunt end.
    for m0 in (1210, 1420):
        p += arc(m0 + 105, T + 110, 105, 120, 180, 360, 50)[1:] + [(m0 + 210, B - 90), (m0 + 214, B - 10), (m0 + 230, B)]
    p += [(1700, 1195), (1780, 1160), (1850, 1090)]
    return p

def ell():
    # Just the looped "l", for the small Mac sizes where the whole word would be a squiggle.
    return [(150, 1200), (240, 1150), (340, 1000), (420, 800), (450, 640), (430, 545), (385, 525), (350, 560),
            (340, 680), (345, 900), (360, 1100), (400, 1185), (470, 1190), (540, 1120), (590, 1040)]

def smooth(p, it=5):
    for _ in range(it):
        q = [p[0]]
        for a, b in zip(p, p[1:]):
            q += [(0.75 * a[0] + 0.25 * b[0], 0.75 * a[1] + 0.25 * b[1]), (0.25 * a[0] + 0.75 * b[0], 0.25 * a[1] + 0.75 * b[1])]
        q.append(p[-1]); p = q
    return p

def resample(p, step):
    out, carry = [p[0]], 0.0
    for a, b in zip(p, p[1:]):
        d = math.dist(a, b); t = step - carry
        while t <= d:
            out.append((a[0] + (b[0] - a[0]) * t / d, a[1] + (b[1] - a[1]) * t / d)); t += step
        carry = d - (t - step)
    return out

def fit(p, w, h):
    # Scale the stroke to fit a w x h box centred on the canvas; returns the path and the scale used.
    xs, ys = [q[0] for q in p], [q[1] for q in p]
    f = min(w / (max(xs) - min(xs)), h / (max(ys) - min(ys)))
    cx, cy = (min(xs) + max(xs)) / 2, (min(ys) + max(ys)) / 2
    return [(1024 + (x - cx) * f, 1024 + (y - cy) * f) for x, y in p], f

def braid(path, f, bold=1.0):
    # Three strands plaited along the path. Each strand weaves side to side; the depth
    # value decides which strand is on top where they cross, and a gap is cut around
    # whichever is on top so the ones underneath read as passing beneath.
    k = S / 2048
    step = 2.0
    path = resample(smooth(path), step)
    amp, w, gap, period = 24 * f, 24 * f * bold, 7 * f, 120 * f
    segs = []
    for si, col in enumerate([CORAL, VIOLET, ORANGE]):
        ph = 2 * math.pi * si / 3
        pts = []
        for i, (x, y) in enumerate(path):
            a, b = path[max(0, i - 1)], path[min(len(path) - 1, i + 1)]
            tx, ty = b[0] - a[0], b[1] - a[1]; L = math.hypot(tx, ty) or 1
            nx, ny = -ty / L, tx / L
            s = i * step; th = 2 * math.pi * s / period + ph
            off = amp * math.sin(th)
            pts.append(((x + nx * off) * k, (y + ny * off) * k, math.sin(2 * th) + 0.004 * s / f))
        segs += [((pts[j][0], pts[j][1]), (pts[j + 1][0], pts[j + 1][1]), (pts[j][2] + pts[j + 1][2]) / 2, col) for j in range(len(pts) - 1)]

    width, cut = w * k, gap * k
    layer = Image.new("RGBA", (S, S), (0, 0, 0, 0)); d = ImageDraw.Draw(layer)
    seglen = sum(math.dist(s[0], s[1]) for s in segs) / len(segs)
    reach = int((width + 2 * cut) / seglen) + 3
    drawn = [False] * len(segs)
    def stroke(i, wd, col):
        p0, p1, _, _ = segs[i]
        d.line([p0, p1], fill=col, width=int(wd))
        d.ellipse([p1[0] - wd / 2, p1[1] - wd / 2, p1[0] + wd / 2, p1[1] + wd / 2], fill=col)
    for i in sorted(range(len(segs)), key=lambda i: segs[i][2]):
        stroke(i, width + 2 * cut, (0, 0, 0, 0)); drawn[i] = True
        for j in range(max(0, i - reach), min(len(segs), i + reach + 1)):
            if drawn[j] and segs[j][3] == segs[i][3]: stroke(j, width, segs[j][3] + (255,))
    return layer

def artwork(path, f, bold=1.0):
    lay = braid(path, f, bold)
    k = S / 2048
    bg = Image.new("RGBA", (S, S), PAPER + (255,))
    sh = Image.new("RGBA", (S, S), (60, 20, 90, 0))
    sh.putalpha(ImageChops.offset(lay.getchannel("A"), 0, int(12 * k * f)).filter(ImageFilter.GaussianBlur(16 * k * f)).point(lambda v: int(v * 0.2)))
    return Image.alpha_composite(Image.alpha_composite(bg, sh), lay)

word_art = artwork(*fit(word(), 1640, 2048))
ell_art = artwork(*fit(ell(), 2048, 1560), bold=1.8)

# iOS: full-bleed square (the system rounds the corners).
ios = word_art.resize((1024, 1024), Image.LANCZOS).convert("RGB")
ios.save(f"{out_dir}/icon-ios-1024.png")

# macOS: rounded square on a transparent canvas with a soft shadow, per Apple's icon grid.
def mac_icon(art, px):
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

# The word turns into a squiggle below 128px, so the Finder/Dock sizes use the looped l.
for px in [16, 32, 64, 128, 256, 512, 1024]:
    mac_icon(word_art if px >= 128 else ell_art, px).save(f"{out_dir}/icon-mac-{px}.png")
print("done")
