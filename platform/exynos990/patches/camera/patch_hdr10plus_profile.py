#!/usr/bin/env python3
#
# Restores HDR10+ HEVC recording on the Exynos 990 media stack.
#
# One UI 8.5 and newer ask the encoder for
# OMX_VIDEO_HEVCProfileMain10HDR10Plus (0x2000).  The Exynos 990 OMX
# component that ships in the target vendor partition only advertises
# Main (0x1), Main10 (0x2) and Main10HDR10 (0x1000), so the profile
# enumeration walks past the end of its table, returns OMX_ErrorNoMore
# and Stagefright turns that into -ENODATA (-61).  MediaRecorder then
# reports that the recording could not be saved.
#
# ACodec::setupHEVCEncoderParameters copies the requested profile into a
# stack slot and hands it to the OMX component.  The patch keeps that
# code path and only translates the profile value, so 0x2000 becomes
# 0x1000 while every other HEVC profile is left untouched.
#
# Both places are located by decoding the instructions around them
# instead of matching hardcoded addresses, so the patch stays valid for
# every Exynos 990 target (x1s, y2s, y2slte, z3s, c1s, c2s, r8s), which
# all share the same source media stack, and survives a source firmware
# update that only shifts code around.

from __future__ import annotations

import argparse
import struct
import sys
from typing import List, Optional, Tuple


class ElfError(Exception):
    pass


# ---------------------------------------------------------------------------
# ELF64 reader
# ---------------------------------------------------------------------------


def executable_range(blob: bytes) -> Tuple[int, int, int]:
    """Return (file offset, virtual address, size) of the executable segment."""
    if blob[:4] != b"\x7fELF" or blob[4] != 2 or blob[5] != 1:
        raise ElfError("expected a little endian 64-bit ELF file")

    e_phoff, = struct.unpack_from("<Q", blob, 0x20)
    e_phentsize, e_phnum = struct.unpack_from("<HH", blob, 0x36)

    for index in range(e_phnum):
        off = e_phoff + index * e_phentsize
        p_type, p_flags = struct.unpack_from("<II", blob, off)
        p_offset, p_vaddr, _p_paddr, p_filesz = struct.unpack_from("<QQQQ", blob, off + 8)
        if p_type == 1 and p_flags & 0x1:
            return p_offset, p_vaddr, p_filesz

    raise ElfError("no executable segment found")


# ---------------------------------------------------------------------------
# AArch64 helpers for the handful of instruction forms involved
# ---------------------------------------------------------------------------

PROFILE_HDR10PLUS = 0x2000
PROFILE_HDR10 = 0x1000

COND_NE = 0b00001

CAVE_INSTRUCTIONS = 6

MOVZ_W = 0x52800000
ADRP = 0x90000000
ADD_IMM = 0x91000000
ORR_XZR = 0xAA0003E0
LDR_W = 0xB9400000
STR_W = 0xB9000000
LDUR_W = 0xB8400000
STUR_W = 0xB8000000
SUBS_W_IMM = 0x71000000

LDR_STR_CLASS_MASK = 0xFFC00000
LDUR_STR_CLASS_MASK = 0xFFE00000


def sign_extend(value: int, bits: int) -> int:
    mask = 1 << (bits - 1)
    return (value ^ mask) - mask


def is_movz_w(insn: int, rd: int, value: int) -> bool:
    return (insn & 0xFFE0001F) == (MOVZ_W | rd) \
        and ((insn >> 5) & 0xFFFF) == value \
        and ((insn >> 21) & 0x3) == 0


def is_adrp(insn: int, rd: int) -> bool:
    return (insn & 0x9F00001F) == (ADRP | rd)


def is_add_imm(insn: int, rd: int, rn: int) -> bool:
    return (insn & 0xFF00001F) == (ADD_IMM | rd) and ((insn >> 5) & 0x1F) == rn


def is_mov_reg(insn: int, rd: int, rm: int) -> bool:
    # ORR rd, xzr, xm
    return (insn & 0xFFE0FFE0) == ORR_XZR \
        and (insn & 0x1F) == rd \
        and ((insn >> 16) & 0x1F) == rm


