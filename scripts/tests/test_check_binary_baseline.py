"""scripts/check_binary_baseline.py holds a release executable to its Zig
target: baseline CPU, and no glibc or macOS newer than the target names.
The ELF and Mach-O fixtures are built here byte by byte; the instruction rule
reads disassembler lines as llvm-objdump and GNU objdump print them.
Python 3.9, stdlib only."""
from __future__ import annotations

import struct
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from scripts import check_binary_baseline as cbb


def _elf(needs: list) -> bytes:
    """A 64-bit little-endian ELF whose SHT_GNU_verneed section needs the
    given version names from libc.so.6, with a matching .dynstr."""
    strtab = b"\0libc.so.6\0"
    offsets = []
    for name in needs:
        offsets.append(len(strtab))
        strtab += name.encode() + b"\0"
    aux = b""
    for i, offset in enumerate(offsets):
        last = i == len(offsets) - 1
        aux += struct.pack("<IHHII", 0, 0, 2 + i, offset, 0 if last else 16)
    verneed = struct.pack("<HHIII", 1, len(needs), 1, 16, 0) + aux
    header_size = 64
    dynstr_off = header_size
    verneed_off = dynstr_off + len(strtab)
    shoff = verneed_off + len(verneed)
    sections = [
        struct.pack("<IIQQQQIIQQ", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0),
        struct.pack("<IIQQQQIIQQ", 0, 3, 0, 0, dynstr_off, len(strtab), 0, 0, 1, 0),
        struct.pack("<IIQQQQIIQQ", 0, cbb.SHT_GNU_VERNEED, 0, 0, verneed_off, len(verneed), 1, 1, 8, 0),
    ]
    ident = b"\x7fELF" + bytes([2, 1, 1]) + bytes(9)
    header = ident + struct.pack("<HHIQQQIHHHHHH", 2, 62, 1, 0, 0, shoff, 0, 64, 0, 0, 64, len(sections), 0)
    return header + strtab + verneed + b"".join(sections)


def _macho(minimum: tuple, command: int = cbb.LC_BUILD_VERSION) -> bytes:
    encoded = (minimum[0] << 16) | (minimum[1] << 8) | minimum[2]
    if command == cbb.LC_BUILD_VERSION:
        load = struct.pack("<IIIIII", command, 24, 1, encoded, encoded, 0)
    else:
        load = struct.pack("<IIII", command, 16, encoded, encoded)
    header = struct.pack("<IiiIIIII", cbb.MACHO_MAGIC_64, 0x01000007, 3, 2, 1, len(load), 0, 0)
    return header + load


LLVM_X86 = """
bin/metacodes:\tfile format elf64-x86-64

Disassembly of section .text:

0000000000401000 <main>:
  401000: \tpushq\t%rbp
  401001: \tmovdqu\t(%rsi), %xmm0
  401005: \tpcmpeqb\t%xmm1, %xmm0
  401009: \tcallq\t0x402000 <vfoo_ymm>
  40100e: \tmovl\t$0x1, %eax\t\t# imm = 0x1 <%ymm0>
"""
GNU_X86_AVX2 = """
  401010:\tvmovdqu (%rsi),%ymm0
  401014:\tvpcmpeqb %ymm1,%ymm0,%ymm2
"""
GNU_X86_AVX512 = """
  401020:\tvmovups %zmm0,0x40(%rax)
  401026:\tkortestw %k0,%k0
"""
LLVM_X86_VEX128 = """
  401030: \tvmovups\t(%rdx), %xmm0
"""
X86_VMX = """
  401040: \tvmcall
  401043: \tverw\t%ax
"""
GNU_AARCH64 = """
  400000:\tld1\t{v0.16b}, [x0]
  400004:\tadd\tx0, x0, #0x10
  400008:\tbl\t400100 <z0.d>
  40000c:\tldr\tx1, [x2]  // #16
"""
GNU_AARCH64_SVE = """
  400010:\tld1d\t{z0.d}, p0/z, [x0]
  400014:\tptrue\tp1.s
"""
LLVM_AARCH64_V86 = """
  400020: \tbfdot\tv0.4s, v1.8h, v2.8h
  400024: \tsmmla\tv0.4s, v1.16b, v2.16b
"""


