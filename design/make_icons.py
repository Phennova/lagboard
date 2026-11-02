"""Generates LagBoard app icon concepts as 1024x1024 SVGs on the macOS icon grid."""
import math, random, os

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "icons")
CYAN, ORANGE, PINK = "#40D9FF", "#FF8C33", "#FA4D73"

def wrap(defs, body, bg):
    # 824x824 body at (100,100) with Big Sur-style corner radius and drop shadow
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
<defs>
  <filter id="shadow" x="-20%" y="-20%" width="140%" height="140%"><feDropShadow dx="0" dy="12" stdDeviation="14" flood-color="#000" flood-opacity="0.32"/></filter>
  <clipPath id="body"><rect x="100" y="100" width="824" height="824" rx="185"/></clipPath>
  <linearGradient id="sheen" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fff" stop-opacity="0.16"/><stop offset="0.45" stop-color="#fff" stop-opacity="0"/></linearGradient>
  {defs}
</defs>
<g filter="url(#shadow)"><rect x="100" y="100" width="824" height="824" rx="185" fill="{bg}"/></g>
<g clip-path="url(#body)">{body}
<rect x="100" y="100" width="824" height="824" fill="url(#sheen)"/></g>
<rect x="100.5" y="100.5" width="823" height="823" rx="185" fill="none" stroke="#fff" stroke-opacity="0.10"/>
</svg>'''

# ---------------------------------------------------------------- A: Signal Pads
def icon_pads():
    defs = '''<linearGradient id="bgA" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#22222c"/><stop offset="1" stop-color="#0c0c11"/></linearGradient>
    <filter id="glow" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="22"/></filter>'''
    size, gap = 196, 30
    start = 512 - (3 * size + 2 * gap) / 2
    out = []
    for r in range(3):
        for c in range(3):
            x, y = start + c * (size + gap), start + r * (size + gap)
            lit = r >= 2 - c
            if (r, c) == (0, 2):
                # the top bar is glitched: torn slices + RGB ghosting
                out.append(f'<rect x="{x}" y="{y}" width="{size}" height="{size}" rx="36" fill="{PINK}" opacity="0.35" filter="url(#glow)"/>')
                offs = [-22, 26, -6, 34, -14]
                h = size / len(offs)
                for i, o in enumerate(offs):
                    yy = y + i * h
                    out.append(f'<rect x="{x + o - 9}" y="{yy:.1f}" width="{size}" height="{h + 0.5:.1f}" fill="{CYAN}" opacity="0.8"/>')
                    out.append(f'<rect x="{x + o}" y="{yy:.1f}" width="{size}" height="{h + 0.5:.1f}" fill="{PINK}"/>')
                for bx, by, bs in [(x + size + 18, y + 40, 26), (x - 40, y + 120, 20), (x + size + 4, y + 150, 16)]:
                    out.append(f'<rect x="{bx}" y="{by}" width="{bs}" height="{bs}" fill="{PINK}" opacity="0.8"/>')
            elif lit:
                out.append(f'<rect x="{x}" y="{y}" width="{size}" height="{size}" rx="36" fill="{CYAN}" opacity="0.45" filter="url(#glow)"/>')
                out.append(f'<rect x="{x}" y="{y}" width="{size}" height="{size}" rx="36" fill="{CYAN}"/>')
                out.append(f'<rect x="{x + 18}" y="{y + 14}" width="{size - 36}" height="10" rx="5" fill="#fff" opacity="0.35"/>')
            else:
                out.append(f'<rect x="{x}" y="{y}" width="{size}" height="{size}" rx="36" fill="#2a2a35"/>')
                out.append(f'<rect x="{x + 1}" y="{y + 1}" width="{size - 2}" height="{size - 2}" rx="35" fill="none" stroke="#fff" stroke-opacity="0.07" stroke-width="2"/>')
    return wrap(defs, "\n".join(out), "url(#bgA)")

# ---------------------------------------------------------------- B: Glitched Wi-Fi
def wifi_symbol(color):
    cx, cy = 512, 700
    parts = [f'<circle cx="{cx}" cy="{cy}" r="52" fill="{color}"/>']
    for r in (150, 265, 380):
        d = r * math.sqrt(0.5)
        parts.append(f'<path d="M {cx - d:.1f} {cy - d:.1f} A {r} {r} 0 0 1 {cx + d:.1f} {cy - d:.1f}" fill="none" stroke="{color}" stroke-width="74" stroke-linecap="round"/>')
    return "".join(parts)

def icon_wifi():
    defs = f'''<radialGradient id="bgB" cx="0.25" cy="0.15" r="1.1"><stop offset="0" stop-color="#3a22a0"/><stop offset="0.55" stop-color="#160f45"/><stop offset="1" stop-color="#08081a"/></radialGradient>
    <g id="sym"><g transform="translate(-16 0)" opacity="0.9">{wifi_symbol(CYAN)}</g><g transform="translate(16 0)" opacity="0.9">{wifi_symbol(PINK)}</g>{wifi_symbol("#ffffff")}</g>'''
    bands = [(150, 330, 0), (330, 395, 34), (395, 470, -40), (470, 560, 0), (560, 615, 56), (615, 700, -22), (700, 900, 0)]
    out = []
    for i, (y0, y1, dx) in enumerate(bands):
        defs += f'<clipPath id="band{i}"><rect x="0" y="{y0}" width="1024" height="{y1 - y0}"/></clipPath>'
        out.append(f'<g clip-path="url(#band{i})"><use href="#sym" transform="translate({dx} 0)"/></g>')
    random.seed(7)
    for _ in range(14):
        s = random.choice([22, 28, 34])
        x = random.randint(230, 760)
        y = random.choice([340, 372, 410, 448, 575, 600, 640])
        out.append(f'<rect x="{x}" y="{y}" width="{s}" height="{s}" fill="{random.choice([CYAN, PINK, "#fff"])}" opacity="{random.choice([0.5, 0.7, 0.9])}"/>')
    return wrap(defs, "\n".join(out), "url(#bgB)")

# ---------------------------------------------------------------- C: Potato Lens
def portrait(x, y):
    """Synthetic portrait colour at normalised lens coords (-1..1)."""
    if (x / 0.55) ** 2 + ((y + 0.05) / 0.68) ** 2 < 1:
        if y < -0.42 and abs(x) < 0.6: return (58, 40, 34)           # hair
        if abs(y + 0.05) < 0.09 and 0.12 < abs(x) < 0.34: return (40, 30, 30)  # eyes
        return (238, 184, 146)                                        # skin
    if y > 0.55: return (250, 110, 80)                                # shirt
    return (64, 150, 190)                                             # background

def icon_lens():
    defs = '''<linearGradient id="bgC" x1="0" y1="0" x2="0.4" y2="1"><stop offset="0" stop-color="#FFC15E"/><stop offset="1" stop-color="#FF5E3A"/></linearGradient>
    <clipPath id="lens"><circle cx="512" cy="470" r="196"/></clipPath>
    <radialGradient id="glass" cx="0.35" cy="0.25" r="0.8"><stop offset="0" stop-color="#fff" stop-opacity="0.35"/><stop offset="0.4" stop-color="#fff" stop-opacity="0"/></radialGradient>'''
    out = ['<rect x="452" y="760" width="120" height="70" fill="#1b1b22"/>',
           '<ellipse cx="512" cy="840" rx="190" ry="44" fill="#1b1b22"/>',
           '<circle cx="512" cy="470" r="300" fill="#1b1b22"/>',
           '<circle cx="512" cy="470" r="232" fill="#2b2b35"/>',
           '<g clip-path="url(#lens)">']
    random.seed(3)
    B = 44
    for by in range(316 - B, 666, B):
        for bx in range(316 - B, 708, B):
            nx, ny = (bx + B / 2 - 512) / 196, (by + B / 2 - 470) / 196
            r, g, b = portrait(nx, ny)
            j = random.randint(-14, 14)
            out.append(f'<rect x="{bx}" y="{by}" width="{B}" height="{B}" fill="rgb({max(0, min(255, r + j))},{max(0, min(255, g + j))},{max(0, min(255, b + j))})"/>')
    out.append('</g><circle cx="512" cy="470" r="196" fill="url(#glass)"/>')
    out.append(f'<circle cx="512" cy="470" r="196" fill="none" stroke="#000" stroke-opacity="0.5" stroke-width="10"/>')
    out.append(f'<circle cx="700" cy="250" r="18" fill="{CYAN}"/>')
    return wrap(defs, "\n".join(out), "url(#bgC)")

# ---------------------------------------------------------------- D: Frozen Call
def call_pixel(x, y):
    if (x - 512) ** 2 + (y - 455) ** 2 < 100 ** 2: return "#f2c6a0"
    if y > 575 and abs(x - 512) < 230 - max(0, 640 - y) * 0.9: return "#ff7a59"
    if abs(x - 512) < 42 and 540 < y <= 600: return "#e9b48c"
    return "#24324a"

def icon_call():
    defs = '''<linearGradient id="bgD" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#2F6BFF"/><stop offset="1" stop-color="#22D3EE"/></linearGradient>
    <clipPath id="tile"><rect x="172" y="262" width="680" height="500" rx="56"/></clipPath>'''
    out = ['<rect x="172" y="262" width="680" height="500" rx="56" fill="#24324a"/>', '<g clip-path="url(#tile)">',
           '<circle cx="512" cy="455" r="100" fill="#f2c6a0"/>',
           '<rect x="470" y="540" width="84" height="60" fill="#e9b48c"/>',
           '<path d="M 282 762 Q 300 590 512 585 Q 724 590 742 762 Z" fill="#ff7a59"/>']
    # horizontal tear through the face: this band is shifted sideways
    out.append('<clipPath id="tear"><rect x="172" y="430" width="680" height="52"/></clipPath>')
    out.append('<g clip-path="url(#tear)"><rect x="172" y="430" width="680" height="52" fill="#24324a"/>'
               '<circle cx="566" cy="455" r="100" fill="#f2c6a0"/><rect x="566" y="430" width="6" height="52" fill="#22D3EE" opacity="0.7"/></g>')
    # a few lost blocks on the right edge of the head
    B = 36
    for bx, by in [(560, 372), (596, 372), (596, 408), (560, 500), (596, 500), (524, 500)]:
        out.append(f'<rect x="{bx}" y="{by}" width="{B}" height="{B}" fill="{call_pixel(bx + B / 2, by + B / 2)}"/>')
    # grey half-decoded frame along the bottom with a ragged edge
    out.append('<rect x="172" y="690" width="680" height="72" fill="#808080"/>')
    for x in range(172, 852, 40):
        if (x // 40) % 3 != 1: out.append(f'<rect x="{x}" y="650" width="40" height="40" fill="#808080"/>')
    out.append('</g>')
    out.append('<circle cx="770" cy="340" r="44" fill="#000" opacity="0.35"/>')
    out.append('<path d="M 770 314 A 26 26 0 1 1 744 340" fill="none" stroke="#fff" stroke-width="10" stroke-linecap="round"/>')
    return wrap(defs, "\n".join(out), "url(#bgD)")

# ---------------------------------------------------------------- E: Breaking Spinner
def icon_spinner():
    defs = '''<linearGradient id="bgE" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#FF4E6A"/><stop offset="1" stop-color="#FFB36B"/></linearGradient>'''
    out = []
    n = 8
    for i in range(n):
        ang = -90 + i * 360 / n
        op = 1 - i * 0.1
        if i == 1:
            # this dash has disintegrated into blocks drifting outward
            random.seed(11)
            a = math.radians(ang)
            for k in range(16):
                t = random.uniform(0.0, 1.0)
                dist = 200 + t * 230 + random.uniform(-14, 14)
                perp = random.uniform(-34, 34) * (1 + t)
                x = 512 + dist * math.cos(a) - perp * math.sin(a)
                y = 512 + dist * math.sin(a) + perp * math.cos(a)
                s = random.choice([26, 30, 36]) * (1 - t * 0.45)
                out.append(f'<rect x="{x - s / 2:.1f}" y="{y - s / 2:.1f}" width="{s:.1f}" height="{s:.1f}" fill="#fff" opacity="{0.95 - t * 0.6:.2f}"/>')
            continue
        out.append(f'<rect x="483" y="190" width="58" height="140" rx="29" transform="rotate({ang + 90} 512 512)" fill="#fff" opacity="{op:.2f}"/>')
    return wrap(defs, "\n".join(out), "url(#bgE)")

os.makedirs(OUT, exist_ok=True)
for name, fn in [("a-signal-pads", icon_pads), ("b-glitched-wifi", icon_wifi), ("c-potato-lens", icon_lens),
                 ("d-frozen-call", icon_call), ("e-breaking-spinner", icon_spinner)]:
    with open(os.path.join(OUT, name + ".svg"), "w") as f:
        f.write(fn())
    print("wrote", name)
