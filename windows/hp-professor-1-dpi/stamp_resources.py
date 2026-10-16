"""Attach an icon and version info to the Windows exe.

The GNU toolchain this project builds with ships no resource compiler, so
`cargo build` produced an exe with no .rsrc section at all: Explorer showed a
blank icon in the Downloads folder and the file had no version metadata.

rc.exe (from the Windows SDK, used at release time only) turns assets/app.rc
into a flat list of resource records. A PE image needs a three-level tree
instead, so the directory is assembled here and appended as a .rsrc section.

Usage:  python stamp_resources.py target/release/hp-professor-1-dpi.exe out.exe

If rc.exe cannot be found the input is copied unchanged and the exit status is
2, so an ordinary build never depends on the SDK being installed.
"""
from __future__ import annotations

import shutil
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
RC = HERE / "assets" / "app.rc"

SECTION_ALIGN = 0x1000
FILE_ALIGN = 0x200
RESOURCE_DIRECTORY_INDEX = 2
RT_VERSION = 16
DIRECTORY_FLAG = 0x80000000
VERSION_CODEPAGE = 1200

# RESOURCEHEADER: 5 DWORDs, 2 WORDs, 2 DWORDs.
RECORD = struct.Struct("<IIIIIHHII")
DIRECTORY = struct.Struct("<IIHHHH")
DIR_ENTRY = struct.Struct("<II")
DATA_ENTRY = struct.Struct("<IIII")


def find_rc() -> Path | None:
    kits = Path(r"C:\Program Files (x86)\Windows Kits\10\bin")
    if kits.is_dir():
        for version in sorted(kits.iterdir(), reverse=True):
            candidate = version / "x64" / "rc.exe"
            if candidate.is_file():
                return candidate
    found = shutil.which("rc.exe")
    return Path(found) if found else None


