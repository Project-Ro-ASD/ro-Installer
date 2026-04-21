#!/usr/bin/env python3
import argparse
import json
import socket
import sys
import time


ASCII_KEYMAP = {
    " ": "spc",
    "-": "minus",
    "_": "shift-minus",
    "=": "equal",
    "+": "shift-equal",
    "/": "slash",
    "?": "shift-slash",
    ".": "dot",
    ",": "comma",
    ":": "shift-semicolon",
    ";": "semicolon",
    "'": "apostrophe",
    '"': "shift-apostrophe",
    "(": "shift-9",
    ")": "shift-0",
    "[": "bracket_left",
    "]": "bracket_right",
    "{": "shift-bracket_left",
    "}": "shift-bracket_right",
    "\\": "backslash",
    "|": "shift-backslash",
    "!": "shift-1",
    "@": "shift-2",
    "#": "shift-3",
    "$": "shift-4",
    "%": "shift-5",
    "^": "shift-6",
    "&": "shift-7",
    "*": "shift-8",
}


def char_to_qemu_key(char: str) -> str:
    if "a" <= char <= "z":
        return char
    if "A" <= char <= "Z":
        return f"shift-{char.lower()}"
    if "0" <= char <= "9":
        return char
    if char == "\n":
        return "ret"
    if char in ASCII_KEYMAP:
        return ASCII_KEYMAP[char]
    raise ValueError(f"Desteklenmeyen karakter: {char!r}")


def read_qmp_message(sock_file):
    line = sock_file.readline()
    if not line:
        raise RuntimeError("QMP cevabi okunamadi.")
    return json.loads(line)


def qmp_command(sock_file, payload):
    sock_file.write(json.dumps(payload) + "\n")
    sock_file.flush()
    return read_qmp_message(sock_file)


def send_hmp(sock_file, command: str):
    qmp_command(
      sock_file,
      {
          "execute": "human-monitor-command",
          "arguments": {"command-line": command},
      },
    )


def main():
    parser = argparse.ArgumentParser(description="QMP uzerinden guest'e klavye komutu gonderir.")
    parser.add_argument("--socket", required=True, help="QMP unix socket yolu")
    parser.add_argument("--combo", help="Dogrudan sendkey kombinasyonu (ornegin alt-f2)")
    parser.add_argument("--text", help="ASCII metin yaz")
    parser.add_argument("--enter", action="store_true", help="Metin sonunda Enter gonder")
    parser.add_argument("--delay-ms", type=int, default=35, help="Tuslar arasi bekleme (ms)")
    args = parser.parse_args()

    delay_seconds = max(args.delay_ms, 0) / 1000.0

    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.connect(args.socket)
        with sock.makefile("rw", encoding="utf-8", buffering=1) as sock_file:
            read_qmp_message(sock_file)
            qmp_command(sock_file, {"execute": "qmp_capabilities"})

            if args.combo:
                send_hmp(sock_file, f"sendkey {args.combo}")
                time.sleep(delay_seconds)

            if args.text:
                for char in args.text:
                    send_hmp(sock_file, f"sendkey {char_to_qemu_key(char)}")
                    time.sleep(delay_seconds)

            if args.enter:
                send_hmp(sock_file, "sendkey ret")
                time.sleep(delay_seconds)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"[HATA] {exc}", file=sys.stderr)
        sys.exit(1)
