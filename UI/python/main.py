import argparse
import math
import os
import sys
import time
import threading
from pathlib import Path

from PySide6.QtCore import QObject, Property, QTimer, Signal, Slot, QUrl, QEvent, Qt
from PySide6.QtGui import QGuiApplication, QFont, QFontDatabase
from PySide6.QtQml import QQmlApplicationEngine
from PySide6.QtQuick import QQuickWindow, QSGRendererInterface
from PySide6.QtMultimedia import QVideoFrame
from video_receiver import MjpegReceiver, CameraProvider
from capture_receiver import CaptureReceiver
from dataset_capture import DatasetRecorder
from serial_terminal import SerialTerminal
from PySide6.QtMultimedia import QMediaDevices
from mac_discovery import DEFAULT_MAC, normalize_mac
from motion_model import MotionModel


# ESP32-CAM: discover the AP IP using DEFAULT_MAC in mac_discovery.py.
# Set a stream URL here only if you want to bypass MAC discovery.
ESP32_CAM_URL = None

# Dataset settings
SAVE_DIR = Path(r"D:\capture\dataset_test_1008")
START_NUMBER = 10
CAPTURE_INTERVAL = 0.1  # 0.1 sec capture


class HudBackend(QObject):
    changed = Signal()
    cameraFrameChanged = Signal()
    espCameraFrameChanged = Signal()
    boardDemoRequested = Signal()
    datasetToggleRequested = Signal()

    @Slot()
    def requestBoardDemo(self):
        self.boardDemoRequested.emit()

    def __init__(self, vehicle_mode=False, esp_camera_enabled=False):
        super().__init__()
        self._vehicle_mode = vehicle_mode
        self._esp_camera_enabled = esp_camera_enabled
        self._pressure, self._angle, self._connected = 85.0, 23.4, False
        self._camera_url = ""
        self._camera_connected = False
        self._esp_camera_url = ""
        self._esp_camera_connected = False
        self._esp_camera_frames = 0
        self._cnn_fresh = False
        self._pressure_source = "demo"
        self._camera_frames = 0
        self._vehicle_status = "WAITING FOR ZYBO"
        self._emergency_stop = False
        self._accel_raw = 0
        self._brake_raw = 0
        self._accel_level = 0
        self._brake_level = 0
        self._brake_percent = 0.0
        self._reverse = False
        self._drive_enabled = False
        self._drive_known = False
        self._reverse_known = False
        self._brake_known = False
        self._brake_active = False
        self.motion = MotionModel()
        self._pedal_gauge = 0.0
        self._command_known = False
        self._can_send_board_command = False
        self._dataset_active = False
        self._test_mode = False

    testMode = Property(bool, lambda self: self._test_mode, notify=changed)

    def setTestMode(self, enabled):
        if self._test_mode != enabled:
            self._test_mode = enabled
            self.changed.emit()

    @Slot()
    def toggleDataset(self):
        if self._test_mode:
            self.datasetToggleRequested.emit()

    datasetActive = Property(bool, lambda self: self._dataset_active, notify=changed)

    @Slot(bool)
    def setDatasetActive(self, active):
        self._dataset_active = active
        self.changed.emit()

    canSendBoardCommand = Property(bool, lambda self: self._can_send_board_command, notify=changed)

    driveEnabled = Property(bool, lambda self: self._drive_enabled, notify=changed)
    driveKnown = Property(bool, lambda self: self._drive_known, notify=changed)
    reverseKnown = Property(bool, lambda self: self._reverse_known, notify=changed)
    brakeKnown = Property(bool, lambda self: self._brake_known, notify=changed)
    brakeActive = Property(bool, lambda self: self._brake_active, notify=changed)

    @Slot()
    def toggleDemoDrive(self):
        self._drive_known = True
        self._drive_enabled = not self._drive_enabled
        self.changed.emit()

    pedalGauge = Property(float, lambda self: self._pedal_gauge, notify=changed)

    motionSpeed = Property(float, lambda self: self.motion.command_percent, notify=changed)
    motionTarget = Property(float, lambda self: (
        self.motion.TARGET_SPEED[self._accel_level] * 100.0 / self.motion.SPEED_MAX
        if self._drive_enabled and self._drive_known and not self._emergency_stop
        and not self._brake_level and not self.motion.direction_interlock
        and (self._pressure_source == 'demo' or self._command_known) else 0.0
    ), notify=changed)
    brakePercent = Property(float, lambda self: self._brake_percent, notify=changed)
    reverse = Property(bool, lambda self: self._reverse, notify=changed)

    @Slot(float)
    def setDemoBrake(self, value):
        self._brake_percent = max(0, min(100, value))
        self._brake_known = True
        self._brake_active = self._brake_percent > 0
        self.changed.emit()

    @Slot(bool)
    def setDemoReverse(self, value):
        self._reverse = value
        self._reverse_known = True
        self.changed.emit()

    commandKnown = Property(bool, lambda self: self._command_known or self._pressure_source == 'demo', notify=changed)

    def advanceMotion(self, dt, active, paused):
        demo = self._pressure_source == 'demo'
        if demo:
            self._accel_level = min(5, max(0, math.ceil(self._pressure / 20)))
            self._brake_level = min(5, max(0, math.ceil(self._brake_percent / 20)))
        if not paused:
            self.motion.step(
                self._accel_level,
                self._brake_level,
                dt,
                active and (demo or self._command_known) and self._drive_known and self._drive_enabled,
                self._emergency_stop,
                self._reverse,
            )
        self.changed.emit()

    pressure = Property(float, lambda self: self._pressure, notify=changed)
    angle = Property(float, lambda self: self._angle, notify=changed)
    connected = Property(bool, lambda self: self._connected, notify=changed)
    status = Property(str, lambda self: (
        self._vehicle_status if self._vehicle_mode
        else "DANGER" if self._pressure >= 90
        else "WARNING" if self._pressure >= 75
        else "NORMAL"
    ), notify=changed)
    emergencyStop = Property(bool, lambda self: self._emergency_stop, notify=changed)
    accelRaw = Property(int, lambda self: self._accel_raw, notify=changed)
    brakeRaw = Property(int, lambda self: self._brake_raw, notify=changed)
    accelLevel = Property(int, lambda self: self._accel_level, notify=changed)
    brakeLevel = Property(int, lambda self: self._brake_level, notify=changed)

    cameraUrl = Property(str, lambda self: self._camera_url, notify=cameraFrameChanged)
    cameraConnected = Property(bool, lambda self: self._camera_connected, notify=changed)
    espCameraUrl = Property(str, lambda self: self._esp_camera_url, notify=espCameraFrameChanged)
    espCameraConnected = Property(bool, lambda self: self._esp_camera_connected, notify=changed)
    espCameraEnabled = Property(bool, lambda self: self._esp_camera_enabled, notify=changed)
    cnnFresh = Property(bool, lambda self: self._cnn_fresh, notify=changed)
    pressureSource = Property(str, lambda self: self._pressure_source, notify=changed)

    def setCameraFrame(self):
        self._camera_frames += 1
        self._camera_url = f"image://camera/frame/{self._camera_frames}"
        self.cameraFrameChanged.emit()

    def setCameraConnected(self, value):
        if self._camera_connected != value:
            self._camera_connected = value
            self.changed.emit()

    def setEspCameraFrame(self):
        self._esp_camera_frames += 1
        self._esp_camera_url = f"image://esp32camera/frame/{self._esp_camera_frames}"
        self.espCameraFrameChanged.emit()

    def setEspCameraConnected(self, value):
        if self._esp_camera_connected != value:
            self._esp_camera_connected = value
            self.changed.emit()

    def setMetadata(self, valid, source):
        source = str(source)
        if (self._cnn_fresh, self._pressure_source) != (valid, source):
            self._cnn_fresh, self._pressure_source = valid, source
            self.changed.emit()

    @Slot(float, float)
    def updateValues(self, pressure, angle):
        pressure, angle = float(pressure), float(angle)
        if not all(map(math.isfinite, (pressure, angle))):
            raise ValueError("Sensor values must be finite")
        self._pressure = max(0.0, min(100.0, pressure))
        self._angle = max(-90.0, min(90.0, angle))
        self.changed.emit()

    def updateTelemetryValues(self, pressure, angle, capture_mode, drive_enabled):
        if capture_mode == 'DEMO' and drive_enabled is False:
            angle = self._angle
        self.updateValues(pressure, angle)

    def setConnected(self, connected):
        if self._connected != connected:
            self._connected = connected
            self.changed.emit()

    def setVehicleState(self, status, local_estop=False):
        if status is None:
            state = ("WAITING FOR ZYBO", True, 0, 0, 0, 0)
        else:
            stopped = local_estop or status.estop or not status.sensor_ok or not status.steering_ok
            label = "E-STOP" if stopped else "BRAKING" if status.brake_level else "DRIVING"
            state = (
                label, stopped, status.accel_raw, status.brake_raw,
                status.accel_level, status.brake_level,
            )

        old = (
            self._vehicle_status, self._emergency_stop, self._accel_raw,
            self._brake_raw, self._accel_level, self._brake_level,
        )
        if state != old:
            (
                self._vehicle_status, self._emergency_stop, self._accel_raw,
                self._brake_raw, self._accel_level, self._brake_level,
            ) = state
            self.changed.emit()


