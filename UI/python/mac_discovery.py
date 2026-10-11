# Windows same-LAN MAC lookup; bounded probes run on the camera worker.
import concurrent.futures
import ipaddress
import json
import re
import subprocess
import time

# ESP32-CAM MAC addr
DEFAULT_MAC = '5C-01-3B-47-98-E0'


def normalize_mac(value):
    value = value.replace('-', '').replace(':', '').lower()
    if not re.fullmatch(r'[0-9a-f]{12}', value):
        raise ValueError('Invalid camera MAC address')
    return value


def run(command, timeout=4):
    return subprocess.run(
        command,
        capture_output=True,
        text=True,
        errors='replace',
        timeout=timeout,
        creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0),
    ).stdout


def parse_arp(text, mac):
    target = normalize_mac(mac)
    result = []
    for ip, found in re.findall(r'(\d+\.\d+\.\d+\.\d+)\s+([0-9a-fA-F:-]{17})', text):
        if normalize_mac(found) == target:
            try:
                ipaddress.IPv4Address(ip)
            except ValueError:
                continue
            if ip not in result:
                result.append(ip)
    return result


def probe(ip):
    try:
        run(['ping', '-n', '1', '-w', '250', ip], timeout=2)
    except (OSError, subprocess.TimeoutExpired):
        pass


def local_targets(records):
    if isinstance(records, dict):
        records = [records]
    targets = set()
    for row in records or []:
        ip = ipaddress.IPv4Address(row['IPAddress'])
        alias = str(row.get('InterfaceAlias', '')).lower()
        if ip.is_loopback or ip.is_link_local or any(s in alias for s in ('wsl', 'vethernet', 'docker', 'vpn', 'loopback')):
            continue
        network = ipaddress.IPv4Network(f"{ip}/{row['PrefixLength']}", strict=False)
        # Avoid large corporate-network sweeps. Limit auto probing to /24 or smaller.
        if network.prefixlen < 24:
            continue
        targets.update(str(host) for host in network.hosts() if host != ip)
    return sorted(targets)[:512]


class MacDiscovery:
    def __init__(self, mac):
        self.mac = normalize_mac(mac)
        self.next_scan = 0
        self.failed = {}

    def reject(self, url):
        self.failed[url] = time.monotonic() + 8

    def lookup(self):
        for ip in parse_arp(run(['arp', '-a']), self.mac):
            url = f'http://{ip}:81/stream'
            if self.failed.get(url, 0) <= time.monotonic():
                return url
        return None

    def resolve(self, stop_event):
        if stop_event.is_set():
            return None

        url = self.lookup()
        if url:
            return url

        if time.monotonic() < self.next_scan:
            return None
        self.next_scan = time.monotonic() + 30

        script = 'Get-NetIPAddress -AddressFamily IPv4 -AddressState Preferred | Select-Object IPAddress,PrefixLength,InterfaceAlias | ConvertTo-Json -Compress'
        raw = run(['powershell.exe', '-NoProfile', '-NonInteractive', '-Command', script], timeout=8)
        targets = local_targets(json.loads(raw or '[]'))

        with concurrent.futures.ThreadPoolExecutor(max_workers=24) as executor:
            for offset in range(0, len(targets), 24):
                if stop_event.is_set():
                    return None
                list(executor.map(probe, targets[offset:offset + 24]))
                url = self.lookup()
                if url:
                    return url
        return None