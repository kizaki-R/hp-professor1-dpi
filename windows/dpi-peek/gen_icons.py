"""Downscale logo PNGs into Rust BGRA tables and a multi-size ICO."""
from pathlib import Path
from PIL import Image, ImageDraw

SRC = Path(r"C:\Users\ffitz\Downloads\DPI_Peek_logo_pack")
OUT = Path(__file__).resolve().parent / "src" / "logo_icons.rs"
ICO = Path(__file__).resolve().parent / "assets"
ICO.mkdir(exist_ok=True)


def draw_mark(size: int, active: int) -> Image.Image:
    im = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    m = max(1, size // 32)
    d.rounded_rectangle((m, m, size - 1 - m, size - 1 - m), radius=size // 4.5, fill=(17, 23, 33, 255))
    heights = [0.42, 0.58, 0.78, 1.0, 0.78, 0.58, 0.42]
    pad_x = size * 0.16
    pad_y = size * 0.22
    w = size - pad_x * 2
    h = size - pad_y * 2
    slant = 0.22
    max_h = h * 0.96
    inner = max(1.0, w - max_h * slant)
    bar_w = inner * 0.072
    gap = (inner - 7 * bar_w) / 6
    mid_y = pad_y + h / 2
    for i, ratio in enumerate(heights):
        bh = max_h * ratio
        skew = bh * slant
        top = mid_y - bh / 2
        bot = mid_y + bh / 2
        left = pad_x + i * (bar_w + gap)
        color = (98, 216, 255, 255) if i == active else (243, 247, 255, 255)
        d.polygon(
            [(left, bot), (left + bar_w, bot), (left + bar_w + skew, top), (left + skew, top)],
            fill=color,
        )
    return im


def bgra_image(im: Image.Image, size: int) -> bytes:
    im = im.resize((size, size), Image.Resampling.LANCZOS)
    raw = im.tobytes()
    out = bytearray(size * size * 4)
    for i in range(size * size):
        r, g, b, a = raw[i * 4 : i * 4 + 4]
        out[i * 4 : i * 4 + 4] = bytes((b, g, r, a))
    return bytes(out)


def rust_array(name: str, data: bytes) -> str:
    rows = []
    for i in range(0, len(data), 16):
        chunk = ", ".join(str(b) for b in data[i : i + 16])
        rows.append(f"        {chunk},")
    body = "\n".join(rows)
    return f"pub static {name}: [u8; {len(data)}] = [\n{body}\n    ];\n"


def write_ico(path: Path, src: Image.Image) -> None:
    import struct
    from io import BytesIO
    src = src.convert("RGBA")
    sizes = [16, 24, 32, 48, 64, 128, 256]
    blobs = []
    for size in sizes:
        buf = BytesIO()
        src.resize((size, size), Image.Resampling.LANCZOS).save(buf, format="PNG", optimize=True)
        blobs.append(buf.getvalue())
    out = bytearray(struct.pack("<HHH", 0, 1, len(blobs)))
    offset = 6 + 16 * len(blobs)
    for size, blob in zip(sizes, blobs):
        dim = 0 if size == 256 else size
        out += struct.pack("<BBBBHHII", dim, dim, 0, 0, 1, 32, len(blob), offset)
        offset += len(blob)
    for blob in blobs:
        out += blob
    path.write_bytes(out)


master = 1024
parts = [
    "// Generated even-pitch SEVEN SHIFT mark. Do not edit.",
    "pub const ICON_PX: usize = 32;",
    rust_array("SEVEN_APP", bgra_image(draw_mark(master, 3), 32)),
]
for n in range(1, 8):
    parts.append(rust_array(f"STAGE_{n}", bgra_image(draw_mark(master, n - 1), 32)))
parts.append("pub static STAGES: [&[u8]; 7] = [&STAGE_1, &STAGE_2, &STAGE_3, &STAGE_4, &STAGE_5, &STAGE_6, &STAGE_7];")
OUT.write_text("\n".join(parts) + "\n", encoding="utf-8")
app = draw_mark(master, 3)
write_ico(ICO / "seven_app.ico", app)
sheet = Image.new("RGB", (980, 160), (40, 40, 44))
for i in range(7):
    sheet.paste(draw_mark(128, i), (16 + i * 138, 16))
sheet.save(Path(__file__).resolve().parent.parent / "icon-even.png")
print("wrote", OUT, "bytes", OUT.stat().st_size)
