#!/usr/bin/env python3
"""A usbmuxd for the QEMU guest, so libimobiledevice tools reach its lockdownd.

  ios-usbmuxd.py [--listen 127.0.0.1:27015] [--mux-port 62079] [--state DIR]

  USBMUXD_SOCKET_ADDRESS=127.0.0.1:27015 ideviceinfo

libimobiledevice never connects to a device itself: it asks usbmuxd for the
device list and to connect to a device port. This speaks the usbmuxd plist
protocol (16-byte header length/version/message/tag, XML plist body) and offers
one device, the guest, as a USB device (ideviceinfo only looks at network
devices with -n). The UDID comes from the guest's lockdownd. Every device
connection goes through the guest kernel's mux relay (bsd/dev/sweet_mux.c,
patch 0100; qemu-sweet.py forwards host 127.0.0.1:62079 to it): send the port
as 2 bytes big endian, read one status byte (0 = connected, else errno), then
the stream is the device port. The relay's sockets belong to the kernel, so
lockdownd treats the connection as USB (pairing allowed) like on an iPhone.
Pair records and the host BUID live in --state (default research/lockdown).
"""
import argparse, os, plistlib, socket, socketserver, struct, threading, time, uuid

PLIST = 8
RESULT_OK, RESULT_BADCOMMAND, RESULT_BADDEV, RESULT_CONNREFUSED = 0, 1, 2, 3
DEVICE_ID = 1
LOCKDOWN = 62078


class Guest:
    def __init__(self, mux_port, state):
        self.mux_port, self.state = mux_port, state
        self.udid = None
        os.makedirs(state, exist_ok=True)

    def connect(self, port, timeout=5):
        s = socket.create_connection(('127.0.0.1', self.mux_port), timeout=timeout)
        try:
            s.sendall(struct.pack('>H', port))
            status = recv_exact(s, 1)[0]
        except (OSError, EOFError):
            s.close()
            raise
        if status:
            s.close()
            raise ConnectionRefusedError(f'guest port {port}: errno {status}')
        return s

    def lockdown_get(self, key):
        """GetValue without a session: lockdownd answers basic keys unpaired."""
        with self.connect(LOCKDOWN, timeout=3) as s:
            body = plistlib.dumps({'Label': 'ios-usbmuxd', 'Request': 'GetValue', 'Key': key})
            s.sendall(struct.pack('>I', len(body)) + body)
            n = struct.unpack('>I', recv_exact(s, 4))[0]
            return plistlib.loads(recv_exact(s, n)).get('Value')

    def present(self):
        if self.udid is None:
            try:
                self.udid = self.lockdown_get('UniqueDeviceID')
            except (OSError, ValueError, struct.error):
                return False
        return self.udid is not None

    def properties(self):
        return {'ConnectionType': 'USB', 'DeviceID': DEVICE_ID, 'LocationID': 0,
                'ProductID': 0x12a8, 'SerialNumber': self.udid, 'ConnectionSpeed': 480000000}

    def buid(self):
        path = os.path.join(self.state, 'SystemConfiguration.plist')
        if not os.path.exists(path):
            with open(path, 'wb') as f:
                plistlib.dump({'SystemBUID': str(uuid.uuid4()).upper()}, f)
        with open(path, 'rb') as f:
            return plistlib.load(f)['SystemBUID']

    def pair_record_path(self, record_id):
        return os.path.join(self.state, os.path.basename(record_id) + '.plist')


def recv_exact(s, n):
    data = b''
    while len(data) < n:
        chunk = s.recv(n - len(data))
        if not chunk:
            raise EOFError
        data += chunk
    return data


def splice(a, b):
    def pump(src, dst):
        try:
            while chunk := src.recv(65536):
                dst.sendall(chunk)
        except OSError:
            pass
        for s in (src, dst):
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
    t = threading.Thread(target=pump, args=(b, a), daemon=True)
    t.start()
    pump(a, b)
    t.join()


