"""Extract the released 0.7 implementation for independent parity/timing checks."""
import pathlib
import subprocess

revision = "dd70bf6333ab2ea0bf7eb04e5d1fe4239cf00f26"
output = pathlib.Path("build/upscale-check")
output.mkdir(parents=True, exist_ok=True)
for name in ["PatternProcessor", "VideoProcessor"]:
    source = subprocess.check_output(["git", "show", f"{revision}:Sources/Processing/{name}.swift"]).decode()
    if name == "PatternProcessor":
        source = source.replace("enum PatternProcessor", "enum BaselinePatternProcessor", 1)
    else:
        source = "@preconcurrency import AVFoundation\nimport CoreImage\nimport Foundation\nimport ImageIO\nimport UniformTypeIdentifiers\n" + source[source.index("actor VideoProcessor"):]
        source = source.replace("actor VideoProcessor", "actor BaselineVideoProcessor", 1).replace("PatternProcessor.", "BaselinePatternProcessor.")
    (output / f"Baseline{name}.swift").write_text(source, encoding="utf-8")