def compile_res(rc: Path, work: Path) -> bytes:
    res = work / "app.res"
    proc = subprocess.run(
        [str(rc), "/nologo", "/fo", str(res), str(RC)],
        cwd=HERE,
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0 or not res.is_file():
        raise SystemExit("rc.exe failed: " + (proc.stdout + proc.stderr).strip())
    return res.read_bytes()


def parse_res(blob: bytes) -> dict[int, dict[int, dict[int, bytes]]]:
    """Read rc.exe's flat record list into a type -> name -> language tree.

    Numeric identifiers are not stored plainly: an ordinal is written as
    0xFFFF in the low word with the value in the high word, so ICON type 3
    arrives as 0x0003FFFF.
    """
    tree: dict[int, dict[int, dict[int, bytes]]] = {}
    pos = 0
    while pos + RECORD.size <= len(blob):
        size, header, rtype, name, _version, _memflags, lang, _ver, _chars = (
            RECORD.unpack_from(blob, pos)
        )
        if header != RECORD.size:
            raise SystemExit(f"unexpected record header size {header} at {pos:#x}")
        pos += header
        payload = blob[pos : pos + size]
        if len(payload) != size:
            raise SystemExit("resource record ran past the end of the blob")
        pos += (size + 3) // 4 * 4
        if rtype == 0xFFFF and name == 0xFFFF:
            continue  # the leading null record
        if rtype & 0xFFFF != 0xFFFF or name & 0xFFFF != 0xFFFF:
            raise SystemExit(f"unexpected string resource at {pos:#x}")
        tree.setdefault(rtype >> 16, {}).setdefault(name >> 16, {})[lang] = payload
    if not tree:
        raise SystemExit("no resources found in the compiled blob")
    return tree


def align_up(value: int, align: int) -> int:
    return (value + align - 1) // align * align


def build_rsrc(tree: dict[int, dict[int, dict[int, bytes]]], rva: int) -> bytes:
    """Assemble a .rsrc section from a type -> name -> language tree.

    A PE resource directory has three levels: type, name, language. Directory
    entries hold section-relative offsets (flagged with the high bit); leaf
    entries point at 16-byte data entries that carry real RVAs.
    """
    level2 = [tree[t] for t in sorted(tree)]
    level3 = [tree[t][n] for t in sorted(tree) for n in sorted(tree[t])]
    dirs = [tree, *level2, *level3]

    at: dict[int, int] = {}
    cursor = 0
    for node in dirs:
        at[id(node)] = cursor
        cursor += DIRECTORY.size + DIR_ENTRY.size * len(node)
    cursor = align_up(cursor, 4)

    index_at: dict[tuple[int, int, int], int] = {}
    for t in sorted(tree):
        for n in sorted(tree[t]):
            for lang in sorted(tree[t][n]):
                index_at[(t, n, lang)] = cursor
                cursor += DATA_ENTRY.size
    cursor = align_up(cursor, 4)

    payload_at: dict[tuple[int, int, int], int] = {}
    for t in sorted(tree):
        for n in sorted(tree[t]):
            for lang in sorted(tree[t][n]):
                payload_at[(t, n, lang)] = cursor
                cursor = align_up(cursor + len(tree[t][n][lang]), 4)

    out = bytearray(cursor)

    def write_dir(node: dict, keys: list, children: list) -> None:
        base = at[id(node)]
        DIRECTORY.pack_into(out, base, 0, 0, 0, 0, 0, len(keys))
        for i, (key, child) in enumerate(zip(keys, children)):
            if child is not None:
                value = at[id(child)] | DIRECTORY_FLAG
            else:
                value = index_at[leaf_key[(id(node), key)]]
            DIR_ENTRY.pack_into(out, base + DIRECTORY.size + i * DIR_ENTRY.size, key, value)

    leaf_key: dict[tuple[int, int], tuple[int, int, int]] = {}
    for t in sorted(tree):
        for n in sorted(tree[t]):
            for lang in sorted(tree[t][n]):
                leaf_key[(id(tree[t][n]), lang)] = (t, n, lang)

    write_dir(tree, sorted(tree), [tree[t] for t in sorted(tree)])
    for t in sorted(tree):
        write_dir(tree[t], sorted(tree[t]), [tree[t][n] for n in sorted(tree[t])])
    for t in sorted(tree):
        for n in sorted(tree[t]):
            write_dir(tree[t][n], sorted(tree[t][n]), [None] * len(tree[t][n]))

    for t in sorted(tree):
        for n in sorted(tree[t]):
            for lang in sorted(tree[t][n]):
                payload = tree[t][n][lang]
                where = payload_at[(t, n, lang)]
                codepage = VERSION_CODEPAGE if t == RT_VERSION else 0
                DATA_ENTRY.pack_into(
                    out, index_at[(t, n, lang)], rva + where, len(payload), codepage, 0
                )
                out[where : where + len(payload)] = payload

    return bytes(out)


def inject(exe: bytes, rsrc: bytes) -> bytes:
    data = bytearray(exe)
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    if data[pe : pe + 4] != b"PE\0\0":
        raise SystemExit("not a PE file")
    coff = pe + 4
    num_sections = struct.unpack_from("<H", data, coff + 2)[0]
    size_opt = struct.unpack_from("<H", data, coff + 16)[0]
    opt = coff + 20
    if struct.unpack_from("<H", data, opt)[0] != 0x20B:
        raise SystemExit("expected a PE32+ image")

    size_image = struct.unpack_from("<I", data, opt + 56)[0]
    ddir = opt + 112
    if struct.unpack_from("<I", data, opt + 108)[0] < RESOURCE_DIRECTORY_INDEX + 1:
        raise SystemExit("optional header has no resource directory slot")

    first_header = pe + 24 + size_opt
    for i in range(num_sections):
        if data[first_header + i * 40 : first_header + i * 40 + 8].rstrip(b"\0") == b".rsrc":
            raise SystemExit("this exe already has a .rsrc section")

    # .bss-style sections carry no raw data, so pointer 0 must not count here.
    first_raw = min(
        raw
        for i in range(num_sections)
        for raw in [struct.unpack_from("<I", data, first_header + i * 40 + 20)[0]]
        if raw
    )
    header_room = first_header + num_sections * 40
    if header_room + 40 > first_raw:
        raise SystemExit("no room for another section header")

    rva = align_up(size_image, SECTION_ALIGN)
    raw = align_up(len(data), FILE_ALIGN)
    body = align_up(len(rsrc), FILE_ALIGN)

    header = bytearray(40)
    header[0:8] = b".rsrc\0\0\0"
    struct.pack_into("<I", header, 8, len(rsrc))
    struct.pack_into("<I", header, 12, rva)
    struct.pack_into("<I", header, 16, body)
    struct.pack_into("<I", header, 20, raw)
    struct.pack_into("<I", header, 36, 0x40000040)

    struct.pack_into("<H", data, coff + 2, num_sections + 1)
    struct.pack_into("<I", data, opt + 56, rva + align_up(len(rsrc), SECTION_ALIGN))
    struct.pack_into("<II", data, ddir + RESOURCE_DIRECTORY_INDEX * 8, rva, len(rsrc))
    data[header_room : header_room + 40] = header
    data.extend(b"\0" * (raw - len(data)))
    data.extend(rsrc)
    data.extend(b"\0" * (align_up(len(data), FILE_ALIGN) - len(data)))
    return bytes(data)


def section_rva(exe: bytes) -> int:
    pe = struct.unpack_from("<I", exe, 0x3C)[0]
    opt = pe + 24
    return align_up(struct.unpack_from("<I", exe, opt + 56)[0], SECTION_ALIGN)


def main() -> int:
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    src, dst = Path(sys.argv[1]), Path(sys.argv[2])
    exe = src.read_bytes()

    rc = find_rc()
    if rc is None:
        print("rc.exe not found; writing the exe without an embedded icon")
        dst.write_bytes(exe)
        return 2

    with tempfile.TemporaryDirectory() as tmp:
        rsrc = build_rsrc(parse_res(compile_res(rc, Path(tmp))), section_rva(exe))
    dst.write_bytes(inject(exe, rsrc))
    print(f"stamped {dst} with {len(rsrc)} bytes of resources")
    return 0


if __name__ == "__main__":
    sys.exit(main())