def is_bl(insn: int) -> bool:
    return (insn & 0xFC000000) == 0x94000000


def is_branch(insn: int) -> bool:
    return (insn & 0xFC000000) == 0x14000000


def is_branch_link(insn: int) -> bool:
    return (insn & 0xFC000000) == 0x94000000


def is_branch_cond(insn: int) -> bool:
    return (insn & 0xFF000010) == 0x54000000


def is_branch_compare(insn: int) -> bool:
    # CBZ, CBNZ, TBZ and TBNZ
    return (insn & 0x7F000000) in (0x34000000, 0x36000000)


def decode_branch(insn: int, pc: int) -> Optional[int]:
    if is_branch(insn) or is_branch_link(insn):
        return pc + sign_extend(insn & 0x3FFFFFF, 26) * 4
    if is_branch_cond(insn):
        return pc + sign_extend((insn >> 5) & 0x7FFFF, 19) * 4
    if is_branch_compare(insn):
        return pc + sign_extend((insn >> 5) & 0x7FFFF, 19) * 4
    return None


def decode_ldr_str_w(insn: int) -> Optional[Tuple[bool, int, int, int]]:
    """Decode a 32-bit LDR/STR with an unsigned offset. Returns
    (is_load, rt, rn, byte offset)."""
    if (insn & LDR_STR_CLASS_MASK) not in (LDR_W, STR_W):
        return None
    return ((insn & 0xFFC00000) == LDR_W,
            insn & 0x1F,
            (insn >> 5) & 0x1F,
            ((insn >> 10) & 0xFFF) * 4)


def decode_ldur_w(insn: int) -> Optional[Tuple[bool, int, int, int]]:
    """Decode a 32-bit LDUR/STUR. Returns (is_load, rt, rn, byte offset)."""
    if (insn & LDUR_STR_CLASS_MASK) not in (LDUR_W, STUR_W):
        return None
    if insn & 0x00000C00:
        return None
    return ((insn & 0x00400000) != 0,
            insn & 0x1F,
            (insn >> 5) & 0x1F,
            sign_extend((insn >> 12) & 0x1FF, 9))


def enc_movz_w(rd: int, value: int) -> int:
    return MOVZ_W | (value << 5) | rd


def enc_cmp_w(rd: int, value: int) -> int:
    if 0 <= value < 0x1000:
        return SUBS_W_IMM | (value << 10) | (rd << 5) | 0x1F
    if value % 0x1000 == 0 and (value >> 12) < 0x1000:
        return SUBS_W_IMM | 0x400000 | ((value >> 12) << 10) | (rd << 5) | 0x1F
    raise ElfError("immediate out of range")


def enc_b_cond(cond: int, pc: int, target: int) -> int:
    return 0x54000000 | ((((target - pc) >> 2) & 0x7FFFF) << 5) | cond


def enc_b(pc: int, target: int) -> int:
    return 0x14000000 | (((target - pc) >> 2) & 0x3FFFFFF)


# ---------------------------------------------------------------------------
# Code view
# ---------------------------------------------------------------------------


class Code:
    def __init__(self, blob: bytes) -> None:
        self.blob = bytearray(blob)
        self.offset, self.base, self.size = executable_range(blob)
        if self.size % 4:
            raise ElfError("executable segment is not instruction aligned")
        self.end = self.base + self.size

    def insn(self, address: int) -> int:
        if address < self.base or address + 4 > self.end:
            raise ElfError(f"address 0x{address:x} is outside the executable segment")
        return struct.unpack_from("<I", self.blob, self.offset + address - self.base)[0]

    def insns(self, address: int, count: int) -> List[int]:
        return [self.insn(address + 4 * index) for index in range(count)]

    def store(self, address: int, insn: int) -> None:
        if address < self.base or address + 4 > self.end:
            raise ElfError(f"address 0x{address:x} is outside the executable segment")
        struct.pack_into("<I", self.blob, self.offset + address - self.base, insn)

    def addresses(self):
        for index in range(0, self.size, 4):
            yield self.base + index


