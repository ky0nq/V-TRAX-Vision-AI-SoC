# Synthetic native HDMI frames: verifies QML sink routing and crop geometry.
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from PySide6.QtCore import QObject, QUrl, QTimer
from PySide6.QtGui import QGuiApplication, QImage, QFontDatabase, QFont
from PySide6.QtQml import QQmlApplicationEngine
from PySide6.QtMultimedia import QVideoFrame
from main import HudBackend
from serial_terminal import SerialTerminal
from capture_receiver import CaptureReceiver

root = Path(__file__).resolve().parents[1]
app = QGuiApplication([])
for font in (root / 'assets/fonts').glob('*.ttf'):
    QFontDatabase.addApplicationFont(str(font))
app.setFont(QFont('Rajdhani', 12))

backend = HudBackend(esp_camera_enabled=True)
backend.setConnected(True)
backend.setMetadata(True, 'raw')
backend._drive_known = backend._reverse_known = backend._brake_known = True
backend._drive_enabled = True
backend._accel_level = 3
backend._command_known = True
backend.updateValues(50, -20)
backend.motion.speed = 42

engine = QQmlApplicationEngine()
console = SerialTerminal(enabled=False)
engine.rootContext().setContextProperty('terminal', console)
engine.rootContext().setContextProperty('backend', backend)
engine.rootContext().setContextProperty('sourceMode', 'SERIAL')
engine.rootContext().setContextProperty('captureMode', True)
engine.load(QUrl.fromLocalFile(str(root / 'Hud.qml')))
assert engine.rootObjects()
window = engine.rootObjects()[0]
window.setProperty('captureCrop', False)


def item(name):
    return window.findChild(QObject, name)


class ReceiverFixture:
    main_sink = item('mainCaptureCamera').property('videoSink')
    expanded_sink = item('expandedCaptureCamera').property('videoSink')
    frames = 0
    backend = backend


receiver = ReceiverFixture()
image = QImage(1280, 720, QImage.Format_RGB32)
image.fill(0x234567)
frame = QVideoFrame(image)

CaptureReceiver.present(receiver, frame)
assert receiver.frames == 1 and receiver.frame_size == (1280, 720)
assert receiver.main_sink.videoFrame().size() == frame.size()
assert receiver.expanded_sink.videoFrame().size() == frame.size()

backend.updateTelemetryValues(50, 80, 'DEMO', False)
assert backend.angle == -20
backend.updateTelemetryValues(50, 30, 'TEST', False)
assert backend.angle == 30
backend.updateValues(50, -20)
backend.changed.emit()


def check():
    try:
        assert item('mainCaptureCamera').property('width') == 178
        assert window.findChild(QObject, 'terminalOverlay') is None
        window.setProperty('captureCrop', True)
        assert item('mainCaptureCamera').property('width') == 890
        assert item('mainCaptureCamera').property('x') == -305.9375
        print('PASS native capture, full/crop layout, TEST/DEMO locked angle')
        app.exit(0)
    except Exception:
        import traceback
        traceback.print_exc()
        app.exit(1)


QTimer.singleShot(800, check)
sys.exit(app.exec())