# Measure ESP32-CAM MJPEG delivery rate without Qt or JPEG decoding.

import argparse
import time
from urllib.request import Request, urlopen

class JpegCounter:
    def __init__(self):
        self.buffer = bytearray()

    def feed(self, chunk):
        self.buffer.extend(chunk)
        count = 0
        while True:
            start = self.buffer.find(b"\xff\xd8")
            if start < 0:
                last_ff = self.buffer.endswith(b"\xff")
                self.buffer.clear()
                if last_ff:
                    self.buffer.append(0xff)
                break
            if start:
                del self.buffer[:start]
            end = self.buffer.find(b"\xff\xd9", 2)
            if end < 0:
                if len(self.buffer) > 1024 * 1024:
                    self.buffer.clear()
                break
            del self.buffer[:end + 2]
            count += 1
        return count


def main():
    parser = argparse.ArgumentParser(description="Measure raw ESP32-CAM stream FPS")
    parser.add_argument("url", help="ESP32-CAM URL, e.g. http://192.168.137.234:81/stream")
    parser.add_argument("--seconds", type=float, default=12)
    args = parser.parse_args()
    counter = JpegCounter()
    request = Request(args.url, headers={"User-Agent": "VisionDrive-FPS-Test/1.0"})
    with urlopen(request, timeout=5) as response:
        content_type = response.headers.get("Content-Type", "")
        if "multipart/" not in content_type.lower():
            raise ValueError(f"Expected /stream MJPEG URL, got {content_type!r}")
        start = time.monotonic()
        last = start
        total = 0
        window = 0
        while time.monotonic() - start < args.seconds:
            chunk = response.read1(16 * 1024)
            if not chunk:
                break
            frames = counter.feed(chunk)
            total += frames
            window += frames
            now = time.monotonic()
            if now - last >= 2:
                print(f"stream_fps={window / (now - last):.1f}  total_frames={total}", flush=True)
                window = 0
                last = now
        elapsed = max(time.monotonic() - start, 0.001)
        print(f"average_fps={total / elapsed:.1f}  frames={total}  elapsed={elapsed:.1f}s")


if __name__ == "__main__":
    main()
