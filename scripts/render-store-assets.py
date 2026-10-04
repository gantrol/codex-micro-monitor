"""Render product XAML, compose editable SVG, then export PNG and lossless WebP.

Edit store-assets.json for copy, order, models, reasoning, quota and task lights.
Edit LAYOUT below for the review layout. No browser or live application is used.
"""
from __future__ import annotations

import argparse
import asyncio
import base64
from functools import lru_cache
import hashlib
from io import BytesIO
import json
import os
from pathlib import Path
import xml.etree.ElementTree as ET

from PIL import Image, ImageFont
import resvg_py

ROOT = Path(__file__).resolve().parent.parent
LAYOUT = {
    "icon": (108, 65, 64, 64),
    "title": (110, 199), "quote": (112, 377),
    "panel": (970, 75, 870, 900),
    "text_width": 770,
}
RENDER_INPUTS = [
    "tools/CodexMicro.StoreAssets/Program.cs",
    "src/CodexMicro.Windows/MainWindow.xaml",
    "src/CodexMicro.Windows/MainWindow.xaml.cs",
    "src/CodexMicro.Windows/MicroSurfaceResources.xaml",
    "src/CodexMicro.Windows/Controls/QuotaKnob.cs",
    "src/CodexMicro.Windows/Controls/SevenSegmentReadout.cs",
    "src/CodexMicro.Windows/Controls/KeycapIcon.cs",
    "src/CodexMicro.Windows/Services/AgentLightingAppearance.cs",
    "src/CodexMicro.Windows/Services/CodexQuotaService.cs",
]
SVG_NS = "http://www.w3.org/2000/svg"
XLINK_NS = "http://www.w3.org/1999/xlink"
ET.register_namespace("", SVG_NS)
ET.register_namespace("xlink", XLINK_NS)


def element(parent, tag, **attributes):
    return ET.SubElement(parent, f"{{{SVG_NS}}}{tag}",
                         {key.replace("_", "-"): str(value) for key, value in attributes.items()})


def new_canvas(background=None, size=(1920, 1080)):
    canvas = ET.Element(f"{{{SVG_NS}}}svg", {
        "width": str(size[0]), "height": str(size[1]),
        "viewBox": f"0 0 {size[0]} {size[1]}", "version": "1.1",
    })
    if background:
        element(canvas, "rect", id="background", width=size[0], height=size[1], fill=background)
    return canvas


def safe_path(path: Path) -> Path:
    resolved = path.resolve()
    if "trash" in str(resolved).lower():
        raise ValueError("Unsupported path")
    return resolved


def load_config(path: Path) -> dict:
    config = json.loads(path.read_text(encoding="utf-8-sig"))
    if (config["canvas"]["width"], config["canvas"]["height"]) not in ((1920, 1080), (3840, 2160)):
        raise ValueError("Use a 1920×1080 or 3840×2160 canvas.")
    if len(config["scenes"]) > 10:
        raise ValueError("Store desktop screenshots are limited to ten.")
    for locale in config["locales"].values():
        for scene in config["scenes"]:
            if len(locale["captions"][scene["id"]]) > 200:
                raise ValueError("Screenshot captions must be 200 characters or fewer.")
    return config


def fingerprint(config: dict) -> str:
    state = {key: config[key] for key in ("renderScale", "quota", "scenes", "stateIds")}
    state["models"] = {name: {key: model[key] for key in ("id", "effort")} for name, model in config["models"].items()}
    digest = hashlib.sha256(json.dumps(state, sort_keys=True).encode())
    for name in RENDER_INPUTS:
        digest.update(safe_path(ROOT / name).read_bytes())
    return digest.hexdigest()


@lru_cache(maxsize=64)
def picture(path: Path) -> str:
    data = safe_path(path).read_bytes()
    with Image.open(BytesIO(data)) as opened:
        if opened.convert("RGBA").getchannel("A").getbbox() is None:
            raise ValueError(f"Empty render: {path.name}")
        mime = Image.MIME[opened.format]
        return f"data:{mime};base64," + base64.b64encode(data).decode("ascii")


def place(canvas, image_uri: str, box: tuple | list) -> None:
    x, y, width, height = box
    node = element(canvas, "image", x=x, y=y, width=width, height=height,
                   preserveAspectRatio="xMidYMid meet")
    # Embed source PNGs so each SVG remains portable without external image paths.
    node.set(f"{{{XLINK_NS}}}href", image_uri)


def text(canvas, value, xy, size, color, font_path, width=None, spacing=1.25):
    font = ImageFont.truetype(str(font_path), size)
    lines = []
    for paragraph in value.split("\n"):
        current = ""
        for character in paragraph:
            if width and current and font.getlength(current + character) > width:
                split = current.rfind(" ")
                if split > 0:
                    lines.append(current[:split])
                    current = current[split + 1:]
                else:
                    lines.append(current)
                    current = ""
            current += character
        lines.append(current)
    family, style = font.getname()
    for index, line in enumerate(lines):
        if not line:
            continue
        # Convert the approved top-aligned Pillow layout to SVG's text baseline.
        top = font.getbbox(line, anchor="ls")[1]
        node = element(canvas, "text", x=xy[0], y=xy[1] + index * size * spacing - top,
                       font_family=family, font_size=size,
                       font_weight=700 if "bold" in style.lower() else 400, fill=color)
        node.text = line


