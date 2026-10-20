"""The Python and Node packages carry the SDK version (sdk/VERSION).

build_wheel.py derives the wheel's version from sdk/VERSION, but a source
install (`pip install sdk/python`, `npm install sdk/node`) and
`metacodes.__version__` read the version written into the package files, so
those must agree with it: sdk/VERSION `0.11.0-dev` is PEP 440 `0.11.0.dev0`
and npm `0.11.0-dev.0`, and a release `X.Y.Z` is `X.Y.Z` in both.
"""
from __future__ import annotations

import importlib.util
import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SDK_VERSION = (ROOT / "sdk" / "VERSION").read_text(encoding="utf-8").strip()

_spec = importlib.util.spec_from_file_location("build_wheel", ROOT / "sdk" / "python" / "build_wheel.py")
build_wheel = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(build_wheel)


def npm_version(sdk_version: str) -> str:
    base, dev = re.fullmatch(r"(\d+\.\d+\.\d+)(-dev)?", sdk_version).groups()
    return base + ("-dev.0" if dev else "")


class SdkPackageVersionTest(unittest.TestCase):
    def test_the_python_package_carries_the_sdk_version(self) -> None:
        expected = build_wheel.python_version(SDK_VERSION)
        pyproject = (ROOT / "sdk" / "python" / "pyproject.toml").read_text(encoding="utf-8")
        match = re.search(r'^version = "([^"]+)"$', pyproject, re.M)
        self.assertIsNotNone(match, "sdk/python/pyproject.toml has no version line")
        self.assertEqual(match.group(1), expected)
        init = (ROOT / "sdk" / "python" / "src" / "metacodes" / "__init__.py").read_text(encoding="utf-8")
        match = re.search(r'^__version__ = "([^"]+)"$', init, re.M)
        self.assertIsNotNone(match, "metacodes/__init__.py has no __version__")
        self.assertEqual(match.group(1), expected)

    def test_the_node_package_carries_the_sdk_version(self) -> None:
        package = json.loads((ROOT / "sdk" / "node" / "package.json").read_text(encoding="utf-8"))
        self.assertEqual(package["version"], npm_version(SDK_VERSION))

    def test_the_mappings(self) -> None:
        self.assertEqual(build_wheel.python_version("0.11.0-dev"), "0.11.0.dev0")
        self.assertEqual(build_wheel.python_version("1.2.3"), "1.2.3")
        self.assertEqual(npm_version("0.11.0-dev"), "0.11.0-dev.0")
        self.assertEqual(npm_version("1.2.3"), "1.2.3")


if __name__ == "__main__":
    unittest.main()
