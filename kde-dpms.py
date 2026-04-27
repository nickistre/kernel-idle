#!/usr/bin/env python3
"""
kde-dpms: Set display power state via org_kde_kwin_dpms Wayland protocol.

Must run as the Wayland session user (e.g. sddm), not as root.
Usage: kde-dpms.py on|off|standby|suspend
"""
import sys, socket, struct, os

MODES = {'on': 0, 'standby': 1, 'suspend': 2, 'off': 3}


def _pad4(n):
    return (n + 3) & ~3


def _enc_str(s):
    b = s.encode('utf-8') + b'\x00'
    return struct.pack('=I', len(b)) + b.ljust(_pad4(len(b)), b'\x00')


class Wl:
    def __init__(self):
        runtime = os.environ.get('XDG_RUNTIME_DIR', '')
        display = os.environ.get('WAYLAND_DISPLAY', 'wayland-0')
        if not runtime:
            raise RuntimeError('XDG_RUNTIME_DIR not set')
        path = display if display.startswith('/') else os.path.join(runtime, display)
        self.s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.s.connect(path)
        self._nxt = 3   # 1=wl_display, 2=wl_registry, 3+ ours
        self._buf = b''

    def _id(self):
        i = self._nxt; self._nxt += 1; return i

    def _send(self, oid, op, payload=b''):
        sz = 8 + len(payload)
        # Wire format: object_id u32, then (size << 16 | opcode) u32
        self.s.sendall(struct.pack('=IHH', oid, op, sz) + payload)

    def _read_exact(self, n):
        while len(self._buf) < n:
            chunk = self.s.recv(65536)
            if not chunk:
                raise EOFError('Wayland socket closed')
            self._buf += chunk

    def recv_event(self):
        self._read_exact(8)
        oid, word = struct.unpack_from('=II', self._buf)
        size = (word >> 16) & 0xFFFF
        opcode = word & 0xFFFF
        self._read_exact(size)
        data = self._buf[8:size]
        self._buf = self._buf[size:]
        return oid, opcode, data

    def roundtrip(self):
        cb = self._id()
        self._send(1, 0, struct.pack('=I', cb))   # wl_display.sync
        self.s.settimeout(3.0)
        events = []
        try:
            while True:
                e = self.recv_event()
                events.append(e)
                if e[0] == cb:   # wl_callback.done
                    break
        except socket.timeout:
            pass
        self.s.settimeout(None)
        return events

    # wl_display.get_registry → registry lives at fixed id 2
    def get_registry(self):
        self._send(1, 1, struct.pack('=I', 2))

    # wl_registry.bind — new_id without known type needs iface+ver+id
    def bind(self, global_name, iface, ver):
        oid = self._id()
        self._send(2, 0,
                   struct.pack('=I', global_name) +
                   _enc_str(iface) +
                   struct.pack('=II', ver, oid))
        return oid

    # org_kde_kwin_dpms_manager.get(new_id, wl_output)
    def get_dpms(self, mgr, output):
        dpms = self._id()
        self._send(mgr, 0, struct.pack('=II', dpms, output))
        return dpms

    # org_kde_kwin_dpms.set(mode)
    def dpms_set(self, dpms, mode):
        self._send(dpms, 0, struct.pack('=I', mode))


def _parse_globals(events):
    """Extract {interface: global_name} from wl_registry.global events."""
    result = {}
    for oid, op, data in events:
        if oid != 2 or op != 0 or len(data) < 8:
            continue
        gname = struct.unpack_from('=I', data, 0)[0]
        slen  = struct.unpack_from('=I', data, 4)[0]
        iface = data[8:8 + slen - 1].decode('utf-8', errors='replace') if slen > 0 else ''
        result.setdefault(iface, []).append(gname)
    return result


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in MODES:
        print(f"Usage: {sys.argv[0]} on|off|standby|suspend", file=sys.stderr)
        sys.exit(1)

    mode = MODES[sys.argv[1]]

    wl = Wl()
    wl.get_registry()
    events = wl.roundtrip()
    globs = _parse_globals(events)

    if 'org_kde_kwin_dpms_manager' not in globs:
        print("org_kde_kwin_dpms_manager not available — not a KWin Wayland session?",
              file=sys.stderr)
        sys.exit(1)
    if 'wl_output' not in globs:
        print("No wl_output found", file=sys.stderr)
        sys.exit(1)

    mgr = wl.bind(globs['org_kde_kwin_dpms_manager'][0], 'org_kde_kwin_dpms_manager', 1)
    outputs = [wl.bind(g, 'wl_output', 4) for g in globs['wl_output']]
    wl.roundtrip()

    dpms_objs = [wl.get_dpms(mgr, out) for out in outputs]
    wl.roundtrip()   # consume supported / mode / done events

    for dpms in dpms_objs:
        wl.dpms_set(dpms, mode)
    wl.roundtrip()   # flush and wait for compositor to apply


if __name__ == '__main__':
    main()
