import os
os.environ["QT_QPA_PLATFORM"] = "offscreen"
os.environ["QT_QUICK_BACKEND"] = "software"
import ast, time, threading, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
os.chdir(Path(__file__).resolve().parents[1])
from unittest.mock import patch
from PySide6.QtCore import QObject, QUrl, Qt, QBuffer, QIODevice, QMetaObject
from PySide6.QtGui import QGuiApplication, QImage, QColor
from PySide6.QtQml import QQmlApplicationEngine
from PySide6.QtMultimedia import QVideoFrame
from serial_terminal import SerialTerminal
from dataset_capture import DatasetRecorder
from main import HudBackend
from capture_receiver import CaptureReceiver

for name in ("main.py", "serial_terminal.py", "capture_receiver.py", "dataset_capture.py"):
    ast.parse(Path(name).read_text(encoding="utf-8"))

app = QGuiApplication([])
terminal = SerialTerminal(enabled=False)
backend = HudBackend()
recorder = DatasetRecorder(terminal, Path("unused"))
recorder.activeChanged.connect(backend.setDatasetActive)
terminal.datasetToggleRequested.connect(recorder.toggle, Qt.ConnectionType.QueuedConnection)

image = QImage(1280, 720, QImage.Format_RGB32)
image.fill(QColor("blue"))
image.setPixelColor(440, 142, QColor("red"))
image.setPixelColor(695, 397, QColor("green"))
frame = QVideoFrame(image)

saved = []
original_save = QImage.save


def save_memory(img, path, fmt):
    buffer = QBuffer()
    buffer.open(QIODevice.WriteOnly)
    assert original_save(img, buffer, fmt)
    decoded = QImage.fromData(buffer.data(), "PNG")
    assert (decoded.width(), decoded.height()) == (256, 256)
    assert decoded.pixelColor(0, 0) == QColor("red")
    assert decoded.pixelColor(255, 255) == QColor("green")
    saved.append(path)
    return True


def mode(value):
    with terminal.lock:
        terminal.latest = {"capture_mode": value}
        terminal.last_at = time.monotonic()


def flush():
    recorder.pending.join()
    recorder.check_mode()


