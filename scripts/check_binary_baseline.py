#!/usr/bin/env python3
"""Fail a release executable that needs more than its target promises.

Without -Dtarget, zig builds for the host: the build runner's CPU, glibc and
macOS. A release built that way runs on machines like the runner and nowhere
older. The x86_64 Linux unit of `release.yml` dry run 40705387727 carried
13,900 AVX-512 instructions because its runner's CPU had them, and the
published 0.8.0 unit needs GLIBC_2.36, so it does not start on Ubuntu 22.04.
`release.yml` therefore builds each CLI unit for an explicit Zig target. This
script holds the built executable to that target string, the same one the
matrix passes as -Dtarget:

- the CPU is the baseline. On x86_64 that means no VEX- or EVEX-encoded
  instruction at all: no AVX, AVX2 or AVX-512. On aarch64 it means no SVE or
  SME and no Armv8.6 BF16 or Int8 matrix instructions.
- a glibc suffix (`aarch64-linux-gnu.2.31`) caps the GLIBC_x.y symbol
  versions an ELF executable needs.
- a macOS version (`x86_64-macos.13.0`) caps the Mach-O minimum OS version.

The instruction check disassembles with `llvm-objdump` or GNU `objdump`, the
first one found (`--objdump` names one). A disassembler that cannot be found
or fails is a failure, not a pass. The glibc and macOS checks read the ELF
version-needs section and the Mach-O load commands directly. Only executables
this repository builds belong here: a vendored binary such as ripgrep selects
its CPU paths at run time, so its static instruction mix says nothing.

Python 3.9, stdlib only.
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import struct
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable, Optional

SHT_GNU_VERNEED = 0x6FFFFFFE
LC_BUILD_VERSION = 0x32
LC_VERSION_MIN_MACOSX = 0x24
MACHO_MAGIC_64 = 0xFEEDFACF
FAT_MAGIC = 0xCAFEBABE
GLIBC_RE = re.compile(r"^GLIBC_(\d+)\.(\d+)(?:\.(\d+))?$")

# An instruction line of llvm-objdump or GNU objdump with --no-show-raw-insn:
# "  401000:\tvmovdqu\t%ymm0, (%rdi)" or "  401000:\tvmovdqu %ymm0,(%rdi)".
INSN_RE = re.compile(r"^\s*[0-9a-f]+:\s+([a-z][a-z0-9.]*)\b(.*)$")
# x86_64, AT&T syntax. A VEX- or EVEX-encoded instruction is a `v` mnemonic
# with a vector register operand (the VMX `vm*` and `verr`/`verw` take none).
X86_RULES = (
    ("AVX-512", re.compile(r"%zmm\d|%k[0-7]\b")),
    ("AVX/AVX2 256-bit", re.compile(r"%ymm\d")),
)
COMMENT_RE = re.compile(r"<[^>]*>")
X86_VEX_OPERAND = re.compile(r"%[xyz]mm\d")
AARCH64_RULES = (
    ("SVE/SME", re.compile(r"\bz\d{1,2}\.[bhsdq]\b|\bp\d{1,2}(?:/[zm]|\.[bhsd])\b|\bza\b")),
)
AARCH64_V86 = frozenset(("bfdot", "bfmmla", "bfmlalb", "bfmlalt", "bfcvt", "bfcvtn", "bfcvtn2",
                         "smmla", "ummla", "usmmla", "usdot", "sudot"))
EXAMPLES = 3


class CheckError(RuntimeError):
    """The executable or its target cannot be checked at all."""


@dataclass(frozen=True)
class Target:
    arch: str
    os: str
    glibc_max: Optional[tuple]
    macos_max: Optional[tuple]


@dataclass
class Report:
    path: Path
    findings: list = field(default_factory=list)
    notes: list = field(default_factory=list)


def parse_version(text: str) -> tuple:
    parts = text.split(".")
    if not 1 <= len(parts) <= 3 or not all(p.isdigit() for p in parts):
        raise CheckError(f"not a version: {text!r}")
    return tuple(int(p) for p in parts) + (0,) * (3 - len(parts))


def show(version: tuple) -> str:
    return ".".join(str(v) for v in (version[:2] if version[2] == 0 else version))


def parse_target(text: str) -> Target:
    """A Zig target string: `<arch>-<os>[.<min>[...<max>]][-<abi>[.<glibc>]]`."""
    parts = text.split("-")
    if len(parts) not in (2, 3) or not all(parts):
        raise CheckError(f"not a Zig target: {text!r}")
    arch = parts[0]
    if arch not in ("x86_64", "aarch64"):
        raise CheckError(f"no baseline rule for architecture {arch!r}")
    os_name, _, os_range = parts[1].partition(".")
    macos_max = None
    if os_range:
        if os_name != "macos":
            raise CheckError(f"an OS version is checked for macOS only: {text!r}")
        macos_max = parse_version(os_range.split("...")[0])
    glibc_max = None
    if len(parts) == 3:
        abi, _, abi_version = parts[2].partition(".")
        if abi_version:
            if abi != "gnu":
                raise CheckError(f"an ABI version is checked for glibc only: {text!r}")
            glibc_max = parse_version(abi_version)
    return Target(arch=arch, os=os_name, glibc_max=glibc_max, macos_max=macos_max)


# ── ELF: the GLIBC versions an executable needs ─────────────────────────────


def elf_glibc_needs(data: bytes) -> list:
    """Every GLIBC_x.y[.z] the ELF's SHT_GNU_verneed section names, sorted."""
    if data[:4] != b"\x7fELF":
        raise CheckError("not an ELF file")
    if data[4] != 2:
        raise CheckError("not a 64-bit ELF file")
    end = "<" if data[5] == 1 else ">"
    shoff, = struct.unpack_from(end + "Q", data, 0x28)
    shentsize, shnum = struct.unpack_from(end + "HH", data, 0x3A)
    sections = []
    for i in range(shnum):
        base = shoff + i * shentsize
        _, sh_type, _, _, sh_offset, sh_size, sh_link, sh_info = struct.unpack_from(end + "IIQQQQII", data, base)
        sections.append((sh_type, sh_offset, sh_size, sh_link, sh_info))
    needs = set()
    for sh_type, offset, _, link, count in sections:
        if sh_type != SHT_GNU_VERNEED:
            continue
        strtab = sections[link][1]
        entry = offset
        for _ in range(count):
            _, vn_cnt, _, vn_aux, vn_next = struct.unpack_from(end + "HHIII", data, entry)
            aux = entry + vn_aux
            for _ in range(vn_cnt):
                _, _, _, vna_name, vna_next = struct.unpack_from(end + "IHHII", data, aux)
                name_end = data.index(b"\0", strtab + vna_name)
                needs.add(data[strtab + vna_name:name_end].decode("ascii", "replace"))
                aux += vna_next
            entry += vn_next
    versions = []
    for name in needs:
        match = GLIBC_RE.match(name)
        if match:
            versions.append(tuple(int(g or 0) for g in match.groups()))
    return sorted(versions)


