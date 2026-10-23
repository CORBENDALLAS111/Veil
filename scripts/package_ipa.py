"""Package a real device build for external signing / LiveContainer, and validate it."""
import hashlib
import json
import pathlib
import plistlib
import shutil
import struct
import zipfile

root = pathlib.Path(__file__).resolve().parent.parent
app = root / "build/device/Build/Products/Release-iphoneos/Veil.app"
info = plistlib.loads((app / "Info.plist").read_bytes())
binary = app / info["CFBundleExecutable"]
magic, cpu = struct.unpack("<II", binary.read_bytes()[:8])
assert magic == 0xFEEDFACF and cpu == 0x0100000C, "Expected arm64 Mach-O device binary"
assert info["CFBundlePackageType"] == "APPL"
assert "iPhoneOS" in info["CFBundleSupportedPlatforms"]
assert (app / "Assets.car").is_file(), "Compiled app icon missing"
assert (app / "SD2.1-OpenRAIL.txt").read_bytes() == (root / "Sources/Licenses/SD2.1-OpenRAIL.txt").read_bytes(), "Complete model license missing"
manifest = json.loads((app / "NeuralManifest.json").read_text())
assert manifest['totalBytes'] == 0 and all(not row.get('url') and row.get('bundledPath') for row in manifest['files']), "All model files must be embedded in the IPA"
assert "fp32" in manifest.get("vaeConversion", ""), "Release requires the tested full precision codec"
bundled = [row for row in manifest["files"] if row.get("bundledPath")]
assert any(row["path"].startswith("VAEEncoder.mlmodelc/") for row in bundled)
assert any(row["path"].startswith("VAEDecoder.mlmodelc/") for row in bundled)
for row in bundled:
    resource = (app / row["bundledPath"]).resolve()
    assert resource.is_relative_to(app.resolve())
    assert resource.stat().st_size == row["bytes"], "Model resource missing or truncated"
    assert hashlib.sha256(resource.read_bytes()).hexdigest() == row["sha256"], "Model resource hash mismatch"
output = root / "build/artifacts"
output.mkdir(parents=True, exist_ok=True)
ipa = output / "Veil-unsigned.ipa"
with zipfile.ZipFile(ipa, "w", zipfile.ZIP_DEFLATED) as archive:
    for path in sorted(app.rglob("*")):
        if path.is_file():
            archive.write(path, pathlib.PurePosixPath("Payload/Veil.app") / path.relative_to(app))
with zipfile.ZipFile(ipa) as archive:
    assert archive.testzip() is None
digest = hashlib.sha256(ipa.read_bytes()).hexdigest()
(output / "SHA256SUMS.txt").write_text(f"{digest}  {ipa.name}\n", encoding="utf-8")
print(f"{ipa.name}: {ipa.stat().st_size:,} bytes; SHA256 {digest}")
