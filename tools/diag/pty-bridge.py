#!/usr/bin/env python3
"""Keep the diag PTY open forever and serve it to QCSuper over TCP.

Usage: sudo python3 pty-bridge.py [/run/diag] [2501]
Then:  qcsuper.py --tcp 127.0.0.1:2501 ...
QCSuper may connect and disconnect any number of times; the PTY is never closed.
"""
import os
import selectors
import socket
import sys
import termios
import tty

PTY = os.path.realpath(sys.argv[1] if len(sys.argv) > 1 else "/run/diag")
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 2501

fd = os.open(PTY, os.O_RDWR | os.O_NOCTTY)
tty.setraw(fd)
attrs = termios.tcgetattr(fd)
attrs[3] &= ~termios.ECHO
termios.tcsetattr(fd, termios.TCSANOW, attrs)

lst = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
lst.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
lst.bind(("127.0.0.1", PORT))
lst.listen(1)

sel = selectors.DefaultSelector()
sel.register(fd, selectors.EVENT_READ, "pty")
sel.register(lst, selectors.EVENT_READ, "listen")
client = None
print(f"holding {PTY}, QCSuper: --tcp 127.0.0.1:{PORT}", flush=True)


def drop():
    global client
    if client:
        try:
            sel.unregister(client)
        except Exception:
            pass
        client.close()
        client = None
        print("client disconnected", flush=True)


while True:
    for key, _ in sel.select():
        if key.data == "listen":
            conn, _ = lst.accept()
            drop()
            client = conn
            sel.register(client, selectors.EVENT_READ, "client")
            print("client connected", flush=True)
        elif key.data == "pty":
            data = os.read(fd, 65536)
            if client and data:
                try:
                    client.sendall(data)
                except OSError:
                    drop()
        elif key.data == "client":
            try:
                data = client.recv(65536)
            except OSError:
                data = b""
            if not data:
                drop()
                continue
            os.write(fd, data)
