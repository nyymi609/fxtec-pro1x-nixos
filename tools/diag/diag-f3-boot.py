#!/usr/bin/env python3
"""Record the modem's debug messages (F3) from its RF start, for
pro1x.diag.bootCapture: started before rmtfs, so it sees the RF devices
(PA, switches, PAPM/QPOET) being created. RF messages fully on, plus LTE
RRC and MAC RACH.

Talks to pty-bridge.py on TCP 127.0.0.1:2501 (QCSuper must not be connected
at the same time). Writes every frame from the modem to OUT as records:
<u32 len><f64 unix time><frame>. Decode afterwards with the QDB
(QDSP6M.QDB in NON-HLOS.bin, zlib after a 64-byte header).

Usage: python3 diag-f3-boot.py OUT.bin [seconds]
Only standard-library Python is needed.
"""
import socket
import struct
import sys
import time

HOST, PORT = "127.0.0.1", 2501
OUT = sys.argv[1] if len(sys.argv) > 1 else "f3.bin"
DURATION = float(sys.argv[2]) if len(sys.argv) > 2 else 300

# SSID ranges and level masks (bit0 LOW, 1 MED, 2 HIGH, 3 ERROR, 4 FATAL)
MSG_RANGES = [
    # The boot flood off (GNSS, Wi-Fi, power manager ...), so the modem's
    # debug buffer has room for the RF device creation; "set all masks"
    # (subcommand 5) is refused through diag-router (bad length)
    (0, 13, 0), (15, 125, 0), (4500, 4700, 0), (6000, 6100, 0),
    (3007, 3007, 0), (9500, 9500, 0), (9503, 9510, 0),
    (14, 14, 0xFFFFFFFF),        # RF: device creation (PAPM/QPOET, PA, ASM), txlin
    (9501, 9501, 0x1F),          # LTE RRC
    (9502, 9502, 0xFFFFFFFF),    # LTE MAC RACH
]
# LTE log items (equipment id 11): 0xB0C0 RRC OTA, 0xB17F serving meas,
# 0xB180 neighbour meas, 0xB181 reselection, 0xB193 serving meas resp,
# 0xB195 connected neighbour meas, 0xB197 serving cell info
LTE_LOGS = [0x0C0]


def crc16(data):
    crc = 0xFFFF
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ 0x8408 if crc & 1 else crc >> 1
    return crc ^ 0xFFFF


def hdlc(payload):
    payload += struct.pack("<H", crc16(payload))
    payload = payload.replace(b"\x7d", b"\x7d\x5d").replace(b"\x7e", b"\x7d\x5e")
    return payload + b"\x7e"


def unhdlc(frame):
    frame = frame.replace(b"\x7d\x5e", b"\x7e").replace(b"\x7d\x5d", b"\x7d")
    if len(frame) < 3 or crc16(frame[:-2]) != struct.unpack("<H", frame[-2:])[0]:
        return None
    return frame[:-2]


def msg_mask(first, last, level):
    n = last - first + 1
    return struct.pack("<BBHHH", 0x7D, 4, first, last, 0) + struct.pack("<%dI" % n, *([level] * n))


def log_mask(equip, items):
    num = max(items) + 1
    bits = bytearray((num + 7) // 8)
    for i in items:
        bits[i // 8] |= 1 << (i % 8)
    return struct.pack("<BxxxIII", 0x73, 3, equip, num) + bytes(bits)


def main():
    s = socket.create_connection((HOST, PORT))
    s.settimeout(0.5)
    out = open(OUT, "wb", buffering=0)
    for first, last, lvl in MSG_RANGES:
        s.sendall(hdlc(msg_mask(first, last, lvl)))
    s.sendall(hdlc(log_mask(11, LTE_LOGS)))
    buf = b""
    counts = {}
    end = time.monotonic() + DURATION
    last_print = 0
    try:
        while time.monotonic() < end:
            try:
                data = s.recv(1 << 20)
            except socket.timeout:
                data = b""
            if data == b"" and time.monotonic() > end:
                break
            buf += data
            while b"\x7e" in buf:
                raw, buf = buf.split(b"\x7e", 1)
                if not raw:
                    continue
                pkt = unhdlc(raw)
                if pkt is None:
                    continue
                out.write(struct.pack("<Id", len(pkt), time.time()) + pkt)
                counts[pkt[0]] = counts.get(pkt[0], 0) + 1
            if time.time() - last_print > 10:
                last_print = time.time()
                print("frames by type:", {hex(k): v for k, v in sorted(counts.items())}, flush=True)
    except KeyboardInterrupt:
        pass
    finally:
        # switch the messages back off so the modem does not keep producing them
        for first, last, _ in MSG_RANGES:
            try:
                s.sendall(hdlc(msg_mask(first, last, 0)))
            except OSError:
                pass
        out.close()
        print("saved", OUT, {hex(k): v for k, v in sorted(counts.items())})


if __name__ == "__main__":
    main()
