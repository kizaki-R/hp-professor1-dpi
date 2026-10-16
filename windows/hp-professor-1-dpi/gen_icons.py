"""Render the VELOCITY app mark from its SVG geometry into Rust BGRA tables.

Source of truth, verbatim from VELOCITY_Complete:
  01_Vector_SVG/AppIcon_dark.svg
  04_DPI_Stages_1_to_7/dark/Stage_N.svg

The seven bars are drawn from the SVG polygon coordinates, not traced by eye.
Bar with index N-1 is cyan for stage N; earlier bars are white and later bars
are the muted slate the brand uses for stages that are not active yet.
"""
from pathlib import Path
import shutil
import sys

import numpy as np
from PIL import Image, ImageDraw

VB = 512.0
WORK = 2048
MASTER = 1024
ICON_PX = 32

HERE = Path(__file__).resolve().parent
OUT = HERE / "src" / "logo_icons.rs"
ASSETS = HERE / "assets"
PREVIEW = HERE.parent


def find_pack() -> Path:
    """Locate the VELOCITY pack, preferring the copy committed to this repo."""
    rel = Path("assets") / "logo" / "velocity" / "VELOCITY_Complete"
    for base in (HERE.parent.parent, *HERE.parents):
        candidate = base / rel
        if candidate.is_dir():
            return candidate
    fallback = Path.home() / "Downloads" / "DPI_Peek_VELOCITY_Complete_Assets" / "DPI_Peek_VELOCITY_Complete"
    if fallback.is_dir():
        return fallback
    raise SystemExit("VELOCITY pack not found; expected " + str(HERE.parent.parent / rel))


PACK = find_pack()

# Mark geometry, normalized against the bar bounding box (346.8 x 279).
MARK_BOX = (90.0, 109.0, 346.8, 279.0)
MARK_ASPECT = 346.8 / 279.0
BAR_W = 0.083622
BAR_X = [0.0, 0.126874, 0.253749, 0.380623, 0.507497, 0.634371, 0.761246]
BAR_TOP = [0.673835, 0.555556, 0.433692, 0.308244, 0.193548, 0.093190, 0.0]
BAR_BOT = [1.0, 0.971326, 0.939068, 0.903226, 0.870968, 0.831541, 0.802867]
BAR_SKEW = [0.062860, 0.080161, 0.097463, 0.114764, 0.130911, 0.142445, 0.155133]

WHITE = (243, 247, 255)
CYAN = (57, 213, 255)
FUTURE = (59, 70, 88)

# Sizes are half the CSS pixel values inside the SVG, so the master renders at
# 4x. Every constant below is copy-pasted from AppIcon_dark.svg.
PLATE = (8.0, 8.0, 496.0, 496.0, 112.0)
PLATE_EDGE = (8.75, 8.75, 494.5, 494.5, 111.5, 1.8)
SURFACE = (40.0, 40.0, 432.0, 432.0, 93.0)
SURFACE_STROKE = (1.3, (0x23, 0x38, 0x54))
SURFACE_OPACITY = 0.34


def _uv(x0, y0, w, h):
    yy, xx = np.mgrid[0:WORK, 0:WORK]
    xu = xx.astype(np.float32) / WORK * VB
    yv = yy.astype(np.float32) / WORK * VB
    return (xu - x0) / w, (yv - y0) / h


def _ramp(t, stops):
    offs = [s[0] for s in stops]
    rgb = np.stack(
        [np.interp(t, offs, [s[1][c] for s in stops]) for c in range(3)], axis=-1
    )
    alpha = np.interp(t, offs, [s[2] for s in stops])
    return rgb.astype(np.float32), alpha.astype(np.float32)


def linear(x0, y0, w, h, gx1, gy1, gx2, gy2, stops):
    u, v = _uv(x0, y0, w, h)
    dx, dy = gx2 - gx1, gy2 - gy1
    t = ((u - gx1) * dx + (v - gy1) * dy) / (dx * dx + dy * dy)
    return _ramp(t, stops)