class TargetTest(unittest.TestCase):
    def test_floors_come_from_the_version_suffixes(self) -> None:
        self.assertEqual(cbb.parse_target("aarch64-linux-gnu.2.31"), cbb.Target("aarch64", "linux", (2, 31, 0), None))
        self.assertEqual(cbb.parse_target("x86_64-macos.13.0"), cbb.Target("x86_64", "macos", None, (13, 0, 0)))
        self.assertEqual(cbb.parse_target("x86_64-macos.13.0...15.6-none"), cbb.Target("x86_64", "macos", None, (13, 0, 0)))
        self.assertEqual(cbb.parse_target("x86_64-windows-gnu"), cbb.Target("x86_64", "windows", None, None))

    def test_a_target_the_check_cannot_hold_an_executable_to_is_refused(self) -> None:
        for text in ("riscv64-linux-gnu", "x86_64", "x86_64-linux-musl.1.2", "x86_64-linux.5.10-gnu", "aarch64-linux-gnu.2.x"):
            with self.subTest(target=text), self.assertRaises(cbb.CheckError):
                cbb.parse_target(text)


class FloorTest(unittest.TestCase):
    def test_the_newest_glibc_version_needed_is_read_from_verneed(self) -> None:
        needs = cbb.elf_glibc_needs(_elf(["GLIBC_2.2.5", "GLIBC_2.36", "GLIBC_2.28", "GCC_3.0"]))
        self.assertEqual(needs, [(2, 2, 5), (2, 28, 0), (2, 36, 0)])

    def test_the_minimum_macos_version_is_read_from_either_load_command(self) -> None:
        self.assertEqual(cbb.macho_min_versions(_macho((26, 6, 2))), [(26, 6, 2)])
        self.assertEqual(cbb.macho_min_versions(_macho((10, 12, 0), cbb.LC_VERSION_MIN_MACOSX)), [(10, 12, 0)])

    def check(self, data: bytes, target: str, disassembly: str = LLVM_X86) -> cbb.Report:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "metacodes"
            path.write_bytes(data)
            with mock.patch.object(cbb, "disassemble", return_value=disassembly.splitlines()):
                return cbb.check(path, cbb.parse_target(target), "objdump")

    def test_a_glibc_newer_than_the_target_fails_and_one_at_or_below_passes(self) -> None:
        self.assertEqual(self.check(_elf(["GLIBC_2.28"]), "x86_64-linux-gnu.2.31").findings, [])
        self.assertEqual(self.check(_elf(["GLIBC_2.31"]), "x86_64-linux-gnu.2.31").findings, [])
        report = self.check(_elf(["GLIBC_2.28", "GLIBC_2.36"]), "x86_64-linux-gnu.2.31")
        self.assertEqual(report.findings, ["needs GLIBC_2.36, newer than the target's glibc 2.31"])

    def test_a_macos_newer_than_the_target_fails_and_one_at_or_below_passes(self) -> None:
        self.assertEqual(self.check(_macho((13, 0, 0)), "x86_64-macos.13.0").findings, [])
        report = self.check(_macho((26, 6, 2)), "aarch64-macos.13.0", GNU_AARCH64)
        self.assertEqual(report.findings, ["minimum macOS 26.6.2, newer than the target's macOS 13.0"])

    def test_an_executable_of_another_os_is_an_error_not_a_pass(self) -> None:
        with self.assertRaisesRegex(cbb.CheckError, "is ELF but the target is macos"):
            self.check(_elf(["GLIBC_2.28"]), "x86_64-macos.13.0")
        with self.assertRaisesRegex(cbb.CheckError, "not an ELF, Mach-O or PE"):
            self.check(b"#!/bin/sh\n", "x86_64-linux-gnu.2.31")


