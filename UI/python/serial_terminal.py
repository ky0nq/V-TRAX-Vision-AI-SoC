# Share one COM port connection for board data and the on-screen console.
import binascii
from collections import deque
import queue
import re
import threading
import time
import serial
from PySide6.QtCore import QObject, Property, Signal, Slot
from telemetry_protocol import normalize

FIELDS = (
    'pressure', 'angle', 'cnn_valid', 'cnn_age_ms', 'accel_raw', 'brake_raw',
    'sensor_ok', 'drive_enabled', 'reverse', 'command_accel', 'command_brake',
    'command_estop', 'brake_active', 'capture_mode',
)


def decode_state(line):
    if b'HUD4,' not in line:
        return None

    match = re.search(rb'HUD4,-?\d+(?:,-?\d+){13}\*[0-9a-fA-F]{4}(?:\s|$)', line)
    if not match:
        raise ValueError('Malformed HUD4')

    payload, checksum = match.group().strip().rsplit(b'*', 1)
    if binascii.crc_hqx(payload, 0xffff) != int(checksum, 16):
        raise ValueError('HUD4 checksum mismatch')

    values = list(map(int, payload[5:].split(b',')))
    if values[-1] not in (0, 1):
        raise ValueError('Invalid board mode')

    data = dict(zip(FIELDS, values))
    data['capture_mode'] = 'DEMO' if values[-1] else 'TEST'
    state = normalize(data)
    state.update(accel_raw=data['accel_raw'], brake_raw=data['brake_raw'])
    return state


class SerialTerminal(QObject):
    changed = Signal()
    datasetToggleRequested = Signal()

    def __init__(self, port='COM4', baud=115200, enabled=True, console_output=False):
        super().__init__()
        self.port = port
        self.baud = baud
        self.enabled = enabled
        self.console_output = console_output
        self.lock = threading.Lock()
        self.stop = threading.Event()
        self.commands = queue.Queue(maxsize=16)
        self.pending = deque(maxlen=500)
        self.lines = deque(maxlen=250)
        self.latest = None
        self.last_at = 0
        self.valid = 0
        self.invalid = 0
        self._open = False
        self._status = 'Opening ' + port if enabled else 'Demo: serial disabled'
        self._log = ''
        self._last_status = None
        self._last_open = None
        self.thread = threading.Thread(target=self._run, daemon=True, name='hud-com') if enabled else None
        if self.thread:
            self.thread.start()

    logText = Property(str, lambda s: s._log, notify=changed)
    connectionStatus = Property(str, lambda s: s._status, notify=changed)
    portOpen = Property(bool, lambda s: s._open, notify=changed)

    def append(self, text):
        if self.console_output:
            print(text, flush=True)
        with self.lock:
            self.pending.append(text)

    @Slot()
    def clear(self):
        with self.lock:
            self.pending.clear()
            self.lines.clear()
            self._log = ''
        self.changed.emit()

    @Slot(str)
    def send(self, text):
        if text.strip().lower() == 'k':
            self.datasetToggleRequested.emit()
            return

        if not self._open:
            self.append('[PC] Port is not open; command was not sent.')
            return

        try:
            data = text.encode('ascii')
        except UnicodeEncodeError:
            self.append('[PC] Board commands must be ASCII.')
            return

        if not data or len(data) > 64:
            return
        if len(data) > 1:
            data += b'\n'

        try:
            self.commands.put_nowait(data)
        except queue.Full:
            self.append('[PC] Command queue full; command was not sent.')

    def _run(self):
        while not self.stop.is_set():
            connection = None
            try:
                connection = serial.Serial(port=None, baudrate=self.baud, timeout=.1, write_timeout=.2)
                connection.dtr = False
                connection.rts = False
                connection.port = self.port
                connection.open()

                self._open = True
                self._status = self.port + ' open — waiting for HUD4 telemetry'
                self.append('[PC] ' + self.port + ' connected at ' + str(self.baud))
                buffer = bytearray()

                while not self.stop.is_set():
                    try:
                        data = self.commands.get_nowait()
                    except queue.Empty:
                        data = None

                    if data:
                        written = connection.write(data)
                        if written != len(data):
                            raise serial.SerialException('Incomplete command write')
                        self.append('[PC → board] ' + data.decode('ascii').rstrip())

                    buffer.extend(connection.read(min(4096, max(1, connection.in_waiting))))

                    while b'\n' in buffer:
                        line, _, rest = buffer.partition(b'\n')
                        buffer = bytearray(rest)

                        try:
                            state = decode_state(line)
                        except (ValueError, TypeError, KeyError, OverflowError):
                            self.invalid += 1
                            state = None

                        if state is not None:
                            with self.lock:
                                self.latest = state
                                self.last_at = time.monotonic()
                                self.valid += 1
                        elif line.strip():
                            try:
                                text = line.rstrip(b'\r').decode('utf-8')
                            except UnicodeDecodeError:
                                text = line.rstrip(b'\r').decode('cp949', errors='replace')
                            self.append(text)

                    if len(buffer) > 8192:
                        buffer.clear()

            except (serial.SerialException, OSError) as exc:
                self._status = self.port + ': ' + str(exc)
                self.append('[PC] ' + self._status)

            finally:
                self._open = False
                if connection:
                    try:
                        connection.close()
                    except OSError:
                        pass
                with self.lock:
                    self.latest = None
                    self.last_at = 0
                # Never replay commands after reconnecting.
                while True:
                    try:
                        self.commands.get_nowait()
                    except queue.Empty:
                        break

            self.stop.wait(2)

    def current_state(self):
        with self.lock:
            return self.latest if time.monotonic() - self.last_at < 1.2 else None

    def poll(self):
        now = time.monotonic()
        with self.lock:
            has_log = bool(self.pending)
            self.lines.extend(self.pending)
            self.pending.clear()
            if has_log:
                self._log = '\n'.join(self.lines)[-65536:]
            live = now - self.last_at < 1.2
            state = self.latest if live else None

        if self._open:
            self._status = self.port + (' — telemetry connected' if live else ' — waiting for HUD4; check board ELF')

        if has_log or self._last_status != self._status or self._last_open != self._open:
            self._last_status = self._status
            self._last_open = self._open
            self.changed.emit()
        return state

    def close(self):
        self.stop.set()
        if self.thread:
            self.thread.join(timeout=1)