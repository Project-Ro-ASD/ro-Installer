"""Real Unix stream protocol tests; no guest daemon or VM required."""
import importlib.util
import json
from pathlib import Path
import socket
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('qga_client', ROOT / 'linux/qga_client.py')
qga = importlib.util.module_from_spec(spec)
spec.loader.exec_module(qga)


class FakeAgent:
    def __init__(self, path, handler, stale=False):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.bind(str(path))
        self.sock.listen()
        self.sock.settimeout(2)
        self.handler = handler
        self.stale = stale
        self.requests = []
        self.errors = []
        self.thread = threading.Thread(target=self.run, daemon=True)
        self.thread.start()

    def run(self):
        try:
            conn, _ = self.sock.accept()
            with conn:
                conn.settimeout(2)
                reader = conn.makefile('rb')
                with reader:
                    while True:
                        line = reader.readline()
                        if not line:
                            return
                        request = json.loads(line.lstrip(b'\xff'))
                        self.requests.append(request)
                        if request['execute'] == 'guest-sync-delimited':
                            if self.stale:
                                conn.sendall(b'broken stale partial data\n{"return":7}\n\xff{"return":8}\n\xffbroken partial' )
                            result = {'return': request['arguments']['id']}
                            payload = b'\xff' + json.dumps(result).encode() + b'\n'
                            # Split the delimiter and payload across reads.
                            conn.sendall(payload[:1])
                            conn.sendall(payload[1:])
                        else:
                            result = self.handler(request)
                            if result is None:
                                return
                            if result == 'hang':
                                time.sleep(.25)
                                return
                            payload = result if isinstance(result, bytes) else json.dumps(result).encode() + b'\n'
                            conn.sendall(payload)
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception as exc:
            self.errors.append(exc)

    def close(self):
        self.thread.join(3)
        self.sock.close()
        if self.errors:
            raise self.errors[0]


class QGATest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='ro-qga-')
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / 'qga.sock'

    def server(self, handler, stale=False):
        server = FakeAgent(self.path, handler, stale)
        self.addCleanup(server.close)
        return server

    def client(self, timeout=1):
        client = qga.Client(str(self.path), time.monotonic() + timeout)
        self.addCleanup(client.close)
        return client

    def test_sync_discards_stale_bytes_and_ping_succeeds(self):
        server = self.server(lambda request: {'return': {}}, stale=True)
        qga.ready(str(self.path), 1)
        self.assertEqual([r['execute'] for r in server.requests], ['guest-sync-delimited', 'guest-ping'])

    def test_missing_socket_readiness_is_bounded(self):
        start = time.monotonic()
        with self.assertRaisesRegex(qga.QGAError, 'did not become ready'):
            qga.ready(str(self.path), .05)
        self.assertLess(time.monotonic() - start, .5)

    def test_readiness_retries_service_reset(self):
        def serve():
            first = self.server(lambda request: None)
            first.thread.join(2)
            first.sock.close()
            self.path.unlink()
            self.server(lambda request: {'return': {}})
        # A first ping reset followed by a new agent is a realistic startup race.
        thread = threading.Thread(target=serve)
        thread.start()
        qga.ready(str(self.path), 3)
        thread.join(2)

    def test_exec_polls_until_success(self):
        polls = []
        def handle(request):
            if request['execute'] == 'guest-exec':
                return {'return': {'pid': 42}}
            polls.append(request)
            return {'return': {'exited': len(polls) > 1, **({'exitcode': 0, 'out-data': 'b2sK'} if len(polls) > 1 else {})}}
        server = self.server(handle)
        client = self.client(3)
        client.wait(client.execute('/bin/sh', ['-c', 'true']))
        self.assertEqual(len(polls), 2)
        self.assertEqual(server.requests[1]['arguments']['path'], '/bin/sh')
        self.assertEqual(polls[0]['arguments']['pid'], 42)

    def test_error_and_malformed_replies_fail(self):
        for reply in [{'error': {'desc': 'disabled'}}, b'not-json\n', {'event': 'bad'}, [], {'return': {'pid': 'bad'}}]:
            with self.subTest(reply=reply):
                server = FakeAgent(self.path, lambda request: reply)
                try:
                    client = self.client()
                    with self.assertRaises(qga.QGAError):
                        client.execute('/bin/true', [])
                    client.close()
                finally:
                    server.close()
                    self.path.unlink()

    def test_nonzero_signal_invalid_output_and_status_fail(self):
        for status in [{'exited': True, 'exitcode': 7}, {'exited': True, 'signal': 9},
                       {'exited': True, 'exitcode': 0, 'err-data': '!!!'}, {'exited': 'yes'}]:
            with self.subTest(status=status):
                server = FakeAgent(self.path, lambda request: {'return': status})
                try:
                    client = self.client()
                    with self.assertRaises(qga.QGAError):
                        client.wait(42)
                    client.close()
                finally:
                    server.close()
                    self.path.unlink()

    def test_disconnect_and_timeout_during_install_fail(self):
        for reply in [None, 'hang', {'return': {'exited': False}}]:
            with self.subTest(reply=reply):
                server = FakeAgent(self.path, lambda request: reply)
                try:
                    client = self.client(.1)
                    with self.assertRaises((OSError, qga.QGAError)):
                        client.wait(42)
                    client.close()
                finally:
                    server.close()
                    self.path.unlink()

    def test_submit_acknowledgement_required_before_disconnect(self):
        self.server(lambda request: {'return': {'pid': 12}})
        self.assertEqual(self.client().execute('/bin/sh', ['-c', 'sleep 2 && systemctl reboot']), 12)


if __name__ == '__main__':
    unittest.main(verbosity=2)
