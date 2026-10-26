#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Write the .mra files and prove each one byte for byte.

    python scripts/build_mra.py                      # every set -> releases/_dev/
    python scripts/build_mra.py avengrgs             # one set
    python scripts/build_mra.py --check              # verify only, write nothing
    python scripts/build_mra.py --image avengrgs out.bin   # the download image, for the benches
    python scripts/build_mra.py --release            # -> releases/ (only with a released .rbf)

The image is the .mra's: MAME's regions in order at scripts/mlc_layout.py's bases, as the HPS
streams it. The core's download path then moves gfx1 into its unit layout
(rtl/memory/mlc_dl_xform.sv); sim/download_tb proves that against mlc_layout.build_image.
Each region is built twice: by this script from the driver's ROM_START records
(scripts/extract_romstart.py), and by re-reading the written .mra with scripts/mra.py
(mra-tools-c's semantics); the two must be identical. Interleave maps are not reasoned about:
each candidate is tried against the ROM_START image and the one that reproduces it is written.
After Arcade-DreamWorld_MiSTer's scripts/build_mra.py.
"""
import argparse
import itertools
import re
import subprocess
import sys
import zipfile
from pathlib import Path
from xml.sax.saxutils import escape

sys.path.insert(0, str(Path(__file__).resolve().parent))
import extract_romstart as ers     # noqa: E402
import mlc_layout as layout        # noqa: E402
import mra as mra_lib              # noqa: E402
from coretools import setting      # noqa: E402

REPO = Path(__file__).resolve().parent.parent
DRIVER = Path(setting("MAME_SRC") or "E:/mame/src/mame/dataeast/deco_mlc.cpp")
ROMDIRS = [Path(p) for p in (setting("MAME_ROMPATH") or "F:/Emulation/roms/MAME ROMs").split(";")]

# set: parent or None. The SH-2 sets first (docs/ROADMAP.md, Game scope).
SETS = {"avengrgs": None, "avengrgsj": "avengrgs"}
# the DE156 sets (Phase 4): parent or None. Not yet in SETS: they have no .mra yet, only
# --regions for the benches.
DE156_SETS = {"stadhr96": None, "stadhr96u": "stadhr96", "stadhr96j": "stadhr96",
              "stadhr96j2": "stadhr96", "stadhr96k": "stadhr96",
              "skullfng": None, "skullfngj": "skullfng", "skullfnga": "skullfng",
              "hoops96": None, "hoops95": "hoops96", "ddream95": "hoops96", "acchi": None}
# the .rbf: DecoMLC for the SH-2 machine config (avengrgs), DecoMLC156 for the DE156 ones
# (docs/ROADMAP.md, "Two .rbfs, one project"); see <rbf> below
# Four buttons a player (deco_mlc.cpp 379-381, 400); the names are the project owner's
# correction of ones taken from MAME by observation (docs/HACKS.md).
# The DE156 sets' names are their own how-to-play screens' in MAME (A, B, C), except hoops96's
# B and C, and acchi's, which are its grip lever's two buttons, found by holding each in the
# practice round (BUTTON_NOTES).
BUTTONS = {"avengrgs": ["Light Punch", "Heavy Punch", "Light Kick", "Heavy Kick"],
           "stadhr96": ["Dash", "Pitch/Swing", "Bunt/Substitute"],
           "skullfng": ["Shot", "Shot/Throttle", "Barrel Roll/Bomb"],
           "hoops96":  ["Shoot", "Pass", "Switch Player"],
           "acchi":    ["Upper Button", "Lower Button"]}
# a comment above <buttons>, where a name alone does not say how the game is played
BUTTON_NOTES = {"acchi": ["the grip lever's two buttons: Upper and Lower held = Rock, Lower alone = Scissors,",
                          "neither = Paper (Upper alone is no hand). Start is the red button that advances."]}
CATEGORY = {"avengrgs": "Fighter", "stadhr96": "Sports", "skullfng": "Shooter", "hoops96": "Sports",
            "acchi": "Puzzle"}
ROTATION = {0: "horizontal", 90: "vertical (cw)", 270: "vertical (ccw)"}
ROT_CODE = {0: 0, 90: 1, 270: 2}   # mod byte bits 2:1
# MAME's hiscore plugin data, beside the driver's source tree
HISCORE_DAT = DRIVER.parents[3] / "plugins" / "hiscore" / "hiscore.dat"
# rtl/hiscore.v header (Psikyo's): START_WAIT 0x199A57EF clk before the first check, CHECK_WAIT
# 0x3FFF, then the table's fixed fields; one 8-byte line per entry follows
HISCORE_HEADER = "19 9A 57 EF 3F FF 00 02 00 02 00 01 00 0F 10 00"

# region -> (base, capacity)
REGIONS = (("maincpu", layout.MAINCPU_BASE, 0x100000), ("gfx1", layout.GFX1_BASE, layout.GFX1_SIZE),
           ("gfx2", layout.GFX2_BASE, layout.GFX2_SIZE), ("ymz", layout.YMZ_BASE, layout.YMZ_SIZE))


def game_info(text, setname):
    m = re.search(r"GAME\(\s*(\d+)\s*,\s*" + setname + r"\s*,[^\n]*", text)
    if not m:
        sys.exit(f"no GAME line for {setname}")
    f = [x.strip() for x in m.group(0).split("(", 1)[1].split(",")]
    q = re.findall(r'"([^"]*)"', m.group(0))
    return {"year": f[0], "machine": f[3], "ports": f[4], "rot": int(f[7][3:]),
            "manufacturer": q[0], "title": q[1]}


def zips_for(setname):
    parent = SETS[setname] if setname in SETS else DE156_SETS[setname]
    names = [setname + ".zip"] + ([parent + ".zip"] if parent else [])
    found = []
    for n in names:
        for d in [REPO / "roms"] + ROMDIRS:
            if (d / n).exists():
                found.append(d / n)
                break
    return names, found


def region_size(body, region):
    m = re.search(r'ROM_REGION\w*\(\s*(0x[0-9a-fA-F]+)\s*,\s*"' + re.escape(region) + '"', body)
    return int(m.group(1), 16) if m else 0


def load_region(zs, records, size):
    """ROM_START records -> region bytes, as MAME's loader puts them (zero fill)."""
    out = bytearray(size)
    for kind, name, dest, length, crc, *rest in records:
        data = mra_lib._zip_read(zs, name, crc)
        assert len(data) == length, (name, len(data), length)
        if kind == "load":
            out[dest:dest + length] = data
        elif kind == "load16_byte":
            out[dest:dest + 2 * length:2] = data
        elif kind == "load32_word":
            # ROM_GROUPWORD | ROM_SKIP(2): each 16-bit word as stored, into every other word
            out[dest:dest + 2 * length:4] = data[0::2]
            out[dest + 1:dest + 2 * length:4] = data[1::2]
        elif kind == "load32_wswap":
            # ROM_GROUPWORD | ROM_SKIP(2) | ROM_REVERSE: each 16-bit word byte-reversed into
            # every other word of the region (romload.cpp)
            out[dest:dest + 2 * length:4] = data[1::2]
            out[dest + 1:dest + 2 * length:4] = data[0::2]
        else:
            sys.exit(f"record kind {kind} not handled")
    return bytes(out)


def hiscore_entries(setname):
    """The set's hiscore.dat entries as (address, length, start byte, end byte), or []."""
    if not HISCORE_DAT.exists():
        return []
    names, entries, out = [], [], {}
    for raw in HISCORE_DAT.read_text(encoding="utf-8", errors="replace").splitlines() + [""]:
        line = raw.strip()
        if line.endswith(":") and not line.startswith(("@", ";")):
            if entries:
                names, entries = [], []
            names.append(line[:-1])
        elif line.startswith("@"):
            entries.append(line)
        elif not line and entries:
            for n in names:
                out[n] = entries
            names, entries = [], []
    parsed = []
    for line in out.get(setname, []):
        f = line.split(",")
        if f[0] != "@:maincpu" or f[1] != "program":
            sys.exit(f"hiscore.dat {setname}: {line!r} is not on the main CPU's program space")
        parsed.append(tuple(int(x, 16) for x in f[2:6]))
    return parsed


def eeprom_record(body):
    """The driver's factory EEPROM image (ROM_REGION16_BE "eeprom"), as (name, crc, length)."""
    recs, unknown = ers.region_records(body, "eeprom")
    if unknown:
        sys.exit(f"eeprom region: unparsed {unknown}")
    if not recs:
        return None
    kind, name, dest, length, crc, *rest = recs[0]
    return name, crc, length


def interleave_group(zs, grp, lanes, want, region, start, setname):
    """The maps that reproduce `want` from the group's files, or exit."""
    raws = [mra_lib._zip_read(zs, r[1], r[4]) for r in grp]
    if lanes == 2:
        cands = ["10", "01"]
    else:
        # two files a 32-bit word, each two bytes in either position pair and either order
        cands = ["1200", "2100", "0012", "0021"]
    for p in itertools.permutations(cands, len(grp)):
        if mra_lib.interleave(list(zip(raws, p)), 8 * lanes) == want:
            return p
    sys.exit(f"{setname}: no interleave map reproduces {region} 0x{start:x}")


def build(setname, out_root, write=True):
    text = DRIVER.read_text(encoding="utf-8", errors="replace")
    body = ers.blocks(text)[setname]
    info = game_info(text, setname)
    parent = SETS[setname] if setname in SETS else DE156_SETS[setname]
    names, paths = zips_for(setname)
    if not paths:
        print(f"{setname}: no zip found ({' / '.join(names)}); skipped")
        return False
    zs = [zipfile.ZipFile(p) for p in paths]

    # the image this script expects: each region at its base, zeros elsewhere
    img = bytearray(layout.IMAGE_END)
    rec, data = {}, {}
    for region, base, cap in REGIONS:
        recs, unknown = ers.region_records(body, region)
        if unknown:
            sys.exit(f"{setname}: region {region}: unparsed {unknown}")
        rec[region] = recs
        size = min(region_size(body, region), cap)       # ymz: 8 MB declared, 6 MB loaded
        data[region] = load_region(zs, recs, size)
        img[base:base + size] = data[region]
    img = bytes(img)

    L, pos = [], 0

    def pad_to(addr, why):
        nonlocal pos
        if addr > pos:
            L.append(f'        <part repeat="0x{addr - pos:X}">00</part>  <!-- {why} -->')
            pos = addr
        assert pos == addr, (why, hex(pos), hex(addr))

    # lanes of the output word, and bytes each file gives a word, per record kind
    SHAPE = {"load16_byte": (2, 1), "load32_wswap": (4, 2), "load32_word": (4, 2)}
    for region, base, cap in REGIONS:
        recs = sorted(rec[region], key=lambda r: r[2])
        if not recs:
            continue
        pad_to(base, f"{region} at 0x{base:X}")
        L.append(f"        <!-- {region} -->")
        # runs of one kind, in address order (hoops: byte pairs, then one word-swapped plane)
        runs = []
        for r in recs:
            if runs and runs[-1][0][0] == r[0]:
                runs[-1].append(r)
            else:
                runs.append([r])
        for run in runs:
            kind = run[0][0]
            if kind == "load":
                for kind, name, dest, length, crc, *rest in run:
                    pad_to(base + dest, f"{region} 0x{dest:x}")
                    L.append(f'        <part name="{escape(name)}" crc="{crc:08x}"/>')
                    pos += length
                continue
            if kind not in SHAPE:
                sys.exit(f"{setname}: {region}: record kind {kind} not handled")
            lanes, bpf = SHAPE[kind]
            per = lanes // bpf     # files a group, when they fill the word
            i = 0
            while i < len(run):
                grp = [run[i]]
                while len(grp) < per and i + len(grp) < len(run) and \
                        run[i + len(grp)][2] - run[i + len(grp)][2] % lanes == run[i][2] - run[i][2] % lanes:
                    grp.append(run[i + len(grp)])
                start, length = grp[0][2] - grp[0][2] % lanes, grp[0][3]
                assert all(r[3] == length for r in grp), grp
                total = length * lanes // bpf             # the group's output, unfilled lanes zero
                pad_to(base + start, f"{region} 0x{start:x}")
                want = data[region][start:start + total]
                chosen = interleave_group(zs, grp, lanes, want, region, start, setname)
                L.append(f'        <interleave output="{8 * lanes}">')
                for r, mp in zip(grp, chosen):
                    L.append(f'            <part name="{escape(r[1])}" crc="{r[4]:08x}" map="{mp}"/>')
                L.append("        </interleave>")
                pos += total
                i += len(grp)
    pad_to(len(img), "image end")

    g_layout, g_frac8 = layout.set_gfx(setname)
    mod = (int(info["machine"] != "avengrgs") | ROT_CODE[info["rot"]] << 1 | int(info["machine"] == "stadhr96") << 3
           | g_layout << 4 | int(g_frac8) << 6)
    hs = hiscore_entries(setname)
    hs_xml = []
    if hs:
        lines = [HISCORE_HEADER] + [f"{a >> 24:02X} {a >> 16 & 255:02X} {a >> 8 & 255:02X} {a & 255:02X} "
                                    f"{n:02X} {st:02X} {en:02X} 00" for a, n, st, en in hs]
        hs_xml = ["    <!-- hiscore (rtl/hiscore.v), from MAME's plugins/hiscore/hiscore.dat -->",
                  '    <rom index="3">', "        <part>", *("        " + l for l in lines), "        </part>",
                  "    </rom>", f'    <nvram index="4" size="{sum(n for _, n, _, _ in hs)}"/>', ""]
    ee = eeprom_record(body)
    ee_xml = []
    if ee:
        ee_xml = ["    <!-- the factory EEPROM image (ROM_REGION16_BE eeprom): the core loads it into its 93C45 -->",
                  f'    <rom index="2" zip="{"|".join(names)}" md5="none">',
                  f'        <part name="{escape(ee[0])}" crc="{ee[1]:08x}"/>', "    </rom>", ""]
    game = BUTTONS[parent or setname]
    # six button slots, then Start, Coin, Pause, Test at the J1 line's positions (DecoMLC.sv);
    # Test has no default pad button
    btn_names = ",".join(game + ["-"] * (6 - len(game)) + ["Start", "Coin", "Pause", "Test"])
    btn_default = ",".join(["A", "B", "X", "Y", "L"][:len(game)] + ["Start", "Select", "R"])
    notes = BUTTON_NOTES.get(parent or setname, [])
    note_xml = [("    <!-- " if i == 0 else "         ") + n + (" -->" if i == len(notes) - 1 else "")
                for i, n in enumerate(notes)]
    q = {chr(34): "&quot;"}
    xml = [
        "<misterromdescription>",
        "    <!-- Generated by scripts/build_mra.py from MAME deco_mlc.cpp; the layout is",
        "         scripts/mlc_layout.py (rtl/video/mlc_video_pkg.sv). Do not edit by hand. -->",
        f'    <about author="Paul Priest" webpage="" source="MAME deco_mlc.cpp"/>',
        f"    <name>{escape(info['title'])}</name>",
        f"    <setname>{setname}</setname>",
        f"    <rbf>{'DecoMLC' if info['machine'] == 'avengrgs' else 'DecoMLC156'}</rbf>",
        f"    <mameversion>{mame_version()}</mameversion>",
        f"    <year>{info['year']}</year>",
        f"    <manufacturer>{escape(info['manufacturer'])}</manufacturer>",
        f"    <category>{CATEGORY.get(parent or setname, '')}</category>",
        f"    <rotation>{ROTATION[info['rot']]}</rotation>",
        "    <players>2</players>",
        "    <joystick>8-way</joystick>",
        *note_xml,
        f'    <buttons names="{escape(btn_names, q)}" default="{btn_default}" count="{len(game)}"/>',
        "",
        "    <!-- mod byte (DecoMLC.sv): [0] the DE156 configurations (0 = SH-2), [2:1] orientation,",
        "         [3] the DECO 146, [5:4] the gfx layout (4bpp, 5bpp, 6bpp, acchi), [6] gfx1 thirds of 8 MB -->",
        f'    <rom index="1"><part>{mod:02X}</part></rom>',
        "",
        *ee_xml,
        *hs_xml,
        "    <!-- address: the HPS puts the image in DDR3 and the core copies it to SDRAM (rtl/memory/rom_loader.sv) -->",
        f'    <rom index="0" zip="{"|".join(names)}" md5="none" address="0x30000000">',
        *L,
        "    </rom>",
        "",
        '    <switches default="00,00,00">',
        "        <!-- the board has no DIP switches (a 93C45 EEPROM): read by the core, not the game -->",
        '        <dip name="Flip Screen" bits="0" ids="Off,On"/>',
        "    </switches>",
        "</misterromdescription>",
        "",
    ]

    def safe(t):
        return re.sub(r'[\\/:*?"<>|]', "-", t)
    odir = (out_root / "_alternatives" / ("_" + safe(game_info(text, parent)["title"]))) if parent else out_root
    fname = odir / (safe(info["title"]) + ".mra")
    odir.mkdir(parents=True, exist_ok=True)
    tmp = fname.with_suffix(".mra.tmp")
    tmp.write_text("\n".join(xml), encoding="utf-8", newline="\n")
    got = mra_lib.build_image(str(tmp), [str(p) for p in paths])
    for z in zs:
        z.close()
    if got != img:
        diff = next((i for i in range(min(len(got), len(img))) if got[i] != img[i]), min(len(got), len(img)))
        tmp.unlink()
        sys.exit(f"{setname}: the .mra image differs from the ROM_START image at 0x{diff:x} "
                 f"({len(got)} vs {len(img)} bytes)")
    if write:
        tmp.replace(fname)
        print(f"{setname}: {fname.relative_to(REPO)}, image {len(img)} bytes, identical to ROM_START")
    else:
        tmp.unlink()
        print(f"{setname}: image {len(img)} bytes, identical to ROM_START (not written)")
    return img


def write_regions(setname):
    """debug/<set>_<region>.bin for every region, raw as MAME loads it (before any init
    descramble), and debug/<set>_eeprom.bin: what scripts/mlc_layout.py --image and the
    benches read."""
    text = DRIVER.read_text(encoding="utf-8", errors="replace")
    body = ers.blocks(text)[setname]
    names, paths = zips_for(setname)
    if not paths:
        sys.exit(f"{setname}: no zip found ({' / '.join(names)})")
    zs = [zipfile.ZipFile(p) for p in paths]
    for region in [r[0] for r in REGIONS] + ["eeprom"]:
        recs, unknown = ers.region_records(body, region)
        if unknown:
            sys.exit(f"{setname}: region {region}: unparsed {unknown}")
        if not recs:
            continue
        cap = dict((r[0], r[2]) for r in REGIONS).get(region, 0x80)
        data = load_region(zs, recs, min(region_size(body, region), cap))
        out = REPO / "debug" / f"{setname}_{region}.bin"
        out.write_bytes(data)
        print(f"{out.name}: {len(data):#x} bytes")


def mame_version():
    exe = Path(setting("MAME_DIR") or "C:/Emulation/Emulators/MAME") / (setting("MAME_EXE") or "mame.exe")
    out = subprocess.run([str(exe), "-version"], capture_output=True, text=True, timeout=30).stdout
    m = re.match(r"\s*0\.(\d+)", out)
    if not m:
        sys.exit(f"cannot read the MAME version from {exe}")
    return "%04d" % int(m.group(1))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("sets", nargs="*")
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--release", action="store_true", help="write to releases/ instead of releases/_dev/")
    ap.add_argument("--image", nargs=2, metavar=("SET", "OUT"))
    ap.add_argument("--regions", metavar="SET", help="write debug/<set>_<region>.bin and stop")
    a = ap.parse_args()
    if a.regions:
        write_regions(a.regions)
        return
    layout.check_pkg()
    out_root = REPO / "releases" / ("" if a.release else "_dev")
    if a.image:
        img = build(a.image[0], out_root, write=False)
        if img is False:
            sys.exit(1)
        Path(a.image[1]).write_bytes(img)
        print(a.image[1])
        return
    for s in a.sets or list(SETS):
        build(s, out_root, write=not a.check)


if __name__ == "__main__":
    main()