# ── Mach-O: the minimum OS version ──────────────────────────────────────────


def macho_min_versions(data: bytes) -> list:
    """The minimum macOS version of each slice (fat files have several)."""
    magic, = struct.unpack_from(">I", data, 0)
    if magic == FAT_MAGIC:
        count, = struct.unpack_from(">I", data, 4)
        offsets = [struct.unpack_from(">iiIII", data, 8 + 20 * i)[2] for i in range(count)]
    else:
        offsets = [0]
    found = []
    for offset in offsets:
        magic, = struct.unpack_from("<I", data, offset)
        if magic != MACHO_MAGIC_64:
            raise CheckError("not a 64-bit Mach-O file")
        ncmds, = struct.unpack_from("<I", data, offset + 16)
        cursor = offset + 32
        version = None
        for _ in range(ncmds):
            cmd, size = struct.unpack_from("<II", data, cursor)
            if cmd == LC_BUILD_VERSION:
                version = struct.unpack_from("<I", data, cursor + 12)[0]
            elif cmd == LC_VERSION_MIN_MACOSX:
                version = struct.unpack_from("<I", data, cursor + 8)[0]
            cursor += size
        if version is None:
            raise CheckError("a Mach-O slice records no minimum macOS version")
        found.append((version >> 16, (version >> 8) & 0xFF, version & 0xFF))
    return found


# ── Instructions ────────────────────────────────────────────────────────────


def find_disassembler(explicit: Optional[str]) -> str:
    if explicit:
        return explicit
    candidates = ["llvm-objdump", "objdump"]
    if os.name == "nt":
        candidates.append(str(Path(os.environ.get("ProgramFiles", r"C:\Program Files")) / "LLVM" / "bin" / "llvm-objdump.exe"))
    for name in candidates:
        found = shutil.which(name) or (name if Path(name).is_file() else None)
        if found:
            return found
    raise CheckError("no disassembler: install llvm-objdump or binutils' objdump, or pass --objdump")


