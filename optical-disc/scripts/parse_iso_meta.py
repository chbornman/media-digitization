#!/usr/bin/env python3
"""parse_iso_meta.py — extract every metadata field from an ISO9660 image.

Reads the volume descriptors directly out of the image (no mount, no root,
no external tools) and emits JSON. Captures the Primary Volume Descriptor
and any Joliet Supplementary Volume Descriptor: volume label, the four
ISO timestamps (creation / modification / expiration / effective), and the
publisher / data-preparer / application / system identifier strings that
burning software stamps in and that `blkid` and friends throw away.

These dates are the single most valuable clue for undated home video: the
volume-creation timestamp is usually the moment the disc was burned, which
for a camcorder-to-CD transfer is typically days from when it was shot.

Usage: parse_iso_meta.py IMAGE.iso
"""
import json
import sys

SECTOR = 2048
# A volume descriptor set starts at sector 16 (byte 32768).
VD_START = 16 * SECTOR


def clean(b):
    """Strip space/NUL padding from an ISO 'a-characters' field."""
    return b.rstrip(b"\x00 ").decode("latin-1", "replace").strip()


def clean_ucs2(b):
    """Joliet stores identifiers as big-endian UCS-2."""
    try:
        s = b.decode("utf-16-be", "replace")
    except Exception:
        return clean(b)
    s = s.replace("\x00", "").strip()
    # Drop fields that decoded to only replacement/control chars (empty in
    # practice — Joliet pads unused identifier fields with stray bytes).
    if s and all(c == "�" or ord(c) < 0x20 for c in s):
        return ""
    return s


def parse_dt(b):
    """Parse a 17-byte ISO9660 dec-datetime: 'YYYYMMDDHHMMSScc' + tz offset.

    The trailing byte is the offset from GMT in 15-minute intervals (signed).
    All-zero means 'not specified'.
    """
    if len(b) < 17 or b[:16] in (b"0000000000000000", b"\x00" * 16):
        return None
    try:
        digits = b[:16].decode("ascii")
        year, mon, day = digits[0:4], digits[4:6], digits[6:8]
        hh, mm, ss, cs = digits[8:10], digits[10:12], digits[12:14], digits[14:16]
        if year == "0000":
            return None
        tz = int.from_bytes(b[16:17], "little", signed=True)
        tz_min = tz * 15
        sign = "+" if tz_min >= 0 else "-"
        tz_min = abs(tz_min)
        iso = f"{year}-{mon}-{day}T{hh}:{mm}:{ss}.{cs} {sign}{tz_min//60:02d}:{tz_min%60:02d}"
        return iso.strip()
    except Exception:
        return None


def parse_descriptor(sec, joliet=False):
    """Pull the human-meaningful fields out of a volume descriptor sector."""
    c = clean_ucs2 if joliet else clean
    out = {
        "system_id": c(sec[8:40]),
        "volume_id": c(sec[40:72]),
        "publisher_id": c(sec[318:446]),
        "data_preparer_id": c(sec[446:574]),
        "application_id": c(sec[574:702]),
        "copyright_file_id": c(sec[702:739]),
        "abstract_file_id": c(sec[739:776]),
        "bibliographic_file_id": c(sec[776:813]),
        "volume_creation":   parse_dt(sec[813:830]),
        "volume_modification": parse_dt(sec[830:847]),
        "volume_expiration":  parse_dt(sec[847:864]),
        "volume_effective":   parse_dt(sec[864:881]),
    }
    # volume space size (number of logical blocks) at offset 80, both-endian
    try:
        out["volume_space_blocks"] = int.from_bytes(sec[80:84], "little")
        out["logical_block_size"] = int.from_bytes(sec[128:130], "little")
    except Exception:
        pass
    # Drop empty strings so the JSON stays readable.
    return {k: v for k, v in out.items() if v not in ("", None)}


def main():
    if len(sys.argv) != 2:
        print("usage: parse_iso_meta.py IMAGE.iso", file=sys.stderr)
        sys.exit(2)
    result = {"primary": None, "joliet": None}
    with open(sys.argv[1], "rb") as f:
        f.seek(VD_START)
        for _ in range(32):  # bounded scan of the descriptor set
            sec = f.read(SECTOR)
            if len(sec) < SECTOR:
                break
            vd_type = sec[0]
            std_id = sec[1:6]
            if std_id != b"CD001":
                break  # not an ISO9660 volume descriptor area
            if vd_type == 1:  # Primary Volume Descriptor
                result["primary"] = parse_descriptor(sec, joliet=False)
            elif vd_type == 2:  # Supplementary (Joliet uses an escape seq)
                esc = sec[88:120]
                is_joliet = b"%/@" in esc or b"%/C" in esc or b"%/E" in esc
                result["joliet"] = parse_descriptor(sec, joliet=is_joliet)
            elif vd_type == 255:  # Volume Descriptor Set Terminator
                break
    json.dump(result, sys.stdout, indent=2, ensure_ascii=False)
    print()


if __name__ == "__main__":
    main()
