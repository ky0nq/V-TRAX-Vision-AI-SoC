# Save the same HDMI ROI shown by the HUD, only with fresh TEST telemetry.
from pathlib import Path
import queue
import re
import threading
import time

from PySide6.QtCore import QObject, Signal, Slot

ROI_X, ROI_Y, ROI_SIZE = 440, 142, 256
FRAME_WIDTH, FRAME_HEIGHT = 1280, 720


class DatasetRecorder(QObject):
    activeChanged = Signal(bool)

    def __init__(self, terminal, output_root, parent=None, start_number=None, interval=0.1):
        super().__init__(parent)
        self.interval = interval
        self.terminal = terminal
        self.output_root = Path(output_root).resolve()
        if start_number is not None and start_number < 0:
            raise ValueError("Dataset start number must be non-negative")
        self.requested_start = start_number
        self.next_number = None
        self.active = False
        self.directory = None
        self.count = 0
        self.last_capture = None
        self.pending = queue.Queue(maxsize=8)
        self.completed = queue.Queue()
        self.worker = threading.Thread(target=self._write, daemon=True, name="dataset-png")
        self.worker.start()

    def _test_mode(self):
        state = self.terminal.current_state()
        return state is not None and state.get("capture_mode") == "TEST"

    @Slot()
    def toggle(self):
        if self.active:
            self.stop("k")
            return
        if not self._test_mode():
            self.terminal.append("[DATASET] TEST mode with live board telemetry is required.")
            return
        directory = self.output_root
        try:
            if self.next_number is None:
                last_number = -1
                for path in self.output_root.rglob("*.png"):
                    match = re.fullmatch(r"(?:capture|manual)_(\d+)\.png", path.name)
                    if match:
                        last_number = max(last_number, int(match.group(1)))
                self.next_number = max(self.requested_start or 0, last_number + 1)
            directory.mkdir(parents=True, exist_ok=True)
        except OSError as exc:
            self.terminal.append("[DATASET] Cannot create output folder: " + str(exc))
            return
        self.directory = directory
        self.count = 0
        self.last_capture = None
        self.active = True
        self.activeChanged.emit(True)
        self.terminal.append(f"[DATASET] ON: start number {self.next_number}, 256x256 PNG every {self.interval}s -> {directory}")

    def stop(self, reason):
        if self.active:
            self.active = False
            self.activeChanged.emit(False)
            self.terminal.append(f"[DATASET] OFF ({reason}); {self.count} frames queued -> {self.directory}")

    def check_mode(self):
        if self.active and not self._test_mode():
            self.stop("TEST mode ended or telemetry disconnected")
        while True:
            try:
                path, error = self.completed.get_nowait()
            except queue.Empty:
                break
            if error:
                self.stop("PNG write failed")
                self.terminal.append("[DATASET] Save failed: " + str(path) + ": " + error)
            else:
                self.terminal.append("[DATASET] Saved: " + str(path))

    def capture(self, frame):
        self.check_mode()
        if not self.active:
            return
        now = time.monotonic()
        # 0.1 sec capture 
        if self.last_capture is not None and now - self.last_capture < self.interval:
            return
        if (frame.width(), frame.height()) != (FRAME_WIDTH, FRAME_HEIGHT):
            self.stop(f"Expected 1280x720, received {frame.width()}x{frame.height()}")
            return
        image = frame.toImage()
        if image.isNull():
            self.stop("Cannot decode HDMI frame")
            return
        # Copy before the source frame is reused. HUD overlays are not part of this image.
        roi = image.copy(ROI_X, ROI_Y, ROI_SIZE, ROI_SIZE)
        path = self.directory / f"capture_{self.next_number:06d}.png"
        try:
            self.pending.put_nowait((path, roi))
        except queue.Full:
            return  # Drop rather than stall the UI or queue old video.
        self.count += 1
        self.next_number += 1
        self.last_capture = now

    def _write(self):
        while True:
            task = self.pending.get()
            try:
                if task is None:
                    return
                path, image = task
                try:
                    error = "" if image.save(str(path), "PNG") else "QImage.save returned false"
                except Exception as exc:
                    error = str(exc)
                self.completed.put((path, error))
            finally:
                self.pending.task_done()

    def close(self):
        self.stop("UI closed")
        self.pending.put(None)
        self.worker.join()
        self.check_mode()