def radial(x0, y0, w, h, cx, cy, r, stops):
    u, v = _uv(x0, y0, w, h)
    return _ramp(np.hypot(u - cx, v - cy) / r, stops)


def rr_mask(x, y, w, h, r):
    im = Image.new("L", (WORK, WORK), 0)
    k = WORK / VB
    ImageDraw.Draw(im).rounded_rectangle(
        [x * k, y * k, (x + w) * k, (y + h) * k], radius=r * k, fill=255
    )
    return np.asarray(im, dtype=np.float32) / 255.0


def over(dst, rgb, alpha, mask):
    a = np.clip(alpha * mask, 0.0, 255.0) / 255.0
    a3 = a[..., None]
    dst[..., :3] = rgb * a3 + dst[..., :3] * (1.0 - a3)
    dst[..., 3] = np.clip(a * 255.0 + dst[..., 3] * (1.0 - a), 0.0, 255.0)


def bars_layer(active):
    im = Image.new("RGBA", (WORK, WORK), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    k = WORK / VB
    x0, y0, mw, mh = MARK_BOX
    for i in range(7):
        left = (x0 + BAR_X[i] * mw) * k
        right = left + BAR_W * mw * k
        skew = BAR_SKEW[i] * mw * k
        top = (y0 + BAR_TOP[i] * mh) * k
        bot = (y0 + BAR_BOT[i] * mh) * k
        if i == active:
            colour = CYAN
        elif i < active:
            colour = WHITE
        else:
            colour = FUTURE
        d.polygon(
            [(left, bot), (right, bot), (right + skew, top), (left + skew, top)],
            fill=colour + (255,),
        )
    return np.asarray(im, dtype=np.float32)


def render_active(active):
    """active is 0-based; the app icon passes 6, a stage icon passes N-1."""
    canvas = np.zeros((WORK, WORK, 4), dtype=np.float32)

    px, py, pw, ph, pr = PLATE
    plate = rr_mask(px, py, pw, ph, pr)

    rgb, a = linear(px, py, pw, ph, 0.12, 0.03, 0.92, 1.0, [
        (0.0, (0x14, 0x23, 0x37), 255.0),
        (0.48, (0x0D, 0x16, 0x25), 255.0),
        (1.0, (0x07, 0x0D, 0x17), 255.0),
    ])
    over(canvas, rgb, a, plate)

    rgb, a = radial(px, py, pw, ph, 0.83, 0.88, 0.82, [
        (0.0, (0x16, 0x69, 0xA6), 0.45 * 255.0),
        (0.60, (0x14, 0x30, 0x55), 0.07 * 255.0),
        (1.0, (0x0B, 0x13, 0x20), 0.0),
    ])
    over(canvas, rgb, a, plate)

    ex, ey, ew, eh, er, ewid = PLATE_EDGE
    inner = rr_mask(ex + ewid, ey + ewid, ew - 2 * ewid, eh - 2 * ewid, er - ewid)
    ring = np.clip(plate - inner, 0.0, 1.0)
    rgb, a = linear(ex, ey, ew, eh, 0.0, 0.0, 1.0, 1.0, [
        (0.0, (0x61, 0xB5, 0xF2), 0.55 * 255.0),
        (0.48, (0x43, 0x64, 0x80), 0.18 * 255.0),
        (1.0, (0x16, 0x7D, 0xBB), 0.65 * 255.0),
    ])
    over(canvas, rgb, a, ring)

    sx, sy, sw, sh, sr = SURFACE
    face = rr_mask(sx, sy, sw, sh, sr)
    rgb, a = linear(sx, sy, sw, sh, 0.0, 0.0, 1.0, 1.0, [
        (0.0, (0x17, 0x23, 0x37), 0.82 * 255.0),
        (1.0, (0x07, 0x10, 0x1C), 0.48 * 255.0),
    ])
    over(canvas, rgb, a * SURFACE_OPACITY, face)

    swid, scol = SURFACE_STROKE
    face_in = rr_mask(sx + swid, sy + swid, sw - 2 * swid, sh - 2 * swid, sr - swid)
    edge = np.clip(face - face_in, 0.0, 1.0)
    solid = np.broadcast_to(np.array(scol, dtype=np.float32), (WORK, WORK, 3))
    over(canvas, solid, np.full((WORK, WORK), 255.0, dtype=np.float32), edge)

    bars = bars_layer(active)
    over(canvas, bars[..., :3], bars[..., 3], np.ones((WORK, WORK), dtype=np.float32))

    master = Image.fromarray(np.clip(canvas, 0, 255).astype(np.uint8), "RGBA")
    return master.resize((MASTER, MASTER), Image.Resampling.LANCZOS)


def bgra(pixels_32):
    arr = np.asarray(pixels_32, dtype=np.uint8)
    out = arr[..., [2, 1, 0, 3]].tobytes()
    return out


def rust_array(name, data):
    rows = []
    for i in range(0, len(data), 16):
        rows.append("        " + ", ".join(str(b) for b in data[i:i + 16]) + ",")
    return f"pub static {name}: [u8; {len(data)}] = [\n" + "\n".join(rows) + "\n    ];\n"


def small(master, size):
    return master.resize((size, size), Image.Resampling.LANCZOS)


def main():
    app = render_active(6)
    parts = [
        "// Generated from the VELOCITY brand SVG. Do not edit.",
        "// Geometry and colours come from AppIcon_dark.svg and Stage_N.svg.",
        f"pub const ICON_PX: usize = {ICON_PX};",
        rust_array("APP_MARK", bgra(small(app, ICON_PX))),
    ]
    icons = []
    for n in range(1, 8):
        stage = render_active(n - 1)
        icons.append(small(stage, ICON_PX))
        parts.append(rust_array(f"STAGE_{n}", bgra(icons[-1])))
    parts.append("pub static STAGES: [&[u8]; 7] = [&STAGE_1, &STAGE_2, &STAGE_3, &STAGE_4, &STAGE_5, &STAGE_6, &STAGE_7];")
    OUT.write_text("\n".join(parts) + "\n", encoding="utf-8")

    ASSETS.mkdir(exist_ok=True)
    shutil.copyfile(PACK / "06_Extras" / "AppIcon_Windows.ico", ASSETS / "AppIcon.ico")
    for stale in ("app.ico", "seven_app.ico", "DPIPeek.ico"):
        path = ASSETS / stale
        if path.exists():
            path.unlink()

    if "--preview" in sys.argv:
        app.save(PREVIEW / "velocity-app.png")
        sheet = Image.new("RGB", (1060, 560), (16, 22, 33))
        big = small(app, 256)
        sheet.paste(big, (40, 40), big)
        row = Image.new("RGB", (7 * 40, 40), (16, 22, 33))
        for i, icon in enumerate(icons):
            row.paste(icon.resize((32, 32), Image.Resampling.NEAREST), (i * 40 + 4, 4))
        sheet.paste(row, (360, 40))
        tiny = Image.new("RGB", (7 * 24, 24), (16, 22, 33))
        for i, icon in enumerate(icons):
            tiny.paste(icon.resize((16, 16), Image.Resampling.NEAREST), (i * 24 + 4, 4))
        sheet.paste(tiny, (360, 100))
        real = Image.new("RGB", (7 * 20, 20), (222, 226, 233))
        for i, icon in enumerate(icons):
            real.paste(icon.resize((16, 16), Image.Resampling.NEAREST), (i * 20 + 2, 2))
        sheet.paste(real, (360, 140))
        for i, icon in enumerate(icons):
            sheet.paste(icon.resize((64, 64), Image.Resampling.LANCZOS), (360 + i * 72, 200), icon.resize((64, 64), Image.Resampling.LANCZOS))
        sheet.save(PREVIEW / "velocity-icons.png")
        print("wrote preview PNGs")
    print("wrote", OUT, OUT.stat().st_size, "bytes")
    print("wrote", ASSETS / "AppIcon.ico")


if __name__ == "__main__":
    main()