class EspCameraPresenter(QObject):
    # Publish the newest decoded frame when Qt can process it, without a frame queue.

    def __init__(self, receiver, main_sink, expanded_sink, window, backend):
        super().__init__(window)
        self.receiver = receiver
        self.main_sink = main_sink
        self.expanded_sink = expanded_sink
        self.window = window
        self.backend = backend
        self.last_frame_at = None

    @Slot()
    def present(self):
        latest = self.receiver.take_latest()
        if latest is None:
            return
        image, received_at = latest

        video_frame = QVideoFrame(image)
        if not video_frame.isValid():
            return

        self.main_sink.setVideoFrame(video_frame)
        if self.window.property("cameraExpanded") and self.window.property("expandedCamera") == "esp32":
            self.expanded_sink.setVideoFrame(video_frame)
        self.last_frame_at = received_at
        self.backend.setEspCameraFrame()
        self.backend.setEspCameraConnected(True)


def main():
    parser = argparse.ArgumentParser(description="HDMI capture + background COM4 telemetry and optional terminal")
    parser.add_argument("--serial-port", default="COM4")
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("--capture-device", default="USB3 Video", help="Name substring or index")
    parser.add_argument("--list-devices", action="store_true")
    parser.add_argument("--dataset-dir", type=Path, default=SAVE_DIR)
    parser.add_argument("--dataset-start", type=int, default=START_NUMBER, help="Override START_NUMBER configured at the top of main.py")
    parser.add_argument("--esp32-cam-url")
    parser.add_argument("--esp32-cam-mac", help="Use MAC discovery instead of the configured fixed URL")
    parser.add_argument("--no-esp32-cam", action="store_true")
    parser.add_argument("--demo", action="store_true")
    parser.add_argument("--stats", action="store_true")
    parser.add_argument("--snapshot", type=Path)
    parser.add_argument("--snapshot-delay", type=int, default=2500)
    args = parser.parse_args()

    if args.dataset_start is not None and args.dataset_start < 0:
        parser.error("--dataset-start must be non-negative")
    if args.esp32_cam_mac:
        try:
            normalize_mac(args.esp32_cam_mac)
        except ValueError as exc:
            parser.error(str(exc))
    args.esp32_cam_url = None if args.no_esp32_cam else (
        args.esp32_cam_url or
        ('mac:' + args.esp32_cam_mac if args.esp32_cam_mac else ESP32_CAM_URL or 'mac:' + DEFAULT_MAC)
    )

    app = QGuiApplication(sys.argv)
    if args.list_devices:
        print("Video:", [(i, d.description()) for i, d in enumerate(QMediaDevices.videoInputs())])
        return 0

    os.environ.setdefault("QT_QUICK_CONTROLS_STYLE", "Basic")
    QQuickWindow.setGraphicsApi(
        QSGRendererInterface.Direct3D11 if sys.platform == 'win32' else QSGRendererInterface.OpenGL
    )
    for font in (Path(__file__).parent / 'assets' / 'fonts').glob('*.ttf'):
        QFontDatabase.addApplicationFont(str(font))
    app.setFont(QFont('Rajdhani', 12))

    video = None
    terminal = SerialTerminal(
        args.serial_port, args.baud, enabled=not args.demo,
        console_output=not args.demo,
    )
    engine = QQmlApplicationEngine()
    backend = HudBackend(esp_camera_enabled=bool(args.esp32_cam_url))
    backend.updateValues(0, 0)
    backend.setMetadata(False, 'demo' if args.demo else 'unknown')
    if args.demo:
        backend._drive_known = backend._reverse_known = backend._brake_known = True

    engine.rootContext().setContextProperty('backend', backend)
    engine.rootContext().setContextProperty('sourceMode', 'DEMO' if args.demo else 'SERIAL')
    engine.rootContext().setContextProperty('terminal', terminal)
    engine.rootContext().setContextProperty('captureMode', not args.demo)
    provider = CameraProvider()
    engine.addImageProvider("camera", provider)
    engine.load(QUrl.fromLocalFile(str(Path(__file__).with_name('Hud.qml'))))
    if not engine.rootObjects():
        if video:
            video.close()
        terminal.close()
        return 1
    window = engine.rootObjects()[0]

    def sink(name):
        return window.findChild(QObject, name).property('videoSink')

    if not args.demo:
        video = CaptureReceiver(
            args.capture_device, sink('mainCaptureCamera'),
            sink('expandedCaptureCamera'), backend, window,
        )

    recorder = DatasetRecorder(
        terminal, args.dataset_dir, window,
        start_number=args.dataset_start, interval=CAPTURE_INTERVAL,
    )
    recorder.activeChanged.connect(backend.setDatasetActive)
    backend.datasetToggleRequested.connect(recorder.toggle)
    terminal.datasetToggleRequested.connect(recorder.toggle, Qt.ConnectionType.QueuedConnection)
    if video:
        video.dataset_recorder = recorder

    if not args.demo:
        print('BOARD TERMINAL: type T / c / j / ? / k (TEST dataset on/off) and press Enter. Close the UI to exit.', flush=True)

        def console_input():
            while not terminal.stop.is_set():
                try:
                    command = input()
                except (EOFError, OSError):
                    return
                terminal.send(command.strip())

        threading.Thread(target=console_input, daemon=True, name='cmd-input').start()

    esp = presenter = None
    if args.esp32_cam_url:
        esp = MjpegReceiver(args.esp32_cam_url)
        presenter = EspCameraPresenter(esp, sink('mainEspCamera'), sink('expandedEspCamera'), window, backend)
        esp.notifier.frameReady.connect(presenter.present, Qt.ConnectionType.QueuedConnection)
        esp.start()

    start = last_stats = time.monotonic()
    last_frames = 0
    last_tick = time.monotonic()

    def tick():
        nonlocal last_stats, last_frames, last_tick
        now = time.monotonic()
        dt = now - last_tick
        last_tick = now

        status = terminal.poll()
        backend.setTestMode(not args.demo and status is not None and status.get("capture_mode") == "TEST")
        recorder.check_mode()

        if not args.demo:
            backend.setConnected(status is not None)
            if status:
                backend._accel_raw = status['accel_raw']
                backend._brake_raw = status['brake_raw']
                backend._brake_percent = status['brake']
                backend._reverse = status['reverse'] is True
                backend._reverse_known = status['reverse'] is not None
                backend._drive_enabled = status['drive_enabled'] is True
                backend._drive_known = status['drive_enabled'] is not None
                backend._brake_active = status['brake_active'] is True
                backend._brake_known = status['brake_active'] is not None
                backend._command_known = all(status[k] is not None for k in ('command_accel', 'command_brake', 'command_estop'))
                backend._accel_level = status['command_accel'] or 0
                backend._brake_level = status['command_brake'] or 0
                backend._emergency_stop = status['command_estop'] is True
                backend.updateTelemetryValues(status['pressure'], status['angle'], status['capture_mode'], status['drive_enabled'])
                backend.setMetadata(status['cnn_valid'], status['source'])
                backend.changed.emit()
            else:
                backend._command_known = False
                backend._accel_level = backend._brake_level = 0
                backend._drive_known = backend._reverse_known = backend._brake_known = False
                backend._drive_enabled = backend._brake_active = False
                backend._brake_percent = 0
                backend._emergency_stop = False
                backend.updateValues(0, 0)
                backend.setMetadata(False, 'unknown')

        if args.demo and not window.property('paused') and not window.property('manualMode'):
            backend.updateValues(60 + 36 * math.sin((now - start) * .3), 85 * math.sin((now - start) * .55))
        backend.advanceMotion(dt, args.demo or backend.connected, bool(window.property("paused")))

        if video:
            backend.setCameraConnected(video.last_frame_at is not None and now - video.last_frame_at < 1.2)
        if esp:
            backend.setEspCameraConnected(presenter.last_frame_at is not None and now - presenter.last_frame_at < 1.2)

        if args.stats and now - last_stats >= 2:
            frames = video.frames if video else 0
            print(f"HDMI capture device={args.capture_device} frames={frames} fps={(frames - last_frames) / (now - last_stats):.1f} live={backend.cameraConnected}", flush=True)
            print(f"UART {args.serial_port} valid={terminal.valid} error={terminal.connectionStatus} live={backend.connected}", flush=True)
            if esp:
                print(f"esp32 frames={esp.frames} size={esp.frame_size} url={esp.resolved_url or 'searching MAC'} error={esp.error or 'none'}", flush=True)
            last_stats, last_frames = now, frames

    timer = QTimer()
    timer.setInterval(16)
    timer.timeout.connect(tick)
    timer.start()

    if args.snapshot:
        def snapshot():
            args.snapshot.parent.mkdir(parents=True, exist_ok=True)
            app.exit(0 if window.grabWindow().save(str(args.snapshot)) else 2)

        QTimer.singleShot(args.snapshot_delay, snapshot)

    try:
        return app.exec()
    finally:
        timer.stop()
        terminal.close()
        if video:
            video.close()
        recorder.close()
        if esp:
            esp.close()


if __name__ == '__main__':
    sys.exit(main())