# ---------------------------------------------------------------------------
# Site discovery
# ---------------------------------------------------------------------------

# The profile copy has two shapes, one per source platform generation:
#   "ldur"  One UI 9 (API 37) reads the callee frame slot, the ldstub
#           register pair of the caller.
#   "ldr"   One UI 8.5 (API 36) reads a plain stack slot.
# Both are followed by the same "mov x0, x19 / mov w1, #1" OMX call setup,
# which is what tells the copy apart from every other 32-bit load.  The load
# itself is carried over verbatim, so any slot offset the donor uses works.


def find_profile_sites(code: Code) -> List[Tuple[str, int, int]]:
    """Return every (shape, address, load instruction) profile copy candidate."""
    sites = []
    for address in code.addresses():
        if address + 16 > code.end:
            continue
        first, _second, third, fourth = code.insns(address, 4)
        if not is_mov_reg(third, 0, 19) or not is_movz_w(fourth, 1, 1):
            continue
        decoded = decode_ldur_w(first)
        if decoded and decoded[0] and decoded[1] == 2 and decoded[2] == 29 and decoded[3] < 0:
            sites.append(("ldur", address, first))
            continue
        decoded = decode_ldr_str_w(first)
        if decoded and decoded[0] and decoded[1] == 2 and decoded[2] == 0x1F:
            sites.append(("ldr", address, first))
    return sites


def find_cave_blocks(code: Code) -> List[int]:
    """Locate the HDR10+ fatal block that is reused as a code cave.

    The block stores the error code, points x19 at the "ACodec" log tag and
    asserts with level 6.  Nothing reaches it during a healthy setup, so the
    assert message setup can host the trampoline.
    """
    blocks = []
    for address in code.addresses():
        if address + 36 > code.end:
            continue
        insns = code.insns(address, 9)
        if not is_movz_w(insns[0], 8, 2):
            continue
        decoded = decode_ldr_str_w(insns[1])
        if not decoded or decoded[0] or decoded[1] != 8 or decoded[2] != 0x1F:
            continue
        if not is_adrp(insns[2], 19) or not is_add_imm(insns[3], 19, 19):
            continue
        if not is_adrp(insns[4], 2) or not is_add_imm(insns[5], 2, 2):
            continue
        if not is_movz_w(insns[6], 0, 6) or not is_mov_reg(insns[7], 1, 19):
            continue
        if not is_bl(insns[8]):
            continue
        blocks.append(address)
    return blocks


def find_predecessors(code: Code, targets: List[int]) -> List[int]:
    wanted = set(targets)
    found = []
    for address in code.addresses():
        insn = code.insn(address)
        if not (is_branch(insn) or is_branch_link(insn) or is_branch_cond(insn)
                or is_branch_compare(insn)):
            continue
        if decode_branch(insn, address) in wanted:
            found.append(address)
    return found


def find_entries(code: Code, block: int, length: int) -> List[int]:
    """Return every address inside the block that a branch jumps to."""
    entries = set()
    for address in code.addresses():
        insn = code.insn(address)
        if not (is_branch(insn) or is_branch_link(insn) or is_branch_cond(insn)
                or is_branch_compare(insn)):
            continue
        target = decode_branch(insn, address)
        if target is not None and block <= target < block + length:
            entries.add(target)
    return sorted(entries)


class Plan:
    def __init__(self, shape: str, site: int, load: int, cave: int, entries: List[int],
                 normal: int, resume: int) -> None:
        self.shape = shape
        self.site = site
        self.load = load
        self.cave = cave
        self.entries = entries
        self.normal = normal
        self.resume = resume