class Client(socketserver.BaseRequestHandler):
    def send(self, tag, msg):
        body = plistlib.dumps(msg)
        self.request.sendall(struct.pack('<IIII', 16 + len(body), 1, PLIST, tag) + body)

    def result(self, tag, number):
        self.send(tag, {'MessageType': 'Result', 'Number': number})

    def handle(self):
        guest = self.server.guest
        while True:
            try:
                length, version, message, tag = struct.unpack('<IIII', recv_exact(self.request, 16))
                body = recv_exact(self.request, length - 16)
            except (EOFError, OSError):
                return
            if message != PLIST:
                self.result(tag, RESULT_BADCOMMAND)
                continue
            req = plistlib.loads(body)
            kind = req.get('MessageType')
            if kind == 'ListDevices':
                devices = [{'DeviceID': DEVICE_ID, 'MessageType': 'Attached',
                            'Properties': guest.properties()}] if guest.present() else []
                self.send(tag, {'DeviceList': devices})
            elif kind == 'Listen':
                self.result(tag, RESULT_OK)
                self.listen()
                return
            elif kind == 'Connect':
                port = ((req['PortNumber'] & 0xff) << 8) | ((req['PortNumber'] >> 8) & 0xff)  # network order
                try:
                    if req.get('DeviceID') != DEVICE_ID:
                        raise ConnectionRefusedError
                    dev = guest.connect(port)
                except (OSError, RuntimeError) as e:
                    print(f'connect to guest port {port}: {e}', flush=True)
                    self.result(tag, RESULT_CONNREFUSED)
                    continue
                print(f'connect to guest port {port}', flush=True)
                self.result(tag, RESULT_OK)
                dev.settimeout(None)
                splice(self.request, dev)
                return
            elif kind == 'ReadBUID':
                self.send(tag, {'BUID': guest.buid()})
            elif kind == 'ReadPairRecord':
                path = guest.pair_record_path(req['PairRecordID'])
                if os.path.exists(path):
                    with open(path, 'rb') as f:
                        self.send(tag, {'PairRecordData': f.read()})
                else:
                    self.result(tag, RESULT_BADDEV)
            elif kind == 'SavePairRecord':
                with open(guest.pair_record_path(req['PairRecordID']), 'wb') as f:
                    f.write(req['PairRecordData'])
                print(f'saved pair record {req["PairRecordID"]}', flush=True)
                self.result(tag, RESULT_OK)
            elif kind == 'DeletePairRecord':
                path = guest.pair_record_path(req['PairRecordID'])
                if os.path.exists(path):
                    os.unlink(path)
                self.result(tag, RESULT_OK)
            else:
                print(f'unsupported request {kind}', flush=True)
                self.result(tag, RESULT_BADCOMMAND)

    def listen(self):
        """Attached/Detached events while the client stays connected."""
        guest, attached = self.server.guest, False
        try:
            while True:
                present = guest.present()
                if present != attached:
                    attached = present
                    self.send(0, {'MessageType': 'Attached', 'DeviceID': DEVICE_ID,
                                  'Properties': guest.properties()} if present else
                              {'MessageType': 'Detached', 'DeviceID': DEVICE_ID})
                if not present:
                    guest.udid = None
                time.sleep(2)
        except OSError:
            return


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--listen', default='127.0.0.1:27015')
    ap.add_argument('--mux-port', type=int, default=62079, help="host port forwarded to the guest's mux relay")
    ap.add_argument('--state', default='research/lockdown')
    a = ap.parse_args()
    host, port = a.listen.rsplit(':', 1)
    server = Server((host, int(port)), Client)
    server.guest = Guest(a.mux_port, a.state)
    print(f'usbmuxd on {a.listen}: USBMUXD_SOCKET_ADDRESS={a.listen} ideviceinfo', flush=True)
    server.serve_forever()


if __name__ == '__main__':
    main()
