#!/usr/bin/env python3
"""Generate a machine-translated locale file from assets/i18n/en.json.

Requires:
  pip install deep-translator

Example:
  python tool/generate_machine_locale.py --target de --output assets/i18n/de.json
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import time
from pathlib import Path

from deep_translator import GoogleTranslator


TOKEN_PATTERN = re.compile(
    r"(\{[A-Za-z0-9_]+\}|Ro-ASD|Ro-Installer|BTRFS|EFI|UEFI|GRUB2|GRUB|"
    r"SWAP|Live ISO|Dracut|Rsync|Ro-ASD API|BLS|UUID|SELinux|BitLocker|"
    r"Fast Startup|NTFS|EXT4|FAT32|GPT|BIOS|QEMU|VM|xattr|/boot/efi|/boot|"
    r"/mnt|rootflags=subvol=@|linux-swap)"
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", default="assets/i18n/en.json")
    parser.add_argument("--target", required=True, help="Target language code")
    parser.add_argument("--output", required=True, help="Output JSON path")
    parser.add_argument("--batch-size", type=int, default=20)
    parser.add_argument("--sleep-ms", type=int, default=250)
    return parser.parse_args()


def protect(text: str) -> tuple[str, list[str]]:
    tokens: list[str] = []

    def repl(match: re.Match[str]) -> str:
        token = f"ZXQTOKEN{len(tokens)}ZXQ"
        tokens.append(match.group(0))
        return token

    return TOKEN_PATTERN.sub(repl, text), tokens


def restore(text: str, tokens: list[str]) -> str:
    restored = text
    for index, token in enumerate(tokens):
        restored = restored.replace(f"ZXQTOKEN{index}ZXQ", token)
    return restored


def translate_values(
    translator: GoogleTranslator,
    values: list[str],
    batch_size: int,
    sleep_ms: int,
) -> dict[str, str]:
    unique_values = list(dict.fromkeys(values))
    translated: dict[str, str] = {}

    for start in range(0, len(unique_values), batch_size):
        batch = unique_values[start : start + batch_size]
        protected_batch: list[str] = []
        token_bag: list[list[str]] = []
        for item in batch:
            protected, tokens = protect(item)
            protected_batch.append(protected)
            token_bag.append(tokens)

        try:
            results = translator.translate_batch(protected_batch)
        except Exception:
            results = []
            for protected in protected_batch:
                try:
                    results.append(translator.translate(protected))
                except Exception:
                    results.append(protected)
        for original, machine, tokens in zip(batch, results, token_bag):
            translated[original] = restore(machine, tokens)

        print(
            f"translated {min(start + batch_size, len(unique_values))}/{len(unique_values)}",
            flush=True,
        )
        time.sleep(sleep_ms / 1000)

    return translated


def main() -> int:
    args = parse_args()
    source_path = Path(args.source)
    output_path = Path(args.output)

    if not source_path.exists():
        print(f"missing source file: {source_path}", file=sys.stderr)
        return 1

    source = json.loads(source_path.read_text())
    values = [value for value in source.values() if isinstance(value, str) and value]
    translator = GoogleTranslator(source="en", target=args.target)
    translated_values = translate_values(
        translator,
        values,
        batch_size=args.batch_size,
        sleep_ms=args.sleep_ms,
    )

    translated_locale: dict[str, object] = {}
    for key, value in source.items():
        if isinstance(value, str) and value:
            translated_locale[key] = translated_values[value]
        else:
            translated_locale[key] = value

    output_path.write_text(
        json.dumps(translated_locale, ensure_ascii=False, indent=2) + "\n"
    )
    print(f"written {output_path}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