def disassemble(objdump: str, path: Path, arch: str) -> Iterable[str]:
    argv = [objdump, "-d", "--no-show-raw-insn"]
    if arch == "aarch64" and is_llvm(objdump):
        # LLVM decodes only the extensions it is told about; GNU decodes all.
        argv.append("--mattr=+sve,+sve2,+sme,+bf16,+i8mm")
    argv.append(str(path))
    completed = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, errors="replace", check=False)
    if completed.returncode != 0:
        raise CheckError(f"{objdump} failed on {path} ({completed.returncode}): {completed.stderr.strip()[:300]}")
    lines = completed.stdout.splitlines()
    if not any(INSN_RE.match(line) for line in lines[:2000]):
        raise CheckError(f"{objdump} printed no instructions for {path}")
    return lines


def is_llvm(objdump: str) -> bool:
    try:
        out = subprocess.run([objdump, "--version"], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, check=False).stdout
    except OSError:
        return False
    return "LLVM" in out


def instruction_findings(lines: Iterable[str], arch: str) -> dict:
    """{class: (count, [example lines])} of instructions beyond the baseline."""
    found: dict = {}

    def hit(name: str, line: str) -> None:
        count, examples = found.get(name, (0, []))
        if len(examples) < EXAMPLES:
            examples.append(line.strip())
        found[name] = (count + 1, examples)

    for line in lines:
        match = INSN_RE.match(line)
        if not match:
            continue
        mnemonic = match.group(1)
        # Drop the disassembler's annotations (`<symbol>`, `# 0x..` on x86,
        # `// =0x..` on aarch64), so a symbol name is never read as a register.
        operands = COMMENT_RE.sub("", match.group(2))
        operands = operands.split("#")[0] if arch == "x86_64" else operands.split("//")[0]
        if arch == "x86_64":
            for name, rule in X86_RULES:
                if rule.search(operands):
                    hit(name, line)
                    break
            else:
                if mnemonic.startswith("v") and X86_VEX_OPERAND.search(operands):
                    hit("AVX 128-bit (VEX)", line)
        else:
            for name, rule in AARCH64_RULES:
                if rule.search(operands):
                    hit(name, line)
                    break
            else:
                if mnemonic in AARCH64_V86:
                    hit("Armv8.6 BF16/Int8 matrix", line)
    return found


# ── The check ───────────────────────────────────────────────────────────────


def check(path: Path, target: Target, objdump: str) -> Report:
    report = Report(path)
    data = path.read_bytes()
    if data[:4] == b"\x7fELF":
        if target.os != "linux":
            raise CheckError(f"{path} is ELF but the target is {target.os}")
        versions = elf_glibc_needs(data)
        newest = versions[-1] if versions else None
        report.notes.append(f"needs GLIBC_{show(newest)}" if newest else "needs no versioned glibc symbol")
        if target.glibc_max is not None and newest is not None and newest > target.glibc_max:
            report.findings.append(f"needs GLIBC_{show(newest)}, newer than the target's glibc {show(target.glibc_max)}")
    elif data[:4] in (b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe"):
        if target.os != "macos":
            raise CheckError(f"{path} is Mach-O but the target is {target.os}")
        for minimum in macho_min_versions(data):
            report.notes.append(f"minimum macOS {show(minimum)}")
            if target.macos_max is not None and minimum > target.macos_max:
                report.findings.append(f"minimum macOS {show(minimum)}, newer than the target's macOS {show(target.macos_max)}")
    elif data[:2] == b"MZ":
        if target.os != "windows":
            raise CheckError(f"{path} is PE but the target is {target.os}")
    else:
        raise CheckError(f"{path} is not an ELF, Mach-O or PE executable")
    for name, (count, examples) in sorted(instruction_findings(disassemble(objdump, path, target.arch), target.arch).items()):
        report.findings.append(f"{count} {name} instruction(s) beyond the {target.arch} baseline, e.g. " + " | ".join(examples))
    return report


def main(argv: Optional[list] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--target", required=True, help="the Zig target the executables were built for, e.g. aarch64-linux-gnu.2.31")
    parser.add_argument("--objdump", help="disassembler to use (default: llvm-objdump, then objdump)")
    parser.add_argument("executables", nargs="+", type=Path)
    args = parser.parse_args(argv)
    try:
        target = parse_target(args.target)
        objdump = find_disassembler(args.objdump)
        reports = [check(path, target, objdump) for path in args.executables]
    except (CheckError, OSError, struct.error, ValueError) as error:
        print(f"check_binary_baseline: {error}", file=sys.stderr)
        return 2
    failed = False
    for report in reports:
        status = "FAIL" if report.findings else "ok"
        print(f"{status} {report.path} ({args.target}; {'; '.join(report.notes) or 'baseline CPU'})")
        for finding in report.findings:
            print(f"  - {finding}")
        failed = failed or bool(report.findings)
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