def plan_patch(code: Code) -> Plan:
    sites = find_profile_sites(code)
    if not sites:
        raise ElfError("the HEVC profile copy in setupHEVCEncoderParameters was not found")
    if len(sites) > 1:
        raise ElfError(f"the HEVC profile copy is ambiguous ({len(sites)} candidates)")

    shape, site, load = sites[0]

    blocks = find_cave_blocks(code)
    if not blocks:
        raise ElfError("the HDR10+ fatal block used as a code cave was not found")
    if len(blocks) > 1:
        raise ElfError(f"the HDR10+ fatal block is ambiguous ({len(blocks)} candidates)")
    block = blocks[0]

    # The cave starts where the fatal block builds the assert message, which
    # is four instructions into the block.
    cave = block + 4 * 4
    if cave + 4 * CAVE_INSTRUCTIONS > code.end:
        raise ElfError("the code cave runs past the end of the executable segment")

    # Every branch that lands inside the block is an entry and has to be
    # redirected, otherwise the check that would have failed the profile would
    # still run into the reused assert code.
    entries = find_entries(code, block, 4 * 9)
    if not entries:
        # Nothing branches into the block, so it is already unreachable and the
        # assert continuation is the only sensible target.
        normal = block + 4 * 9
    else:
        # The last entry is the one the last guard jumps to, so the instruction
        # after that guard is the path taken when no check failed.
        last = max(entries)
        guards = find_predecessors(code, [last])
        for address in guards:
            if is_branch(code.insn(address)):
                raise ElfError(
                    f"the fatal block is entered through an unconditional branch at 0x{address:x}")
        normal = max(guards) + 4

    return Plan(shape, site, load, cave, entries, normal, site + 4)


def cave_body(plan: Plan) -> List[int]:
    # LDUR and LDR share bit 22 with their STUR/STR counterparts, so the store
    # of the translated profile is the original load with that bit flipped.
    store = plan.load ^ 0x00400000

    # Reload the profile, test it, translate 0x2000 to 0x1000 in place and
    # return to the instruction after the patched copy.  Only w2 and the flags
    # are touched, and the copy it replaces defined neither.
    return [
        plan.load,
        enc_cmp_w(2, PROFILE_HDR10PLUS),
        enc_b_cond(COND_NE, plan.cave + 8, plan.cave + 8 + 3 * 4),
        enc_movz_w(2, PROFILE_HDR10),
        store,
        enc_b(plan.cave + 5 * 4, plan.resume),
    ]


def build_writes(plan: Plan) -> List[Tuple[int, int]]:
    body = cave_body(plan)
    if len(body) != CAVE_INSTRUCTIONS:
        raise ElfError("internal error: unexpected trampoline size")

    writes = [(address, enc_b(address, plan.normal)) for address in plan.entries]
    writes.append((plan.site, enc_b(plan.site, plan.cave)))
    writes += [(plan.cave + 4 * index, insn) for index, insn in enumerate(body)]
    return writes


def decode_cmp_w(insn: int) -> Optional[Tuple[int, int]]:
    """Decode a SUBS (immediate) on w registers. Returns (rn, value)."""
    if (insn & 0xFF80001F) != (SUBS_W_IMM | 0x1F) or (insn >> 21) & 0x1:
        return None
    value = (insn >> 10) & 0xFFF
    if (insn >> 22) & 0x1:
        value <<= 12
    return ((insn >> 5) & 0x1F, value)


def read_trampoline(code: Code, cave: int, resume: int) -> Optional[str]:
    """Validate a trampoline at cave and return the profile slot shape it uses."""
    if cave < code.base or cave + 4 * CAVE_INSTRUCTIONS > code.end:
        return None
    load, compare, skip, mov, store, back = code.insns(cave, CAVE_INSTRUCTIONS)

    shape = None
    decoded = decode_ldur_w(load)
    if decoded and decoded[0] and decoded[1] == 2 and decoded[2] == 29 and decoded[3] < 0:
        shape = "ldur"
        mirrored = decode_ldur_w(store)
        if not mirrored or mirrored[0] or mirrored[1] != 2 \
                or mirrored[2] != 29 or mirrored[3] != decoded[3]:
            return None
    else:
        decoded = decode_ldr_str_w(load)
        if not decoded or not decoded[0] or decoded[1] != 2 or decoded[2] != 0x1F:
            return None
        shape = "ldr"
        mirrored = decode_ldr_str_w(store)
        if not mirrored or mirrored[0] or mirrored[1] != 2 \
                or mirrored[2] != 0x1F or mirrored[3] != decoded[3]:
            return None

    if decode_cmp_w(compare) != (2, PROFILE_HDR10PLUS):
        return None
    if not is_branch_cond(skip) or (skip & 0xF) != COND_NE \
            or decode_branch(skip, cave + 8) != cave + 8 + 3 * 4:
        return None
    if not is_movz_w(mov, 2, PROFILE_HDR10):
        return None
    if not is_branch(back) or decode_branch(back, cave + 5 * 4) != resume:
        return None
    return shape


