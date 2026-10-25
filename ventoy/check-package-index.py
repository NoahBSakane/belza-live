#!/usr/bin/env python3
"""Explicit, optional resolute package-name validation. No network by default."""
import argparse
import lzma
from pathlib import Path
import re
import sys
import urllib.error
import urllib.request


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--download", action="store_true", help="索引のネットワーク取得を明示的に許可")
    parser.add_argument("--indexes", type=Path, help="main.xz と universe.xz のあるローカルフォルダ")
    args = parser.parse_args()
    if not args.download and args.indexes is None:
        print("SKIP: 索引なし。--download または --indexes が必要です", file=sys.stderr)
        return 77
    names = set()
    try:
        for component in ("main", "universe"):
            if args.indexes is not None:
                raw = (args.indexes / f"{component}.xz").read_bytes()
            else:
                url = f"https://archive.ubuntu.com/ubuntu/dists/resolute/{component}/binary-amd64/Packages.xz"
                with urllib.request.urlopen(url, timeout=30) as response:
                    raw = response.read()
            names.update(re.findall(r"^Package: (\S+)$", lzma.decompress(raw).decode(), re.M))
    except (OSError, EOFError, lzma.LZMAError, UnicodeError, urllib.error.URLError) as error:
        print(f"SKIP: 索引を取得できません: {error}", file=sys.stderr)
        return 77
    bundle = Path(__file__).resolve().parent
    required = set()
    for template in (bundle / "script").glob("*.yaml"):
        source = template.read_text()
        required.update(re.search(r"^  packages: \[(.+)\]$", source, re.M).group(1).split(", "))
        purge = re.search(r"for package in (.+); do", source)
        if purge:
            required.update(purge.group(1).split())
    missing = required - names
    if missing:
        print("FAIL: 索引にないパッケージ: " + ", ".join(sorted(missing)), file=sys.stderr)
        return 1
    print(f"PASS: resolute main/universe に {len(required)} パッケージが存在")
    return 0


if __name__ == "__main__":
    sys.exit(main())
