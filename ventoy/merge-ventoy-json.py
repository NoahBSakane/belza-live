#!/usr/bin/env python3
"""Merge only this bundle's ISO entries, preserving unrelated Ventoy settings."""
import argparse
import json
import os
from pathlib import Path
import tempfile

ISO = "/ISO/live/ubuntu-26.04.1-desktop-amd64.iso"
ENTRIES = {
    "persistence": {"image": ISO, "backend": "/ISO/persistence/ubuntu-26.04.1-amd64.dat"},
    "conf_replace": {"iso": ISO, "org": "/boot/grub/grub.cfg", "new": "/ventoy/ubuntu/grub.cfg"},
    "auto_install": {
        "image": ISO,
        "template": [f"/ventoy/script/{name}.yaml" for name in (
            "ubuntu-plus-server", "lubuntu-plus-server", "server-only")],
        "autosel": 0,
        "timeout": 15,
    },
    "menu_alias": {"image": ISO, "alias": "Ubuntu 26.04.1 LTS (Server / Lubuntu / Ubuntu)"},
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("existing", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--in-place", action="store_true")
    args = parser.parse_args()
    try:
        same = args.existing.resolve() == args.output.resolve()
        if args.output.exists():
            same = same or os.path.samefile(args.existing, args.output)
        if same and not args.in_place and not args.dry_run:
            raise ValueError("同じファイルへの書き込みには --in-place が必要です")
        data = json.loads(args.existing.read_text(encoding="utf-8"))
        if not isinstance(data, dict):
            raise ValueError("ventoy.json の最上位はオブジェクトが必要です")
        for key, entry in ENTRIES.items():
            old = data.get(key, [])
            if not isinstance(old, list) or any(not isinstance(item, dict) for item in old):
                raise ValueError(f"{key} はオブジェクトの配列が必要です")
            match_key = "iso" if key == "conf_replace" else "image"
            data[key] = [item for item in old if item.get(match_key) != ISO] + [entry]
        result = json.dumps(data, ensure_ascii=False, indent=2) + "\n"
        if args.dry_run:
            print(result, end="")
        else:
            # Atomic replacement also avoids following output symlinks on write.
            temporary = None
            try:
                with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8",
                                                 dir=args.output.parent, delete=False) as stream:
                    temporary = stream.name
                    stream.write(result)
                os.replace(temporary, args.output)
            finally:
                if temporary and os.path.exists(temporary):
                    os.unlink(temporary)
    except (OSError, ValueError) as error:
        parser.exit(1, f"エラー: {error}\n")


if __name__ == "__main__":
    main()
