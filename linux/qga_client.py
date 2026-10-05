#!/usr/bin/env python3
"""Bounded, synchronized Unix-only QGA transport for the QEMU test harness."""
import argparse
import base64
import json
import secrets
import socket
import sys
import time


class QGAError(Exception):
    pass


class Client:
    def __init__(self, path, deadline):
        self.deadline = deadline
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.buffer = b''
        try:
            self._timeout()
            self.sock.connect(path)
            token = secrets.randbits(63)
            self._send({'execute': 'guest-sync-delimited', 'arguments': {'id': token}}, prefix=b'\xff')
            self._synchronize(token)
        except Exception:
            self.close()
            raise

    def _synchronize(self, token):
        # A delimiter resets even a partially delivered stale response. Ignore
        # everything until the delimited JSON return contains our fresh token.
        delimited = False
        while True:
            if b'\xff' in self.buffer:
                self.buffer = self.buffer.rsplit(b'\xff', 1)[1]
                delimited = True
            if delimited and b'\n' in self.buffer:
                line, self.buffer = self.buffer.split(b'\n', 1)
                try:
                    reply = json.loads(line)
                except (ValueError, UnicodeError):
                    reply = None
                if isinstance(reply, dict) and reply.get('return') == token:
                    return
                delimited = False
                continue
            if not delimited:
                self.buffer = b''
            if len(self.buffer) > 8 * 1024 * 1024:
                raise QGAError('QGA synchronization reply too large')
            self.buffer += self._recv()

    def close(self):
        self.sock.close()

    def _timeout(self):
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            raise QGAError('QGA timeout')
        self.sock.settimeout(remaining)

    def _recv(self):
        self._timeout()
        data = self.sock.recv(65536)
        if not data:
            raise QGAError('QGA disconnected unexpectedly')
        return data

    def _send(self, value, prefix=b''):
        self._timeout()
        self.sock.sendall(prefix + json.dumps(value).encode() + b'\n')

    def _reply(self):
        while b'\n' not in self.buffer:
            if len(self.buffer) > 8 * 1024 * 1024:
                raise QGAError('QGA reply too large')
            self.buffer += self._recv()
        line, self.buffer = self.buffer.split(b'\n', 1)
        try:
            reply = json.loads(line)
        except (ValueError, UnicodeError) as exc:
            raise QGAError('Malformed QGA JSON reply') from exc
        if not isinstance(reply, dict):
            raise QGAError('Malformed QGA reply object')
        return reply

    def call(self, command, arguments=None):
        request = {'execute': command}
        if arguments is not None:
            request['arguments'] = arguments
        self._send(request)
        reply = self._reply()
        if 'error' in reply:
            raise QGAError(f'{command}: {reply["error"]}')
        if 'return' not in reply:
            raise QGAError(f'{command}: missing return in reply')
        return reply['return']

    def execute(self, path, arguments):
        result = self.call('guest-exec', {'path': path, 'arg': arguments, 'capture-output': True})
        if not isinstance(result, dict) or type(result.get('pid')) is not int or result['pid'] <= 0:
            raise QGAError('guest-exec: invalid pid')
        return result['pid']

    def wait(self, pid):
        while True:
            result = self.call('guest-exec-status', {'pid': pid})
            if not isinstance(result, dict) or type(result.get('exited')) is not bool:
                raise QGAError('guest-exec-status: invalid status')
            if result['exited']:
                for field, stream in [('out-data', sys.stdout), ('err-data', sys.stderr)]:
                    if field in result:
                        try:
                            stream.write(base64.b64decode(result[field], validate=True).decode(errors='replace'))
                        except (ValueError, TypeError) as exc:
                            raise QGAError('Invalid guest output encoding') from exc
                if type(result.get('exitcode')) is not int or result['exitcode'] != 0:
                    raise QGAError(f'Guest command failed: exitcode={result.get("exitcode")}, signal={result.get("signal")}')
                return
            remaining = self.deadline - time.monotonic()
            if remaining <= 0:
                raise QGAError('Guest command timeout')
            time.sleep(min(1, remaining))


def ready(path, timeout):
    deadline = time.monotonic() + timeout
    last_error = 'socket not ready'
    while time.monotonic() < deadline:
        client = None
        try:
            client = Client(path, min(deadline, time.monotonic() + 5))
            reply = client.call('guest-ping')
            if reply != {}:
                raise QGAError('guest-ping: invalid reply')
            return
        except (OSError, QGAError) as exc:
            last_error = str(exc)
        finally:
            if client:
                client.close()
        time.sleep(min(1, max(0, deadline - time.monotonic())))
    raise QGAError(f'QEMU Guest Agent did not become ready within {timeout:g} seconds: {last_error}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--socket', required=True)
    parser.add_argument('--timeout', type=float, default=30)
    parser.add_argument('operation', choices=['ready', 'exec', 'submit'])
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if not 0 < args.timeout < float('inf'):
        parser.error('--timeout must be finite and positive')
    client = None
    try:
        if args.operation == 'ready':
            ready(args.socket, args.timeout)
        else:
            if not args.command:
                parser.error('exec/submit requires an executable')
            client = Client(args.socket, time.monotonic() + args.timeout)
            pid = client.execute(args.command[0], args.command[1:])
            # submit returns only after the agent acknowledges a valid PID.
            # Used for reboot: disconnect after this acknowledgement is expected.
            if args.operation == 'exec':
                client.wait(pid)
            else:
                print(json.dumps({'pid': pid}))
        return 0
    except (OSError, QGAError) as exc:
        print(f'QGA failure: {exc}', file=sys.stderr)
        return 1
    finally:
        if client:
            client.close()


if __name__ == '__main__':
    sys.exit(main())
