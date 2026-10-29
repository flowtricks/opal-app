#!/usr/bin/env python3
"""Passive IORegistry observation only; never opens USB handles or camera APIs."""
import datetime, json, plistlib, subprocess, sys, time
seconds = float(sys.argv[1]) if len(sys.argv) > 1 else 120
end = time.monotonic() + seconds
previous = None
while time.monotonic() < end:
    result = subprocess.run(['ioreg', '-p', 'IOUSB', '-a', '-l'], stdout=subprocess.PIPE, check=True)
    devices = []
    def visit(item):
        if item.get('idVendor') == 0x03e7:
            devices.append({key: item.get(key) for key in ['USB Product Name', 'USB Serial Number', 'idProduct', 'locationID', 'UsbExclusiveOwner', 'IORegistryEntryName']})
        for child in item.get('IORegistryEntryChildren', []): visit(child)
    roots = plistlib.loads(result.stdout)
    for root in ([roots] if isinstance(roots, dict) else roots): visit(root)
    if devices != previous:
        print(json.dumps({'utc': datetime.datetime.now(datetime.timezone.utc).isoformat(), 'devices': devices}), flush=True)
        previous = devices
    time.sleep(0.05)
