# Find the ESP32-CAM's advertised stream on the local Wi-Fi network.

import threading
SERVICE_TYPE = "_visioncam._tcp.local."

def stream_url_from_info(info):
    # Build a stream URL from one mDNS service record.
    if info is None or not (1 <= info.port <= 65535):
        return None

    for address in info.parsed_addresses():
        if ":" not in address:  # ESP32 CameraWebServer uses IPv4.
            return f"http://{address}:{info.port}/stream"
    return None

def discover_camera_url(timeout=4, stop_event=None):
    # Return an advertised camera URL, or None when none is found in time.
    from zeroconf import IPVersion, ServiceBrowser, ServiceStateChange, Zeroconf

    found = threading.Event()
    result = []
    zeroconf = Zeroconf(ip_version=IPVersion.V4Only)

    def on_change(zc, service_type, name, state):
        if state not in (ServiceStateChange.Added, ServiceStateChange.Updated):
            return
        info = zc.get_service_info(service_type, name, timeout=1000)
        url = stream_url_from_info(info)
        if url and not found.is_set():
            result.append(url)
            found.set()

    browser = None
    try:
        browser = ServiceBrowser(zeroconf, SERVICE_TYPE, handlers=[on_change])
        remaining = max(0.0, timeout)

        while remaining > 0 and not found.is_set():
            if stop_event is not None and stop_event.is_set():
                break
            step = min(0.1, remaining)
            found.wait(step)
            remaining -= step

        return result[0] if result else None
    finally:
        if browser is not None:
            browser.cancel()
        zeroconf.close()