def save_artwork(canvas, path, size, font_files, webp=False):
    path.parent.mkdir(parents=True, exist_ok=True)
    canvas.set("width", str(size[0]))
    canvas.set("height", str(size[1]))
    ET.indent(canvas, space="  ")
    source = ET.tostring(canvas, encoding="unicode")
    png = resvg_py.svg_to_bytes(svg_string=source, skip_system_fonts=True,
                               font_files=[str(font) for font in font_files])
    if len(png) > 50 * 1024 * 1024:
        raise ValueError(f"Store image exceeds 50 MB: {path.name}")
    path.with_suffix(".svg").write_text(source, encoding="utf-8")
    path.write_bytes(png)
    if webp:
        with Image.open(BytesIO(png)) as image:
            image.save(path.with_suffix(".webp"), "WEBP", lossless=True, method=6)


def heading(canvas, copy, config, bold):
    palette = config["canvas"]
    if style := config.get("typography"):
        y = LAYOUT["title"][1]
        for index, line in enumerate(copy["title"].split("\n")):
            size = style["firstLineSize"] if index == 0 else style["secondLineSize"]
            # Keep each authored headline line intact in either language.
            while ImageFont.truetype(str(bold), size).getlength(line) > LAYOUT["text_width"]:
                size -= 1
            text(canvas, line, (LAYOUT["title"][0], y), size,
                 palette["ink"] if index == 0 else palette["accent"], bold)
            y += size + style["lineGap"]
    else:
        text(canvas, copy["title"], LAYOUT["title"], 64, palette["ink"], bold, LAYOUT["text_width"])


def model_actions(canvas, labels, palette, normal, label_size):
    color = palette["accent"]
    arrows = element(canvas, "g", id="model-actions", fill="none", stroke=color,
                     stroke_width=2, stroke_linecap="round", stroke_linejoin="round")
    # Two-way model switch, kept separate from the reasoning rings.
    element(arrows, "path", d="M397 617H481 M408 606L397 617L408 628 M470 606L481 617L470 628",
            stroke_width=3)
    for index, label in enumerate(labels):
        x, y = 140, 796 + index * 58
        mouse = element(arrows, "g", id="click-icon" if index == 0 else "scroll-icon",
                        transform=f"translate({x} {y})")
        element(mouse, "rect", width=26, height=36, rx=12)
        if index == 0:
            element(mouse, "path", d="M13 0A13 13 0 0 0 0 13H13Z", fill=color, stroke="none")
            element(mouse, "path", d="M13 0V16")
        else:
            element(mouse, "rect", x=11, y=7, width=4, height=11, rx=2, fill=color, stroke="none")
        text(canvas, label, (185, y + 1), label_size, palette["ink"], normal)
    # Actual lower-left SettingsKey center in the 590 x 610 XAML surface.
    px, py, pw, ph = LAYOUT["panel"]
    scale = min(pw / 590, ph / 610)
    cx = round(px + (pw - 590 * scale) / 2 + 150 * scale)
    cy = round(py + (ph - 610 * scale) / 2 + 465 * scale)
    radius = 59
    element(arrows, "circle", id="model-knob-target", cx=cx, cy=cy, r=radius)
    end = cx - radius - 5
    element(arrows, "path", id="model-knob-leader",
            d=f"M570 834H1020L1080 {cy}H{end} M{end - 10} {cy - 7}L{end} {cy}L{end - 10} {cy + 7}")
    # A visible pointer clicks the knob's lower-right rim, clear of its readout.
    cursor = element(canvas, "g", id="model-knob-click-cursor",
                     transform=f"translate({cx + 32} {cy + 29})", stroke=color,
                     stroke_width=3, stroke_linecap="round", stroke_linejoin="round")
    element(cursor, "path", id="click-rays", fill="none",
            d="M2 -12L3 -22 M12 -8L20 -15 M16 2L27 3")
    element(cursor, "path", id="cursor-pointer", fill="#FFFFFF",
            d="M0 0L2 43L12 33L22 51L30 46L20 28L34 28Z")


