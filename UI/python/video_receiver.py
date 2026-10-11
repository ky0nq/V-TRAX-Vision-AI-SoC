# ESP32-CAM worker with a single latest-frame mailbox.
import sys
from array import array
import threading
import time
from urllib.request import Request, urlopen
from camera_discovery import discover_camera_url
from mac_discovery import MacDiscovery
from PySide6.QtCore import QObject, Signal
from PySide6.QtGui import QImage
from PySide6.QtQuick import QQuickImageProvider


class FrameNotifier(QObject):
    frameReady = Signal()


class MjpegReceiver:
    def __init__(self, url):
        self.url = url
        self.mac_discovery = MacDiscovery(url[4:]) if url.startswith("mac:") else None
        self.resolved_url = None
        self.stop_event = threading.Event()
        self.lock = threading.Lock()
        self.latest = None
        self.notification_pending = False
        self.notifier = FrameNotifier()
        self.frames = 0
        self.dropped_for_display = 0
        self.invalid_frames = 0
        self.frame_size = None
        self.last_jpeg_bytes = 0
        self.error = None
        self.thread = threading.Thread(target=self._run, daemon=True, name='esp32-cam')

    def start(self):
        self.thread.start()

    def _run(self):
        while not self.stop_event.is_set():
            try:
                self.resolved_url = None
                url = (
                    self.mac_discovery.resolve(self.stop_event)
                    if self.mac_discovery
                    else discover_camera_url(stop_event=self.stop_event)
                    if self.url == 'auto'
                    else self.url
                )
                if not url:
                    raise ConnectionError(
                        'Camera discovery pending: check power, same LAN and MAC; automatic probes support /24 or smaller'
                        if self.mac_discovery
                        else 'ESP32-CAM not found via mDNS'
                    )
                self.resolved_url = url
                request = Request(url, headers={'User-Agent': 'MotionHUD/1.0'})

                with urlopen(request, timeout=4) as response:
                    if 'multipart/' not in response.headers.get('Content-Type', '').lower():
                        raise ValueError('Use the ESP32-CAM MJPEG URL on port 81: /stream')
                    self.error = None
                    buffer = bytearray()

                    while not self.stop_event.is_set():
                        chunk = response.read1(4096)
                        if not chunk:
                            raise ConnectionError('Camera stream ended')
                        buffer.extend(chunk)

                        while True:
                            start = buffer.find(b'\xff\xd8')
                            if start < 0:
                                trailing_ff = buffer.endswith(b'\xff')
                                buffer.clear()
                                if trailing_ff:
                                    buffer.append(0xff)
                                break
                            if start:
                                del buffer[:start]

                            end = buffer.find(b'\xff\xd9', 2)
                            if end < 0:
                                if len(buffer) > 1024 * 1024:
                                    buffer.clear()
                                break

                            jpeg = bytes(buffer[:end + 2])
                            del buffer[:end + 2]

                            try:
                                image = QImage.fromData(jpeg, 'JPEG')
                            except ValueError:
                                self.invalid_frames += 1
                                continue
                            if image.isNull():
                                self.invalid_frames += 1
                                continue

                            notify = False
                            with self.lock:
                                if self.latest is not None:
                                    self.dropped_for_display += 1
                                self.latest = (image, time.monotonic())
                                self.frames += 1
                                self.frame_size = (image.width(), image.height())
                                self.last_jpeg_bytes = len(jpeg)
                                if not self.notification_pending:
                                    self.notification_pending = True
                                    notify = True
                            if notify:
                                self.notifier.frameReady.emit()

            except Exception as exc:
                if self.mac_discovery and self.resolved_url:
                    self.mac_discovery.reject(self.resolved_url)
                self.error = str(exc)
                self.stop_event.wait(1)

    def take_latest(self):
        with self.lock:
            result, self.latest = self.latest, None
            self.notification_pending = False
        return result

    def close(self):
        self.stop_event.set()
        if self.thread.is_alive():
            self.thread.join(timeout=0.5)


class CameraProvider(QQuickImageProvider):
    def __init__(self):
        super().__init__(QQuickImageProvider.Image)
        self.lock = threading.Lock()
        self.image = QImage(320, 180, QImage.Format_RGB888)
        self.image.fill(0x07111c)

    def set_jpeg(self, jpeg):
        try:
            image = QImage.fromData(jpeg, 'JPEG')
        except ValueError:
            # A damaged frame should be skipped without stopping the Qt timer.
            return False
        if image.isNull():
            return False
        with self.lock:
            self.image = image
        return True

    def set_image(self, image):
        # Publish a JPEG already decoded by the camera receiver thread.
        if image.isNull():
            return False
        with self.lock:
            self.image = image
        return True

    def requestImage(self, identifier, size, requestedSize):
        with self.lock:
            image = self.image.copy()
        size.setWidth(image.width())
        size.setHeight(image.height())
        return image