try:
    with patch.object(Path, "mkdir"), \
         patch.object(Path, "write_text", side_effect=AssertionError("No session JSON should be written")), \
         patch.object(QImage, "save", save_memory):
        terminal.send("k")
        app.processEvents()
        assert not recorder.active and terminal.commands.empty()

        mode("DEMO")
        terminal.send("k")
        app.processEvents()
        assert not recorder.active

        mode("TEST")
        thread = threading.Thread(target=lambda: terminal.send("k"))
        thread.start()
        thread.join()
        assert not recorder.active
        app.processEvents()
        assert recorder.active and backend.datasetActive

        recorder.capture(frame)
        recorder.capture(frame)
        flush()
        assert recorder.count == 1 and len(saved) == 1
        assert Path(saved[0]).is_absolute()
        assert "[DATASET] Saved: " + saved[0] in terminal.pending

        recorder.last_capture -= .11
        recorder.capture(frame)
        flush()
        assert recorder.count == 2
        assert Path(saved[0]).name == 'capture_000000.png'
        assert Path(saved[1]).name == 'capture_000001.png'

        directory = recorder.directory
        terminal.send("k")
        app.processEvents()
        assert not recorder.active
        terminal.send("k")
        app.processEvents()
        assert recorder.active and recorder.directory == directory
        assert recorder.next_number == 2

        mode("DEMO")
        recorder.capture(frame)
        flush()
        assert not recorder.active and len(saved) == 2

        mode("TEST")
        recorder.toggle()
        terminal.last_at -= 2
        recorder.capture(frame)
        assert not recorder.active

        mode("TEST")
        recorder.toggle()
        recorder.capture(QVideoFrame(QImage(640, 480, QImage.Format_RGB32)))
        assert not recorder.active

        mode("TEST")
        recorder.toggle()
        with patch.object(QImage, "save", return_value=False):
            recorder.capture(frame)
            flush()
        assert not recorder.active and any("Save failed" in x for x in terminal.pending)

        with patch.object(Path, "mkdir", side_effect=OSError("denied")):
            recorder.toggle()
            assert not recorder.active

    for requested, existing, expected in (
        (163654, [], 163654),
        (None, ['capture_163654.png', 'manual_163655.png', 'other_999999.png'], 163656),
        (10, ['capture_163654.png'], 163655),
    ):
        other = DatasetRecorder(terminal, Path('unused'), start_number=requested)
        try:
            mode('TEST')
            with patch.object(Path, 'mkdir'), \
                 patch.object(Path, 'write_text', side_effect=AssertionError('No session JSON should be written')), \
                 patch.object(Path, 'rglob', return_value=iter(map(Path, existing))):
                other.toggle()
                assert other.next_number == expected
                other.stop('test')
                other.toggle()
                assert other.next_number == expected
        finally:
            other.close()

    engine = QQmlApplicationEngine()
    engine.rootContext().setContextProperty("terminal", terminal)
    engine.rootContext().setContextProperty("backend", backend)
    engine.rootContext().setContextProperty("sourceMode", "SERIAL")
    engine.rootContext().setContextProperty("captureMode", True)
    engine.load(QUrl.fromLocalFile(str(Path("Hud.qml").resolve())))
    assert engine.rootObjects()
    window = engine.rootObjects()[0]

    def item(name):
        return window.findChild(QObject, name)

    backend.datasetToggleRequested.connect(recorder.toggle)
    shortcut = item('datasetShortcut')
    assert shortcut is not None and not shortcut.property('enabled')
    assert not shortcut.property('autoRepeat')

    with patch.object(Path, 'mkdir'), \
         patch.object(Path, 'write_text', side_effect=AssertionError('No session JSON should be written')):
        mode('TEST')
        backend.setTestMode(True)
        app.processEvents()
        assert shortcut.property('enabled')
        QMetaObject.invokeMethod(shortcut, 'activated')
        assert recorder.active
        QMetaObject.invokeMethod(shortcut, 'activated')
        assert not recorder.active

        mode('DEMO')
        backend.setTestMode(False)
        app.processEvents()
        assert not shortcut.property('enabled')
        backend.toggleDataset()
        assert not recorder.active

        # A stale UI mode must still be rejected by the recorder.
        backend.setTestMode(True)
        backend.toggleDataset()
        assert not recorder.active

        mode('TEST')
        terminal.last_at -= 2
        backend.toggleDataset()
        assert not recorder.active
        backend.setTestMode(False)

    window.setProperty("cameraExpanded", True)
    app.processEvents()
    expanded = item("expandedCaptureCamera")
    viewport = expanded.parentItem()
    assert viewport.width() == 1752 and viewport.height() == 756
    assert expanded.property("width") == viewport.width()
    assert expanded.property("height") == viewport.height()
    assert expanded.property("x") == 0 and expanded.property("y") == 0

    class Fixture:
        main_sink = item("mainCaptureCamera").property("videoSink")
        expanded_sink = expanded.property("videoSink")
        frames = 0
        backend = backend
        dataset_recorder = recorder

    fixture = Fixture()
    CaptureReceiver.present(fixture, frame)
    assert fixture.main_sink.videoFrame().size() == frame.size()
    assert fixture.expanded_sink.videoFrame().size() == frame.size()
    assert item("mainCaptureCamera").property("y") == -142 * 178 / 256

    window.setProperty("captureCrop", False)
    app.processEvents()
    assert expanded.property("width") == viewport.width()
    assert expanded.property("height") == viewport.height()

    window.close()
    print("PASS: local k routing from console thread, TEST gating, 10Hz cadence, exact ROI PNG encoding, unique sessions, mode/stale/size/write failures, QML expanded layout and native sinks.")
finally:
    recorder.close()
    terminal.close()