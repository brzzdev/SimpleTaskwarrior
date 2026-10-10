#!/usr/bin/env python3
"""Drives a hidden instance of the dev build through its Debug driver: no cursor, keyboard or focus.

Run from the repo root as `headless.py COMMAND FIXTURE_DIR [ARG...]`. The fixture directory names the
instance, so agents with their own fixtures run in parallel. Prints the driver's JSON reply, most
carrying a `dump`, and exits 1 when it holds an `error`.
"""

import hashlib
import json
import os
import socket
import subprocess
import sys
import time

APP = os.path.join(os.getcwd(), ".build/xcode/Build/Products/Debug/SimpleTaskwarrior Debug.app")
USAGE = """usage: headless.py COMMAND FIXTURE_DIR [ARG...]
  launch                 start a hidden instance for FIXTURE_DIR; run `just build` first
  open REPLICA_DIR       open a Replica
  choose PATH            the next open panel picks PATH without showing
  menu MENU ITEM         a main menu item, e.g. File "Choose Taskrc…"
  context ITEM [ROW]     an item in the header's menu, or in the menu on table row ROW
  click ROW [COLUMN_ID]  the middle of a table cell, the first column by default
  key CHARS [MODIFIER…]  e.g. `key n command`; MODIFIERs: command control option shift
  type TEXT              into the first responder
  sheet BUTTON           a button on the window's sheet
  frame WIDTH HEIGHT     the window's content size
  shot PNG               the window, rendered at the display's scale
  dump                   the window as JSON
  quit"""


def request(name, args):
    match name, args:
        case "choose", [path]:
            return {"choose": {"path": os.path.abspath(path)}}
        case "click", [row, *column] if len(column) <= 1:
            return {"click": {"row": int(row), "column": column[0] if column else None}}
        case "context", [item, *row] if len(row) <= 1:
            return {"contextMenu": {"item": item, "row": int(row[0]) if row else None}}
        case "dump", []:
            return {"dump": {}}
        case "frame", [width, height]:
            return {"frame": {"width": float(width), "height": float(height)}}
        case "key", [characters, *modifiers]:
            return {"key": {"characters": characters, "modifiers": modifiers}}
        case "menu", [menu, item]:
            return {"menu": {"menu": menu, "item": item}}
        case "open", [path]:
            return {"open": {"path": os.path.abspath(path)}}
        case "quit", []:
            return {"quit": {}}
        case "sheet", [button]:
            return {"sheet": {"button": button}}
        case "shot", [path]:
            return {"shot": {"path": os.path.abspath(path)}}
        case "type", [text]:
            return {"type": {"text": text}}
    sys.exit(USAGE)


def launch(path):
    if os.path.exists(path):
        os.remove(path)
    subprocess.run(
        ["open", "-n", "-g", "--env", f"STW_DRIVER_SOCKET={path}", APP,
         "--args", "-ApplePersistenceIgnoreState", "YES"],
        check=True,
    )
    for _ in range(50):
        if os.path.exists(path):
            return
        time.sleep(0.1)
    sys.exit(f"launch: no socket at {path}")


def main():
    if len(sys.argv) < 3:
        sys.exit(USAGE)
    name, directory, args = sys.argv[1], sys.argv[2], sys.argv[3:]
    # Under /tmp, since `sockaddr_un` holds 103 bytes and a scratch directory is often longer.
    digest = hashlib.sha1(os.path.realpath(directory).encode()).hexdigest()[:12]
    path = f"/tmp/stw-{digest}.sock"
    if name == "launch":
        launch(path)
        return
    connection = socket.socket(socket.AF_UNIX)
    connection.settimeout(30)
    connection.connect(path)
    connection.sendall(json.dumps(request(name, args)).encode() + b"\n")
    reply = b""
    while not reply.endswith(b"\n"):
        chunk = connection.recv(65536)
        if not chunk:
            break
        reply += chunk
    sys.stdout.write(reply.decode())
    if "error" in json.loads(reply):
        sys.exit(1)


main()