def compose(config: dict, output: Path) -> None:
    """Offline SVG composition and resvg rendering run on a worker, never the WPF thread."""
    palette = config["canvas"]
    size = (palette["width"], palette["height"])
    raw = output / "renders"
    fonts = Path(os.environ.get("WINDIR", "C:/Windows")) / "Fonts"
    font_files = sorted({fonts / locale[key] for locale in config["locales"].values()
                         for key in ("font", "boldFont")})
    icon = picture(safe_path(ROOT / config["product"]["icon"]))
    icon_path = output / "store" / "app-icon-300.png"
    # Preserve the actual icon and its transparency, without redrawing its mark.
    icon_canvas = new_canvas(size=(300, 300))
    place(icon_canvas, icon, (0, 0, 300, 300))
    save_artwork(icon_canvas, icon_path, (300, 300), font_files)
    for scene in config["scenes"]:
        canvas = new_canvas(palette["background"])
        place(canvas, picture(raw / (scene["id"] + ".png")), config["storePanelBox"])
        save_artwork(canvas, output / "store" / (scene["id"] + ".png"), size, font_files)

    for language, locale in config["locales"].items():
        normal, bold = fonts / locale["font"], fonts / locale["boldFont"]
        for card in config["cards"]:
            copy = locale["cards"][card["id"]]
            canvas = new_canvas(palette["background"])
            element(canvas, "title").text = copy["title"].replace("\n", " ")
            canvas.set("{http://www.w3.org/XML/1998/namespace}lang", language)
            place(element(canvas, "g", id="brand-icon"), icon, LAYOUT["icon"])
            heading(element(canvas, "g", id="headline"), copy, config, bold)
            if quote := copy.get("quote"):
                text(element(canvas, "g", id="quote"), quote, LAYOUT["quote"], 27,
                     palette["muted"], normal, LAYOUT["text_width"])
            place(element(canvas, "g", id="product-panel"),
                  picture(raw / (card["scene"] + ".png")), LAYOUT["panel"])
            if card["detail"] == "states":
                for index, state in enumerate(card["states"]):
                    legend = element(canvas, "g", id="state-" + state)
                    if config.get("showAnnotations"):
                        label_size = config.get("typography", {}).get("stateLabelSize", 26)
                        x, y = 85 + index % 2 * 415, 452 + index // 2 * 155
                        place(legend, picture(raw / f"state-{state}.png"), (x, y, 170, 170))
                        text(legend, locale["stateLabels"][state], (x + 160, y + (170 - label_size) / 2),
                             label_size, palette["ink"], normal, 250)
                    else:
                        x, y = 90 + index % 2 * 350, 465 + index // 2 * 200
                        place(legend, picture(raw / f"state-{state}.png"), (x, y, 240, 240))
            elif card["detail"] == "models":
                for index, key in enumerate(config["models"]):
                    place(element(canvas, "g", id="model-" + key),
                          picture(raw / f"knob-{key}.png"), (105 + index * 385, 477, 280, 280))
                if config.get("showAnnotations"):
                    model_actions(canvas, locale["modelActions"], palette, normal,
                                  config.get("typography", {}).get("actionLabelSize", 28))
            elif card["detail"] == "quota":
                place(canvas, picture(raw / "knob-quota.png"), (180, 461, 380, 380))
            elif card["detail"] == "fast":
                for index, state in enumerate(("off", "pending", "on")):
                    place(canvas, picture(raw / f"fast-{state}.png"), (90 + index * 260, 494, 210, 210))
            else:
                raise ValueError(f'Unknown detail: {card["detail"]}')
            save_artwork(canvas, output / "review" / language / (card["id"] + ".png"), size, font_files, webp=True)

    (output / "captions.json").write_text(json.dumps({key: value["captions"] for key, value in config["locales"].items()}, ensure_ascii=False, indent=2), encoding="utf-8")
    (output / "source-config.json").write_text(json.dumps(config, ensure_ascii=False, indent=2), encoding="utf-8")
    review = []
    for language, locale in config["locales"].items():
        review += [locale["shortDescription"], ""]
        for card in config["cards"]:
            file = output / "review" / language / (card["id"] + ".png")
            review += [f'![{card["id"]}]({file.as_posix()})', "",
                       f'[SVG]({file.with_suffix(".svg").as_posix()})', ""]
    (output / "review.md").write_text("\n".join(review), encoding="utf-8")


async def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, default=ROOT / "scripts/store-assets.json")
    parser.add_argument("--output", type=Path, default=ROOT / "dist/store/listing/v2")
    parser.add_argument("--compose-only", action="store_true", help="Only update copy/layout; require unchanged rendered state and source.")
    args = parser.parse_args()
    config_path, output = safe_path(args.config), safe_path(args.output)
    config = await asyncio.to_thread(load_config, config_path)
    stamp = await asyncio.to_thread(fingerprint, config)
    stamp_path = output / "renders" / "fingerprint.txt"
    if args.compose_only:
        previous = await asyncio.to_thread(stamp_path.read_text, encoding="utf-8")
        if previous != stamp:
            raise ValueError("Render state or product source changed. Run again without --compose-only.")
    else:
        process = await asyncio.create_subprocess_exec("dotnet", "run", "--project",
            str(ROOT / "tools/CodexMicro.StoreAssets/CodexMicro.StoreAssets.csproj"), "-c", "Release", "--", str(config_path), str(output / "renders"), cwd=ROOT)
        if await process.wait():
            raise RuntimeError("XAML render failed.")
        if await asyncio.to_thread(fingerprint, config) != stamp:
            raise RuntimeError("Product source changed during rendering. Run again after the edit completes.")
        await asyncio.to_thread(stamp_path.write_text, stamp, encoding="utf-8")
    await asyncio.to_thread(compose, config, output)
    print(output / "review.md")


if __name__ == "__main__":
    asyncio.run(main())
