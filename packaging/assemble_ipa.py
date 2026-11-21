#!/usr/bin/env python3
"""assemble_ipa.py — build the unsigned BOTB v2 ipa in GitHub Actions.

Takes the verified v2 seed ipa (split parts reassembled beforehand) and the
freshly compiled BOTBTweak.dylib, and produces the final unsigned ipa in
which ONLY Payload/BOTB.app/BOTBTweak.dylib is replaced. Every other entry
must be byte-identical to the seed — that invariant is verified here and any
deviation fails the build.

Structural checks on the fresh dylib:
  - Mach-O 64-bit arm64 (MH_MAGIC_64, cputype 0x0100000c, filetype MH_DYLIB)
  - LC_ID_DYLIB == @executable_path/BOTBTweak.dylib
  - LC_BUILD_VERSION minos == 16.1
  - required v2 symbols present

Exit code 0 only if everything passes.
"""
import argparse, hashlib, io, struct, sys, zipfile

DYLIB_ENTRY = 'Payload/BOTB.app/BOTBTweak.dylib'
MAIN_EXE_ENTRY = 'Payload/BOTB.app/BOTB'

REQUIRED_SYMBOLS = [
    b'stb_compute_mapping',
    b'stb_normalized_to_image_px',
    b'stb_image_px_to_normalized',
    b'stb_content_rect',
    b'stb_image_px_to_view_point',
    b'stb_normalized_to_view_point',
    b'stb_view_point_to_normalized',
    b'STBOverlayController',
    b'STBHeatmapView',
]

def fail(msg):
    print(f'FAIL: {msg}')
    sys.exit(1)

def sha256(b):
    return hashlib.sha256(b).hexdigest()

def check_dylib(dy):
    if len(dy) < 4096:
        fail(f'dylib suspiciously small: {len(dy)} bytes')
    magic, cputype = struct.unpack_from('<II', dy, 0)
    filetype = struct.unpack_from('<I', dy, 12)[0]
    if magic != 0xFEEDFACF:
        fail(f'dylib magic is {magic:#x}, expected MH_MAGIC_64 0xFEEDFACF')
    if cputype != 0x0100000C:
        fail(f'dylib cputype {cputype:#x}, expected arm64 0x0100000C')
    if filetype != 6:
        fail(f'dylib filetype {filetype}, expected MH_DYLIB (6)')
    ncmds = struct.unpack_from('<I', dy, 16)[0]
    off = 32
    id_name = None
    minos = None
    load_dylibs = []
    for _ in range(ncmds):
        if off + 8 > len(dy):
            fail('load commands run past end of dylib')
        cmd, size = struct.unpack_from('<II', dy, off)
        if cmd == 0xD:  # LC_ID_DYLIB
            name_off = struct.unpack_from('<I', dy, off + 8)[0]
            end = dy.find(b'\x00', off + name_off)
            id_name = dy[off + name_off:end].decode()
        elif cmd == 0x32:  # LC_BUILD_VERSION
            minos = struct.unpack_from('<I', dy, off + 12)[0]
        elif cmd == 0x25:  # LC_VERSION_MIN_IPHONEOS
            minos = struct.unpack_from('<I', dy, off + 8)[0]
        elif cmd == 0xC:  # LC_LOAD_DYLIB
            name_off = struct.unpack_from('<I', dy, off + 8)[0]
            end = dy.find(b'\x00', off + name_off)
            load_dylibs.append(dy[off + name_off:end].decode())
        off += size
    if id_name != '@executable_path/BOTBTweak.dylib':
        fail(f'dylib LC_ID_DYLIB is {id_name!r}, expected @executable_path/BOTBTweak.dylib')
    if minos is None:
        fail('dylib has no LC_BUILD_VERSION')
    if minos != 0x100100:
        fail(f'dylib minos {minos:#x}, expected 16.1 (0x100100)')
    for fw in ('Foundation', 'UIKit', 'CoreGraphics'):
        if not any(f'/System/Library/Frameworks/{fw}.framework/{fw}' in n for n in load_dylibs):
            fail(f'dylib does not link {fw}')
    missing = [s.decode() for s in REQUIRED_SYMBOLS if s not in dy]
    if missing:
        fail(f'dylib missing required symbols: {missing}')
    print(f'  dylib: {len(dy)} bytes, arm64 MH_DYLIB, id={id_name}, minos=16.1, {len(load_dylibs)} load-dylib cmds, symbols OK')

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--seed', required=True)
    ap.add_argument('--dylib', required=True)
    ap.add_argument('--out', required=True)
    args = ap.parse_args()

    fresh_dy = open(args.dylib, 'rb').read()
    print(f'== fresh dylib from {args.dylib} ==')
    check_dylib(fresh_dy)

    seed = zipfile.ZipFile(args.seed)
    names = seed.namelist()
    if DYLIB_ENTRY not in names:
        fail(f'seed ipa has no {DYLIB_ENTRY}')

    print(f'== assembling {args.out} ({len(names)} entries, only {DYLIB_ENTRY} replaced) ==')
    infos = seed.infolist()
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, 'w') as out:
        for info in infos:
            data = fresh_dy if info.filename == DYLIB_ENTRY else seed.read(info.filename)
            zi = zipfile.ZipInfo(info.filename, date_time=info.date_time)
            zi.compress_type = info.compress_type
            zi.external_attr = info.external_attr
            zi.create_system = info.create_system
            out.writestr(zi, data)

    out_bytes = buf.getvalue()
    open(args.out, 'wb').write(out_bytes)

    # ---- verification pass ----
    print('== verification ==')
    outz = zipfile.ZipFile(args.out)
    if outz.testzip() is not None:
        fail('output zip failed integrity test')
    out_names = outz.namelist()
    if out_names != names:
        fail(f'entry list mismatch: out {len(out_names)} vs seed {len(names)}')
    seed_dy = seed.read(DYLIB_ENTRY)
    seed_exe = seed.read(MAIN_EXE_ENTRY)
    changed = []
    for info in infos:
        a = outz.read(info.filename)
        if info.filename == DYLIB_ENTRY:
            if a != fresh_dy:
                fail('dylib entry is not the fresh build')
        else:
            b = seed.read(info.filename)
            if a != b:
                changed.append(info.filename)
    if changed:
        fail(f'{len(changed)} non-dylib entries differ from seed: {changed[:10]}')
    if outz.read(MAIN_EXE_ENTRY) != seed_exe:
        fail('main executable changed (must be byte-identical to seed)')
    n = needle = b'@executable_path/BOTBTweak.dylib\x00'
    if needle not in seed_exe:
        fail('seed main executable lacks LC_LOAD_DYLIB @executable_path/BOTBTweak.dylib')
    print(f'  {len(out_names)}/{len(out_names)} entries valid; all non-dylib entries byte-identical to seed')
    print(f'  main executable byte-identical to seed ({len(seed_exe)} bytes, LC_LOAD_DYLIB present)')
    print(f'  dylib entry == fresh Actions build ({len(fresh_dy)} bytes; seed/verified dylib was {len(seed_dy)} bytes)')
    print(f'== output: {args.out} size={len(out_bytes)} sha256={sha256(out_bytes)} ==')

if __name__ == '__main__':
    main()