def find_patched_sites(code: Code) -> List[Tuple[int, int]]:
    """Return every (profile copy, trampoline) pair already wired together."""
    found = []
    for address in code.addresses():
        insn = code.insn(address)
        if not is_branch(insn) or is_branch_link(insn):
            continue
        cave = decode_branch(insn, address)
        if cave is None or read_trampoline(code, cave, address + 4) is not None:
            found.append((address, cave))
    return found


SHAPE_NAMES = {"ldur": "frame", "ldr": "stack"}


def patch_file(path: str, expected_shape: Optional[str], dry_run: bool) -> int:
    with open(path, "rb") as handle:
        code = Code(handle.read())

    patched = find_patched_sites(code)
    if patched:
        # A patched copy no longer looks like a profile copy, so any remaining
        # candidate means a partially bridged work directory rather than a
        # completed one.  Patching only half of them would leave HDR10+ broken
        # on whichever path was missed.
        remaining = find_profile_sites(code)
        if remaining:
            raise ElfError(
                f"only {len(patched)} of {len(patched) + len(remaining)} HEVC "
                f"profile copies carry the bridge, starting at 0x{remaining[0][1]:x}"
            )
        site, cave = patched[0]
        print(f"info: HDR10+ profile bridge is already patched at 0x{site:x} "
              f"(trampoline at 0x{cave:x})")
        return 0

    plan = plan_patch(code)
    if expected_shape and plan.shape != expected_shape:
        print(f"warning: the source generation in use keeps the profile in the "
              f"{SHAPE_NAMES[plan.shape]} slot, not the expected "
              f"{SHAPE_NAMES[expected_shape]} slot; patching the layout found",
              file=sys.stderr)

    writes = build_writes(plan)
    for address, insn in writes:
        code.store(address, insn)
    for address, insn in writes:
        if code.insn(address) != insn:
            raise ElfError(f"failed to write 0x{insn:08x} at 0x{address:x}")

    if read_trampoline(code, plan.cave, plan.resume) is None:
        raise ElfError("the trampoline did not verify after being written")
    if not plan.entries:
        print("warning: the fatal block has no branch entry to redirect, "
              "it was already unreachable", file=sys.stderr)

    slot = "frame" if plan.shape == "ldur" else "stack"
    print(f"info: HDR10+ profile bridge: profile 0x2000 -> 0x1000 in the {slot} slot")
    print(f"info: profile copy at 0x{plan.site:x}, trampoline at 0x{plan.cave:x}, "
          f"resume at 0x{plan.resume:x}, fatal block continues at 0x{plan.normal:x}")

    if dry_run:
        return 0

    with open(path, "wb") as handle:
        handle.write(code.blob)
    return 0


def main(argv: List[str]) -> int:
    parser = argparse.ArgumentParser(description="restore HDR10+ recording on Exynos 990")
    parser.add_argument("library", help="path to libstagefright.so")
    parser.add_argument("-n", "--dry-run", action="store_true",
                        help="report the patch without writing the library")
    parser.add_argument("--expect-shape", choices=("frame", "stack"),
                        help="profile slot the source generation is known to use; "
                             "warns when the donor uses the other one")
    args = parser.parse_args(argv)

    shape = {"frame": "ldur", "stack": "ldr"}.get(args.expect_shape)
    try:
        return patch_file(args.library, shape, args.dry_run)
    except (ElfError, OSError, struct.error) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
