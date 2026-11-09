#!/usr/bin/env python3
"""Inject XTRA (predicted orbits) into the modem's GNSS engine over QMI LOC.

  xtra-inject FILE

ModemManager won't on this modem: it checks for XTRA support when it probes
the modem, before the location service is up, and then calls it
unsupported. The modem takes "Inject XTRA Data" (the older "Inject
Predicted Orbits Data" is NotSupported), in parts of 1 KiB. The data stays
in the modem's RAM until it restarts.
"""
import sys

import gi

gi.require_version("Qmi", "1.0")
gi.require_version("Qrtr", "1.0")
from gi.repository import GLib, Qmi, Qrtr  # noqa: E402

PART = 1024
data = open(sys.argv[1], "rb").read()
total = (len(data) + PART - 1) // PART
loop = GLib.MainLoop()
state = {"ok": False}


def fail(msg):
    print("xtra-inject:", msg, file=sys.stderr)
    loop.quit()


def inject(client, i):
    inp = Qmi.MessageLocInjectXtraDataInput.new()
    inp.set_total_size(len(data))
    inp.set_total_parts(total)
    inp.set_part_number(i + 1)
    inp.set_part_data(list(data[i * PART:(i + 1) * PART]))

    def done(c, res):
        try:
            c.inject_xtra_data_finish(res).get_result()
        except GLib.Error as e:
            return fail("part %d/%d: %s" % (i + 1, total, e.message))
        if i + 1 < total:
            inject(c, i + 1)
        else:
            print("xtra-inject: %d bytes in %d parts" % (len(data), total))
            state["ok"] = True
            loop.quit()

    client.inject_xtra_data(inp, 10, None, done)


def got_client(dev, res):
    try:
        inject(dev.allocate_client_finish(res), 0)
    except GLib.Error as e:
        fail("no LOC client: " + e.message)


def opened(dev, res):
    try:
        dev.open_finish(res)
    except GLib.Error as e:
        return fail("open: " + e.message)
    dev.allocate_client(Qmi.Service.LOC, Qmi.CID_NONE, 10, None, got_client)


def created(src, res):
    try:
        dev = Qmi.Device.new_from_node_finish(res)
    except GLib.Error as e:
        return fail("device: " + e.message)
    state["dev"] = dev
    dev.open(Qmi.DeviceOpenFlags.NONE, 15, None, opened)


def bus_ready(src, res):
    bus = Qrtr.Bus.new_finish(res)
    state["bus"] = bus
    node = bus.peek_node(0)
    if not node:
        return fail("no modem on QRTR node 0")
    Qmi.Device.new_from_node(node, None, created)


Qrtr.Bus.new(1000, None, bus_ready)
GLib.timeout_add_seconds(120, lambda: fail("timeout"))
loop.run()
sys.exit(0 if state["ok"] else 1)
