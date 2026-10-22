"""Choose a real available iPhone simulator; don't assume an installed model name."""
import json
import os
import pathlib
import subprocess

devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"]))["devices"]
phones = [(runtime, d) for runtime, rows in devices.items() if "iOS" in runtime
          for d in rows if d.get("isAvailable") and "iPhone" in d["name"]]
if not phones:
    raise SystemExit("No available iPhone simulator")
runtime, device = sorted(phones, key=lambda row: (row[0], "iPhone 17 Pro" == row[1]["name"], row[1]["name"]), reverse=True)[0]
with open(os.environ["GITHUB_OUTPUT"], "a") as f:
    f.write(f"destination=platform=iOS Simulator,id={device['udid']}\n")
print(f"Simulator: {device['name']} ({runtime})")
subprocess.run(["xcrun", "simctl", "boot", device["udid"]], check=device["state"] != "Booted")
subprocess.run(["xcrun", "simctl", "bootstatus", device["udid"], "-b"], check=True)
subprocess.run(["xcrun", "simctl", "status_bar", device["udid"], "override", "--time", "9:41", "--batteryState", "charged", "--batteryLevel", "100"], check=True)
