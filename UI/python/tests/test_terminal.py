import binascii
from pathlib import Path
import sys,time,unittest
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from PySide6.QtCore import QCoreApplication
from serial_terminal import SerialTerminal, decode_state


def wire(values):
    payload = b'HUD4,' + ','.join(map(str, values)).encode()
    return payload + f'*{binascii.crc_hqx(payload, 0xffff):04X}\r\n'.encode()


READY = [50, -20, 1, 10, 14500, 13000, 1, 1, 1, 3, 0, 0, 0, 1]


class TerminalTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app = QCoreApplication.instance() or QCoreApplication([])

    def test_state_crc_permission_and_pedals(self):
        state = decode_state(wire(READY))
        self.assertTrue(state['drive_enabled'] and state['reverse'])
        self.assertEqual(state['pressure'], 50)
        self.assertEqual(state['command_accel'], 3)

        with self.assertRaises(ValueError):
            decode_state(wire(READY).replace(b'-20', b'-30'))
        self.assertIsNone(decode_state(b'JA1: vehicle armed (NORMAL)'))

        values = READY.copy()
        values[7] = 0
        values[-1] = 0
        values[10] = 4
        values[12] = 1
        state = decode_state(wire(values))
        self.assertFalse(state['drive_enabled'])
        self.assertTrue(state['brake_active'])
        self.assertEqual(state['capture_mode'], 'TEST')
        self.assertEqual(state['command_brake'], 4)

    def test_single_connection_logs_commands_and_stale(self):
        ports = []

        class FakePort:
            def __init__(self, **kwargs):
                self.data = bytearray(b'START\r\n' + wire(READY))
                self.writes = []
                ports.append(self)

            def open(self):
                pass

            def close(self):
                pass

            @property
            def in_waiting(self):
                return min(len(self.data), 9)

            def read(self, n):
                if not self.data:
                    time.sleep(.005)
                    return b''
                result = bytes(self.data[:n])
                del self.data[:n]
                return result

            def write(self, data):
                self.writes.append(data)
                return len(data)

        with patch('serial_terminal.serial.Serial', FakePort):
            terminal = SerialTerminal()
            try:
                deadline = time.monotonic() + 1
                while terminal.valid < 1 and time.monotonic() < deadline:
                    time.sleep(.005)
                self.assertTrue(terminal.poll()['drive_enabled'])
                self.assertIn('START', terminal.logText)
                self.assertEqual(len(ports), 1)

                terminal.send('T')
                terminal.send('E0')
                deadline = time.monotonic() + 1
                while len(ports[0].writes) < 2 and time.monotonic() < deadline:
                    time.sleep(.005)
                self.assertEqual(ports[0].writes, [b'T', b'E0\n'])

                terminal.last_at -= 2
                self.assertIsNone(terminal.poll())
                terminal.clear()
                self.assertEqual(terminal.logText, '')
            finally:
                terminal.close()

    def test_demo_does_not_open_port_or_queue_commands(self):
        with patch('serial_terminal.serial.Serial', side_effect=AssertionError('Must not open')):
            terminal = SerialTerminal(enabled=False)
            terminal.send('T')
            terminal.poll()
            self.assertFalse(terminal.portOpen)
            self.assertTrue(terminal.commands.empty())
            terminal.close()


if __name__ == '__main__':
    unittest.main()