class InstructionTest(unittest.TestCase):
    def classes(self, text: str, arch: str) -> dict:
        return {name: count for name, (count, _) in cbb.instruction_findings(text.splitlines(), arch).items()}

    def test_baseline_x86_code_and_annotations_pass(self) -> None:
        self.assertEqual(self.classes(LLVM_X86 + X86_VMX, "x86_64"), {})

    def test_every_vex_or_evex_encoded_x86_instruction_fails(self) -> None:
        self.assertEqual(self.classes(GNU_X86_AVX2, "x86_64"), {"AVX/AVX2 256-bit": 2})
        self.assertEqual(self.classes(GNU_X86_AVX512, "x86_64"), {"AVX-512": 2})
        self.assertEqual(self.classes(LLVM_X86_VEX128, "x86_64"), {"AVX 128-bit (VEX)": 1})

    def test_baseline_aarch64_code_and_annotations_pass(self) -> None:
        self.assertEqual(self.classes(GNU_AARCH64, "aarch64"), {})

    def test_sve_and_armv86_matrix_instructions_fail(self) -> None:
        self.assertEqual(self.classes(GNU_AARCH64_SVE, "aarch64"), {"SVE/SME": 2})
        self.assertEqual(self.classes(LLVM_AARCH64_V86, "aarch64"), {"Armv8.6 BF16/Int8 matrix": 2})

    def test_a_finding_names_the_class_count_and_examples(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "metacodes"
            path.write_bytes(_elf(["GLIBC_2.28"]))
            with mock.patch.object(cbb, "disassemble", return_value=(GNU_X86_AVX2 + GNU_X86_AVX512).splitlines()):
                report = cbb.check(path, cbb.parse_target("x86_64-linux-gnu.2.31"), "objdump")
        self.assertEqual(len(report.findings), 2)
        self.assertTrue(report.findings[0].startswith("2 AVX-512 instruction(s) beyond the x86_64 baseline, e.g. "))
        self.assertIn("vmovups %zmm0,0x40(%rax)", report.findings[0])


class MainTest(unittest.TestCase):
    def test_exit_codes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            clean = Path(directory) / "clean"
            clean.write_bytes(_elf(["GLIBC_2.28"]))
            newer = Path(directory) / "newer"
            newer.write_bytes(_elf(["GLIBC_2.36"]))
            with mock.patch.object(cbb, "disassemble", return_value=LLVM_X86.splitlines()), \
                    mock.patch("sys.stdout"), mock.patch("sys.stderr"):
                self.assertEqual(cbb.main(["--objdump", "objdump", "--target", "x86_64-linux-gnu.2.31", str(clean)]), 0)
                self.assertEqual(cbb.main(["--objdump", "objdump", "--target", "x86_64-linux-gnu.2.31", str(clean), str(newer)]), 1)
                self.assertEqual(cbb.main(["--objdump", "objdump", "--target", "riscv64-linux-gnu", str(clean)]), 2)

    def test_a_missing_disassembler_is_an_error_not_a_pass(self) -> None:
        with mock.patch.object(cbb.shutil, "which", return_value=None), \
                mock.patch.object(cbb.os, "name", "posix"):
            with self.assertRaisesRegex(cbb.CheckError, "no disassembler"):
                cbb.find_disassembler(None)

    def test_a_disassembler_that_prints_no_instructions_is_an_error(self) -> None:
        completed = mock.Mock(returncode=0, stdout="bin/metacodes: file format unknown\n", stderr="")
        with mock.patch.object(cbb.subprocess, "run", return_value=completed), \
                mock.patch.object(cbb, "is_llvm", return_value=False):
            with self.assertRaisesRegex(cbb.CheckError, "printed no instructions"):
                cbb.disassemble("objdump", Path("bin/metacodes"), "x86_64")


if __name__ == "__main__":
    unittest.main()
