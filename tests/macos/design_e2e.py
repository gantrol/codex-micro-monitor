#!/usr/bin/env python3
"""Exercise the shipping painter without UIApplication, windows or a bridge."""
import argparse
import json
from pathlib import Path
import struct
import subprocess


def run(app: Path, directory: Path, report: Path):
    # Use an empty output folder: prior successful PNGs must not hide a crash.
    assert not directory.exists() or not any(directory.iterdir()), "Use a fresh artifact directory"
    directory.mkdir(parents=True, exist_ok=True)
    result = subprocess.run([str(app), "--export-design", str(directory)], capture_output=True, text=True, timeout=120)
    assert result.returncode == 0, f"Offline renderer exited {result.returncode}: {result.stderr[-2000:]}"
    expected = set("FAST FAST_ON APPR REJ SPLIT MIC MIC1 CODEX NEW DIFF SKETCH MIND+ MIND- BUG OAI TERM DWN DEL NAV MAGIC PLAY GIT BRCH BRANCH MRG PR PAINT LAB SETUP PARTY TIME FOLD UPL APPS EMPT1 EMPT2 EMPT3 EMPT4 EMPT5 YOLO YEET".split())
    records = json.loads((directory / "glyph-metrics.json").read_text())
    assert len(records) == len(expected) * 4
    scales = [0.6, 0.75, 1.0, 1.05]
    for scale in scales:
        items = [r for r in records if r["designScale"] == scale]
        assert len(items) == len(expected) and {r["name"] for r in items} == expected
        for item in items:
            optical = 1.35 if item["name"] in {"MIND+", "MIND-"} else 0.55 if item["name"].startswith("EMPT") else 1
            expected_side = 24 * optical * scale
            assert item["visibleWidth"] > 0 and item["visibleHeight"] > 0, item
            assert abs(max(item["visibleWidth"], item["visibleHeight"]) - expected_side) < 1e-6, item
            assert abs(item["centerX"] - 14 * optical * scale) < 1e-6, item
            assert abs(item["centerY"] - 14 * optical * scale) < 1e-6, item
            if item["name"] == "BRANCH":
                assert item["visibleHeight"] > item["visibleWidth"], "Branch must retain its vertical stem and three nodes, not a filled open-path slash"
        png = (directory / f"glyphs-{round(scale * 100)}.png").read_bytes()
        assert png[:8] == b"\x89PNG\r\n\x1a\n"
        # Eight columns, six rows, two themes, rendered at 2x.
        assert struct.unpack(">II", png[16:24]) == (1600, 2400)
    report.parent.mkdir(parents=True, exist_ok=True)
    report.write_text(json.dumps({
        "scope": "Packaged --export-design entry and shipping painter; no UIApplication, desktop bridge or Codex UI.",
        "result": "Pass", "catalogKeycaps": 40, "glyphsIncludingFastOn": 41,
        "scaleMetrics": 164, "scales": scales, "themes": ["light", "dark"],
        "artifactDirectory": str(directory),
    }, indent=2) + "\n")
    print(f"PASS offline painter: 40 keycaps, 164 metrics, 4 sheets; {report}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--directory", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    run(args.app.resolve(), args.directory.resolve(), args.report.resolve())
