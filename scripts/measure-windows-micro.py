#!/usr/bin/env python3
"""Extract the current Windows default Micro design without starting any UI.

Writes source values, analytically derived layout, and a dimension drawing.
This is a measurement/export utility, not an application renderer or test suite.
"""
from pathlib import Path
import csv
import hashlib
import html
import json
import re
import subprocess
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'docs/design/windows-micro'
X = '{http://schemas.microsoft.com/winfx/2006/xaml}'
W = '{http://schemas.microsoft.com/winfx/2006/xaml/presentation}'
MAIN = 'src/CodexMicro.Windows/MainWindow.xaml'
STYLE = 'src/CodexMicro.Windows/MicroSurfaceResources.xaml'
FILES = [MAIN, STYLE, 'src/CodexMicro.Windows/MainWindow.xaml.cs',
         'src/CodexMicro.Windows/Services/MicroWindowLayout.cs',
         'src/CodexMicro.Windows/Services/AgentLightingAppearance.cs',
         'src/CodexMicro.Windows/Controls/KeycapIcon.cs',
         'src/CodexMicro.Windows/Services/CodexOfficialArtwork.cs',
         'src/CodexMicro.Windows/Services/CodexOfficialArtwork.g.cs',
         'src/CodexMicro.Windows/Controls/QuotaKnob.cs',
         'src/CodexMicro.Windows/Controls/SevenSegmentReadout.cs']
FILES += ['src/CodexMicro.Windows/MainWindow.Monitor.cs']


def local(s):
    return s.split('}')[-1]


def line(path, token):
    return next((i for i, s in enumerate((ROOT / path).read_text().splitlines(), 1) if token in s), None)


def source(path, token):
    return {'path': path, 'line': line(path, token)}


def tree(node):
    return {'type': local(node.tag), 'attributes': {local(k): v for k, v in node.attrib.items()},
            'children': [tree(c) for c in node]}


def margins(value):
    a = list(map(float, value.split(',')))
    if len(a) == 1:
        return a * 4
    if len(a) == 2:
        return [a[0], a[1], a[0], a[1]]
    return a


def inset(rect, margin):
    l, t, r, b = margins(margin)
    x, y, w, h = rect
    return [x + l, y + t, w - l - r, h - t - b]


def centered(rect, width, height):
    x, y, w, h = rect
    return [x + (w - width) / 2, y + (h - height) / 2, width, height]


def lighting_details(resources, named):
    """Keep each light carrier's real node, including gradients and effects.

    Rectangles are nominal unpressed geometry relative to a 96×96 AgentKey.
    The 1 DIP cap border participates in layout before inner margins do.
    Runtime descriptions were traced through ApplyAgentLightingAppearance.
    """
    agent = resources['AgentKey']
    parts = {e.get(X + 'Name'): e for e in agent.iter() if X + 'Name' in e.attrib}
    cap = [0, 0, 96, 96]
    content = inset(cap, parts['Cap'].get('BorderThickness'))
    specs = [
        ('AgentWideHalo', '共享宽光晕', centered(cap, 106, 106), '动态纯色；Z=-10；中性选中用纯白画刷'),
        ('AgentNearHalo', '共享近光晕', centered(cap, 100, 100), '动态纯色；Z=-9；位于所有实体键帽下方'),
        ('MintSeamLight', '薄荷接缝', centered(cap, 98, 98), '仅薄荷选中态；位于 Cap 后面，独立于 Cap 的按压位移'),
        ('StatusCapWash', '键帽染光', inset(content, parts['StatusCapWash'].get('Margin')), '动态纯色，使用 CapWashOpacity'),
        ('MintCapReturn', '键帽回光', inset(content, parts['MintCapReturn'].get('Margin')), '仅薄荷选中态；左上透明，右下渐强'),
        ('StatusLightField', '井外圆形光场', centered(content, 82, 82), '动态纯色圆面；Blur5.5；在实体圆井后面'),
        ('MintWellLight', '井边薄荷光', centered(content, 81, 81), '仅薄荷选中态；3 DIP 描边，Blur3.2'),
        ('MintWellReturn', '井内回光', centered(content, 76, 76), '仅薄荷选中态；偏心径向渐变，无额外 Blur'),
        ('StatusWellWash', '井内染光', centered(content, 76, 76), '动态纯色圆面；位于实体圆井上面，无额外 Blur'),
        ('AgentWellHighlight', '凹槽明暗沿', centered(content, 76, 76), '1.6 DIP 对角渐变描边；白光时减弱暗端'),
        ('AgentGlyph', '紫色中心点', centered(content, 18, 18), '普通态 Opacity=.6；白光或薄荷态隐藏'),
        ('WhiteAgentGlyph', '白色中心点', centered(content, 18, 18), '白光且非薄荷态显示'),
        ('MintAgentGlyph', '薄荷中心点', centered(content, 18, 18), '薄荷选中态显示'),
    ]
    carriers = []
    for key, label, rect, behavior in specs:
        node = resources[key] if key in resources else parts[key]
        token = f'x:Key="{key}"' if key in resources else f'x:Name="{key}"'
        carriers.append({'id': key, 'label': label, 'rectRelativeToCap': rect,
                         'behavior': behavior, 'source': source(STYLE, token), 'node': tree(node)})
    return {
        'carriers': carriers,
        'runtimeSource': source(FILES[2], 'internal static AgentLightingAppearance ApplyAgentLightingAppearance('),
        'compositionSource': source(FILES[2], 'internal static void ApplyAgentGlowAppearance('),
        'order': ['shared wide halos (Z=-10)', 'shared near halos (Z=-9)',
                  'per-key FarShadow', 'MintSeamLight', 'Cap base and border',
                  'StatusCapWash', 'MintCapReturn', 'CapInsetShadow', 'white inset edge',
                  'StatusLightField', 'MintWellLight', 'AgentWell opaque base',
                  'MintWellReturn', 'StatusWellWash', 'AgentWellHighlight', 'active center glyph'],
        'orderNote': 'Cap shadow is an effect on the composed Cap subtree. Template GlowWide/Glow are disabled in MainWindow. CurrentSessionRing is always set to zero.',
        'alphaRules': {
            'coloredCarrier': 'colorAlpha × DisplayOpacity × carrierOpacity, before blur and overlapping layers',
            'neutralSharedHalo': 'white brush alpha 1 × carrierOpacity; DisplayOpacity is bypassed',
            'mintCarrier': 'its own ARGB/gradient alpha × enabled opacity (0 or 1); independent of DisplayOpacity',
            'monitor': 'whole-key opacity applies to the key subtree, not the sibling shared halos; stale/unavailable appearance is cleared separately',
            'notPixelBrightness': 'These are source alpha coefficients, not final pixel luminance. Blur, occlusion and layer compositing still apply.'},
        'selectionRules': {
            'neutral': 'current && (!active || whiteFallback || color == White)',
            'mint': 'current && (!active || whiteFallback)',
            'whiteDot': 'renderedColor == White && DisplayOpacity > 0 && !mint',
            'purpleDot': '!whiteLight && !mint',
            'ring': 'CurrentSessionRing remains opacity 0'},
        'whiteLightShadowChanges': [
            ['Cap near shadow', 'Opacity .20 → .05; Blur3, depth2, color#3A403D unchanged'],
            ['FarShadow', '#243A403D → #093A403D; Blur8 unchanged'],
            ['CapInsetShadow', 'Opacity 1 → .25'],
            ['Well rim dark stops', '#28747B77 → #0A747B77 at0; #14747B77 → #05747B77 at.42; white stops unchanged']],
        'motion': {
            'status': 'The inspected renderer directly assigns light color/opacity; EffectName breath is a protocol label, not a local breathing storyboard. Upstream snapshots may change values over time.',
            'hover': 'Cap border #99FFFFFF → #F7FFFFFF; AgentWellHighlight opacity 1 → .86',
            'press': '80ms: Cap translates down1.5; FarShadow opacity→.45. Release110ms: Cap returns with CubicEase EaseOut; FarShadow opacity→1. Shared halos and MintSeamLight do not move with Cap.'},
        'lowerRefraction': {'rect': [113, 562, 364, 5], 'node': tree(named['CrystalLowerRefraction']),
                            'source': source(MAIN, 'x:Name="CrystalLowerRefraction"'),
                            'peakUnblurredAlpha': 165 / 255 * .15},
        'statusLED': {'diameter': 7, 'glowBlurRadius': 8, 'glowDepth': 0, 'glowOpacity': .78,
                      'colors': {'neutralNoGlow': '#B8B98B', 'healthy': '#78A6FF', 'active': '#304FFE', 'waiting': '#FFC85A', 'error': '#FF7994'},
                      'source': source(FILES[2], 'private const double StatusLedGlowBlurRadius')},
        'precision': 'Source values and nominal geometry only; WPF blur kernel/antialiasing and physical brightness have not been measured.'
    }


def measure():
    main = ET.parse(ROOT / MAIN).getroot()
    styles = ET.parse(ROOT / STYLE).getroot()
    named = {e.get(X + 'Name'): e for e in main.iter() if X + 'Name' in e.attrib}
    resources = {e.get(X + 'Key'): e for e in styles.iter() if X + 'Key' in e.attrib}
    canvas = [0, 0, float(named['DesignSurface'].get('Width')), float(named['DesignSurface'].get('Height'))]
    rows = []

    def add(name, rect, radius=None, ref=None, note=''):
        row = {'id': name, 'rect': rect, 'center': [rect[0] + rect[2] / 2, rect[1] + rect[3] / 2],
               'radius': radius, 'source': ref, 'note': note,
               'measurement': 'source-derived nominal layout; before WPF device-pixel rounding'}
        rows.append(row)
        return rect

    add('DesignSurface', canvas, ref=source(MAIN, 'x:Name="DesignSurface"'))
    frame = add('DeviceFrame', inset(canvas, named['DeviceFrame'].get('Margin')),
                float(named['DeviceFrame'].get('CornerRadius')), source(MAIN, 'x:Name="DeviceFrame"'))
    inner = add('CrystalLightClip', inset(frame, named['DeviceFrame'].get('BorderThickness')),
                ref=source(MAIN, 'x:Name="CrystalLightClip"'), note='DeviceFrame BorderThickness is part of layout.')
    for name in ['CrystalPrismRim', 'CrystalDepthPlate', 'PearlLightGuide']:
        node = named[name]
        add(name, inset(inner, node.get('Margin')), float(node.get('CornerRadius')), source(MAIN, f'x:Name="{name}"'))
    gridnode = named['ControlGrid']
    grid = add('ControlGrid', centered(inner, float(gridnode.get('Width')), float(gridnode.get('Height'))), ref=source(MAIN, 'x:Name="ControlGrid"'))
    cols = [float(n.get('Width')) for n in gridnode.find(W + 'Grid.ColumnDefinitions')]
    heights = [float(n.get('Height')) for n in gridnode.find(W + 'Grid.RowDefinitions')]
    cell_centers = [[grid[0] + sum(cols[:c]) + cols[c] / 2, grid[1] + sum(heights[:r]) + heights[r] / 2]
                    for r in range(4) for c in range(4)]
    controls = ['DialButton', 'AgentKey0', 'AgentKey1', 'JoystickSurface',
                'AgentKey2', 'AgentKey3', 'AgentKey4', 'AgentKey5',
                'ActionKey06', 'ActionKey07', 'ActionKey08', 'ActionKey09', 'ModelKnob', 'ActionKey10', 'ActionKey12']
    layout = {}
    for name in controls:
        n = named[name]
        c, r = int(n.get('Grid.Column', 0)), int(n.get('Grid.Row', 0))
        span = int(n.get('Grid.ColumnSpan', 1))
        cell = [grid[0] + sum(cols[:c]), grid[1] + sum(heights[:r]), sum(cols[c:c + span]), heights[r]]
        rect = centered(inset(cell, n.get('Margin', '0')), float(n.get('Width')), float(n.get('Height')))
        radius = 14 if name.startswith(('AgentKey', 'ActionKey')) else None
        layout[name] = add(name, rect, radius, source(MAIN, f'x:Name="{name}"'))
        if name.startswith('AgentKey'):
            add(name + '.Cap', rect, 14, source(STYLE, 'x:Key="AgentKey"'),
                'Explicit 96×96 Cap; differs from the command-key template.')
            add(name + '.Well', centered(rect, 76, 76), 38, source(STYLE, 'x:Name="AgentWell"'))
        if name.startswith('ActionKey'):
            cap = inset(inset(rect, '0.5'), '0,0,0,1.5')
            add(name + '.Cap', cap, 14, source(STYLE, 'x:Name="Cap"'), 'CommandKey: Grid margin 0.5, Cap bottom margin 1.5.')
            well = centered(cap, 160 if span == 2 else 76, 76)
            add(name + '.Well', well, 38, source(STYLE, 'x:Name="KeyWell"'))
    dial = layout['DialButton']
    for name, margin in [('DialSide', '3,9,3,0'), ('DialReturn', '5,4,5,4'), ('DialFace', '3,0,3,7')]:
        add(name, inset(dial, margin), ref=source(STYLE, 'x:Key="DialButton"'))
    add('DialIndicator.unrotated', [dial[0] + 41, dial[1] + 9, 6, 30], 3, source(STYLE, 'x:Name="DialIndicator"'),
        'Rotate 42° around its bottom center (136,141), not around its center.')
    add('JoystickCap', centered(layout['JoystickSurface'], 67, 67), 33.5, source(MAIN, 'x:Name="JoystickCap"'))
    joy = layout['JoystickSurface']
    directions = {'JoystickUp': [joy[0] + 36, joy[1] - 6, 24, 24],
                  'JoystickLeft': [joy[0] - 6, joy[1] + 36, 24, 24],
                  'JoystickRight': [joy[0] + 78, joy[1] + 36, 24, 24],
                  'JoystickDown': [joy[0] + 36, joy[1] + 78, 24, 24]}
    for name, rect in directions.items():
        add(name, rect, ref=source(MAIN, f'x:Name="{name}"'), note='24×24 hit area; glyph container 14×10, base path M1,7 L6,2 L11,7.')
    knob = layout['ModelKnob']
    add('QuotaKnob.Face', [knob[0] + knob[2] - 5 - 58, knob[1] + (knob[3] - 58) / 2, 58, 58], 29,
        source(STYLE, 'x:Name="KnobFace"'))
    add('QuotaKnob.Seat', [knob[0] + knob[2] - 1 - 64, knob[1] + 4 + (knob[3] - 4 - 64) / 2, 64, 64], 32,
        source(STYLE, 'Width="64"'))
    for index, name in enumerate(['RuntimeLed', 'DriverLed', 'ActivityLed']):
        add(name, [knob[0] + 10, knob[1] + (96 - 29) / 2 + index * 11, 7, 7], 3.5, source(MAIN, f'x:Name="{name}"'))
    page_style = next(e for e in main.iter() if e.get(X + 'Key') == 'PageDot')
    page_width = float(next(e.get('Value') for e in page_style if e.get('Property') == 'Width'))
    page_height = float(next(e.get('Value') for e in page_style if e.get('Property') == 'Height'))
    for i, name in enumerate(['ControlPageButton', 'MonitorPageButton']):
        rect = [canvas[2] / 2 - page_width + i * page_width, inner[1] + 28, page_width, page_height]
        add(name, rect, ref=source(MAIN, f'x:Name="{name}"'))
        add(name + '.Dot', centered(rect, 20 if i == 0 else 7, 7), 4, source(MAIN, 'x:Key="PageDot"'))
    for index, cell in enumerate([n for n in range(16) if n not in [12, 15]]):
        x, y = cell_centers[cell]
        add(f'MonitorTask{index:02d}', [x - 48, y - 48, 96, 96], 14,
            source(FILES[10], 'MonitorGrid.RowDefinitions.Add'), f'Monitor page; cell {cell}; quota at 12, Codex at 15.')
    source_data = [{'path': p, 'sha256': hashlib.sha256((ROOT / p).read_bytes()).hexdigest()} for p in FILES]
    raw_nodes = {name: tree(named[name]) for name in ['DeviceFrame', 'LeftSilkScreen', 'RightSilkScreen', 'BrandWordmarkPanel', 'DialSelectionHud']}
    # Avoid embedding the entire window twice. Keep the shell's own layer definitions.
    raw_nodes['DeviceFrame']['children'] = [tree(c) for c in named['DeviceFrame'] if local(c.tag) in ['Border.Background', 'Border.Effect']]
    for name in ['CrystalPrismRim', 'CrystalDepthPlate', 'PearlLightGuide', 'CrystalLowerRefraction', 'JoystickCap']:
        raw_nodes[name] = tree(named[name])
    for name in ['CommandKey', 'AgentKey', 'AgentWideHalo', 'AgentNearHalo', 'DialButton', 'DarkKnobButton', 'JoystickDirectionButton', 'PaperRecessRingBrush', 'PaperWhiteLightRecessRingBrush']:
        raw_nodes[name] = tree(resources[name])
    raw_nodes['PageDot'] = tree(page_style)
    # Retain paths verbatim, including each path's fill rule. Do not substitute
    # inactive fallback artwork just because it appears in KeycapIcon.cs.
    official = (ROOT / FILES[7]).read_text()
    local_art = (ROOT / FILES[5]).read_text()
    glyphs = {}
    for key in ['FAST', 'FAST_ON', 'APPR', 'REJ', 'SPLIT', 'MIC', 'CODEX']:
        if key == 'FAST':
            definition = re.search(r'PaperFastGeometry\s*=\s*CreateGeometry\((.*?)\);', local_art, re.S).group(1)
            glyphs[key] = {'source': source(FILES[5], 'PaperFastGeometry ='), 'viewBox': [24, 24], 'transform': [1, 0, 0]}
        else:
            name = re.search(r'\["' + ('FAST' if key == 'FAST_ON' else key) + r'"\] = "([^"]+)"', official).group(1)
            definition = re.search(r'\["' + re.escape(name) + r'"\] = new\((.*?)\),\n', official, re.S).group(1)
            w, h, scale, x, y = map(float, definition.split('Create(', 1)[0].rstrip(', ').split(','))
            glyphs[key] = {'source': source(FILES[7], f'["{name}"] = new('), 'name': name, 'viewBox': [w, h], 'transform': [scale, x, y]}
        glyphs[key]['paths'] = [{'data': p, 'fillRule': 'nonzero' if p.startswith('F1 ') else 'evenodd'} for p in re.findall(r'"([^"]+)"', definition)]
    return {
        'basis': {'repositoryCommit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
                  'scope': 'Current repository Windows default Codex control-page design. Excludes unpublished updates, saved user mappings and live Windows runtime measurements.',
                  'units': 'design DIP; top-left origin; rectangles are x,y,width,height',
                  'certainty': 'XML numbers are exact source values. Layout is derived before WPF rounding. Raster samples are evidence only.',
                  'sources': source_data},
        'window': {'designSize': canvas[2:], 'defaultSize': [442.5, 457.5], 'defaultDesignScale': 0.75,
                   'userScaleRange': [0.8, 1.4], 'effectiveDesignScaleRange': [0.6, 1.05],
                   'pixelFormula': 'designDIP × (windowWidth / 590) × (WindowsDPI / 96), then WPF layout/snapping',
                   'source': source(FILES[3], 'DefaultWidth =')},
        'layout': rows, 'grid': {'columns': cols, 'rows': heights, 'cellCenters': cell_centers,
                                'nominalSingleKey': [96, 96], 'nominalKeyGap': 10, 'doubleKey': [202, 96]},
        'layers': raw_nodes, 'glyphs': glyphs,
        'icons': {'nominalElement': [28, 28], 'effectiveDrawingSizeFormula': 'max(28, 24 / designScale)',
                  'drawingSizeAtDefaultScale': [32, 32], 'windowDIPAtDefaultScale': [24, 24],
                  'commandColor': '#171717', 'commandCenterOffsetFromSlot': [0, -0.75],
                  'source': source(FILES[5], 'var deviceScale =')},
        'lighting': {'source': source(FILES[4], 'FromHarnessSession('),
                     'columns': ['display', 'wideHalo', 'nearHalo', 'capWash', 'lightField', 'wellWash'],
                     'softwareBackgroundActive': [0.94, 0.42, 0.22, 0.12, 0.43, 0.40],
                     'softwareSelectedActive': [1, 0.82, 0.48, 0.28, 0.52, 0.48],
                     'softwareSelectedIdleAfterForDisplay': [1, 0.96, 0.68, 0.18, 0.52, 0.38],
                     'idleUnselected': [0, 0, 0, 0, 0, 0],
                     'monitorWholeKeyOpacity': {'empty': 0.42, 'stale': 0.58, 'fresh': 1},
                     'monitorOpacitySource': source(FILES[10], 'key.Opacity ='),
                     'dot': {'diameter': 18, 'purple': '#685FAE', 'purpleOpacity': 0.6,
                             'mintSelectedIdle': '#B9EFD2', 'mintStroke': '#28939A96', 'mintStrokeThickness': 0.8,
                             'glowBlurRadius': 4, 'glowDepth': 0, 'glowOpacity': 0.38},
                     'colors': {'running': '#304FFE', 'waiting': '#FF6D00', 'question': '#FFD54F', 'unread': '#00FF4C', 'error': '#FF0033'},
                     'composition': 'All shared halos are below every physical cap. Colored carriers multiply DisplayOpacity; neutral shared halos use a white brush without that multiplier. Mint layers use their own ARGB/gradient alpha.',
                     'details': lighting_details(resources, named)},
        'quota': {'source': source(FILES[8], 'var gauge = new Grid'), 'faceDiameter': 58, 'sourceGauge': [52, 52],
                  'displayModes': {'auto': 'quota normally; model on hover or keyboard preview', 'quota': 'always quota', 'model': 'always model'},
                  'gaugeScale': '58/52', 'trackDiametersInGaugeUnits': [47, 41],
                  'trackThicknessInGaugeUnits': 1.4, 'progressThicknessInGaugeUnits': 1.6,
                  'displayTrackDiameters': [47 * 58 / 52, 41 * 58 / 52],
                  'singleReadoutBox': [36, 20], 'dualReadoutBox': [34, 32], 'dualValueBox': [27, 14],
                  'sevenSegment': {'digit': [7.5, 14], 'digitGap': 1.5, 'percentWidth': 6.5, 'percentGap': 4,
                                   'percentPen': 0.9, 'segments': re.findall(r'Segment\("([^"]+)"\)', (ROOT / FILES[9]).read_text())}},
        'text': {'leftRotatedLeftEdge': 64, 'rightRotatedRightEdge': 526, 'verticalCenter': 305,
                 'sideFontSize': 8, 'brandBottomEdge': 560, 'brandIcon': [10, 10], 'brandGap': 5,
                 'brandFontSize': 8, 'family': 'Segoe UI Variable Text',
                 'limitation': 'Text ink bounds and final measured line boxes require the actual font renderer; no invented bounding box.'},
        'limitations': ['No Windows process or GUI was started.', 'No font rasterization, WPF antialiasing or blur kernel equivalence was measured.',
                        'WPF BlurRadius must not be assumed to equal UIKit/CoreGraphics shadowRadius or half of it.',
                        'Colors are uncomposited ARGB values; a flattened screenshot cannot uniquely recover layer alpha.',
                        'Do not mix the historical KeypadExports rendering with the current vector-icon routing.']
    }


def drawing(data):
    by_id = {r['id']: r for r in data['layout']}
    elements = ['<svg xmlns="http://www.w3.org/2000/svg" width="1120" height="830" viewBox="0 0 1120 830">',
                '<style>text{font-family:Arial,sans-serif;fill:#163e3a} .small{font-size:11px} .label{font-size:13px} .dim{stroke:#087f8c;stroke-width:1;fill:none} .guide{stroke:#98b2b0;stroke-width:.7;stroke-dasharray:3 4;fill:none}</style>',
                '<rect width="1120" height="830" fill="#f8faf9"/>',
                '<text x="44" y="39" font-size="23" font-weight="700">Windows Micro / source dimensions</text>',
                '<text x="44" y="64" class="label">590 × 610 design DIP · origin at top left · nominal layout before WPF pixel rounding</text>',
                '<g transform="translate(44 103)">']
    for name in ['DesignSurface', 'DeviceFrame', 'CrystalPrismRim', 'CrystalDepthPlate', 'PearlLightGuide', 'ControlGrid']:
        r = by_id[name]; x, y, w, h = r['rect']
        elements.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{r["radius"] or 0}" class="{"guide" if name in ["DesignSurface", "ControlGrid"] else "dim"}"/>')
    names = ['DialFace', 'AgentKey0', 'AgentKey1', 'JoystickCap', 'AgentKey2', 'AgentKey3', 'AgentKey4', 'AgentKey5',
             'ActionKey06', 'ActionKey07', 'ActionKey08', 'ActionKey09', 'ActionKey10', 'ActionKey12', 'QuotaKnob.Face']
    for name in names:
        r = by_id[name]; x, y, w, h = r['rect']; radius = r['radius'] if r['radius'] is not None else min(w, h) / 2
        elements.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{radius}" fill="#eaf2ef" stroke="#2d6862" stroke-width="1"/>')
        label = {'DialFace':'82 × 81', 'JoystickCap':'Ø67', 'QuotaKnob.Face':'Ø58', 'ActionKey10':'202 × 96'}.get(name, '96 × 96')
        elements.append(f'<text x="{x+w/2}" y="{y+h/2+4}" class="small" text-anchor="middle">{label}</text>')
        if name + '.Well' in by_id:
            well = by_id[name + '.Well']['rect']
            elements.append(f'<rect x="{well[0]}" y="{well[1]}" width="{well[2]}" height="{well[3]}" rx="38" class="guide"/>')
    for name in ['ControlPageButton.Dot', 'MonitorPageButton.Dot', 'RuntimeLed', 'DriverLed', 'ActivityLed']:
        r = by_id[name]; x,y,w,h=r['rect']
        elements.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{r["radius"]}" fill="#087f8c"/>')
    for x in [136,242,348,454]:
        elements.append(f'<path d="M{x} 83 V528" class="guide"/><text x="{x}" y="83" text-anchor="middle" class="small">x={x}</text>')
    for y in [146,252,358,464]:
        elements.append(f'<path d="M73 {y} H517" class="guide"/><text x="585" y="{y+4}" text-anchor="end" class="small">y={y}</text>')
    elements += ['<path d="M0 633 H590 M0 628 V638 M590 628 V638" class="dim"/><text x="295" y="653" text-anchor="middle" class="label">590 DIP</text>', '</g>']
    lines = [('OUTER SHELL', '(23,23) · 544 × 564 · R66 · border 2'),
             ('PRISM / DEPTH / FACE', '(29,29) 532 × 551 · R61', '(35,35) 520 × 540 · R56', '(43,43) 504 × 524 · R50'),
             ('GRID', '(83,93) · 424 × 424', '106 pitch · 96 key · 10 nominal gap'),
             ('COMMAND CAP ≠ AGENT CAP', 'Command: 95 × 93.5 · R14', 'Well / glyph center: slot y − 0.75', 'Agent: explicit 96 × 96 · R14'),
             ('PAGE INDICATORS', 'Centers (277,67) and (313,67)', 'Selected 20 × 7 · inactive 7 × 7'),
             ('WHITE DIAL', 'Control 88 × 88 · face 82 × 81', 'Indicator 6 × 30 · R3 · angle 42°', 'Rotation pivot (136,141)'),
             ('QUOTA / GLYPHS', 'Quota face center (150,464)', 'Glyph nominal 28 · default drawn 32', 'Default window: 442.5 × 457.5')]
    y=120
    for group in lines:
        elements.append(f'<text x="680" y="{y}" font-size="13" font-weight="700">{html.escape(group[0])}</text>');y+=21
        for value in group[1:]:
            elements.append(f'<text x="680" y="{y}" class="label">{html.escape(value)}</text>');y+=19
        y+=17
    elements += [f'<text x="44" y="805" class="small">Source commit {data["basis"]["repositoryCommit"][:12]} · This is a dimension drawing, not a rendered appearance preview.</text>', '</svg>']
    return '\n'.join(elements)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    data = measure()
    (OUT / 'measurements.json').write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n')
    (OUT / 'lighting.json').write_text(json.dumps({'basis': data['basis'], **data['lighting']}, ensure_ascii=False, indent=2) + '\n')
    with (OUT / 'layout.csv').open('w', newline='') as f:
        writer = csv.writer(f, lineterminator='\n')
        writer.writerow(['id','x','y','width','height','center_x','center_y','radius','source','line','note'])
        for r in data['layout']:
            writer.writerow([r['id'],*r['rect'],*r['center'],r['radius'],r['source']['path'],r['source']['line'],r['note']])
    (OUT / 'dimensions.svg').write_text(drawing(data))
    (OUT / 'index.html').write_text(report(data))
    print(f'Measured {len(data["layout"])} rectangles, {len(data["layers"])} layer trees and {len(data["glyphs"])} glyph variants at {data["basis"]["repositoryCommit"][:12]}.')


def report(data):
    def esc(value):
        return html.escape(str(value))
    def table(headers, rows):
        return '<table><thead><tr>' + ''.join(f'<th>{esc(h)}</th>' for h in headers) + '</tr></thead><tbody>' + ''.join('<tr>' + ''.join(f'<td>{esc(c)}</td>' for c in row) + '</tr>' for row in rows) + '</tbody></table>'
    chunks = ['''<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Windows Micro 精确测量</title><style>
body{margin:0;background:#f4f6f3;color:#203b35;font:15px/1.7 system-ui,-apple-system,sans-serif}main{max-width:1160px;margin:auto;padding:36px 28px 70px}h1{font-size:32px;margin:0 0 8px}h2{font-size:21px;margin-top:38px}p{max-width:960px}a{color:#087d70}table{border-collapse:collapse;width:100%;background:#fff;font-size:13px;margin:16px 0}td,th{padding:10px 13px;text-align:left;border-bottom:1px solid #dce5df;vertical-align:top}th{background:#e5eeea}td{font-variant-numeric:tabular-nums}svg{width:100%;height:auto}code{background:#e7ece9;padding:2px 4px}aside{border-left:3px solid #197869;padding:8px 18px;background:#e8f0ed}details{margin-top:16px}summary{cursor:pointer;font-weight:600}.meta{color:#58716a}button{padding:7px 16px;font:inherit;border:1px solid #aac2b8;background:white;border-radius:6px;cursor:pointer}@media print{body{background:white}main{padding:0}button{display:none}table{break-inside:avoid}}
</style><main><h1>Windows Micro 精确测量</h1>''',
        f'<p class="meta">基准：当前本地 Windows 提交 <code>{data["basis"]["repositoryCommit"]}</code>；默认 Codex 布局。源码逐文件 SHA-256 已记录。</p>',
        '<aside>“精确”分三层：① 源码字面值；② 按 WPF 布局规则推导、尚未做设备像素取整的逻辑坐标；③ 图像实测。这里的坐标以设计画布左上角为原点，单位为设计 DIP。并未启动 Windows 或 Mac 应用，也未把数学布局冒充实际渲染截图。</aside>',
        '<p><a href="measurements.json">完整图层与路径 JSON</a> · <a href="layout.csv">坐标 CSV</a> · <a href="dimensions.svg">独立尺寸图 SVG</a></p>', drawing(data),
        '<h2>01 / 尺寸与坐标</h2><p>设计画布 590 × 610；默认窗口 442.5 × 457.5，相当于 0.75 倍。用户设置的 80%–140% 作用于默认窗口，对应设计尺度 0.60–1.05。DIP 不等于截图像素，最终还受 Windows DPI 与 WPF 取整影响。</p>']
    key_rows = [r for r in data['layout'] if r['id'] in ['DeviceFrame','CrystalPrismRim','CrystalDepthPlate','PearlLightGuide','ControlGrid','DialButton','DialFace','JoystickCap','AgentKey0.Cap','ActionKey06.Cap','ActionKey06.Well','ActionKey10','ActionKey10.Cap','ActionKey10.Well','QuotaKnob.Face','QuotaKnob.Seat','ControlPageButton.Dot','MonitorPageButton.Dot']]
    chunks.append(table(['部件','x / y','宽 × 高','中心','圆角'], [[r['id'],f'{r["rect"][0]:g}, {r["rect"][1]:g}',f'{r["rect"][2]:g} × {r["rect"][3]:g}',', '.join(f'{v:g}' for v in r['center']),r['radius'] if r['radius'] is not None else '椭圆 / 无'] for r in key_rows]))
    chunks.append('<p>格距 106，单键占位 96 × 96，名义键间距 10。四列中心 x=136 / 242 / 348 / 454，四行中心 y=146 / 252 / 358 / 464。监视页使用同一格网，槽位 12 为额度、15 为 Codex，其余 14 个为任务键。</p>')
    chunks.append('<h2>02 / 键帽不是同一个组件</h2>')
    chunks.append(table(['项目','任务键 AgentKey','命令键 CommandKey'],[
        ['表面尺寸','显式 96 × 96','95 × 93.5；外部仍占 96 × 96'],
        ['表面中心','等于槽位中心','比槽位中心高 0.75'],
        ['外圈 / 圆井','R14；圆井 76 × 76、R38','R14；圆井 76 × 76、R38；麦克风井 160 × 76'],
        ['底色','#FFF7F8F6','#FFF7F8F6'],
        ['外边','#99FFFFFF，1 DIP；悬停 #F7FFFFFF','#F2FFFFFF，1 DIP；悬停 #FFFFFFFF'],
        ['暗内沿','#334E5451；右/下 2 DIP','#295F6662；右/下 1.5 DIP'],
        ['亮内沿','#B8FFFFFF；左/上 2 DIP','#F2FFFFFF；左/上 1.5 DIP'],
        ['远影','92 × 92，向下 3；#243A403D；BlurRadius 8','内边距 2,4,2,0；#33363C39；BlurRadius 8'],
        ['底座','无命令键式独立 SwitchShadow','SwitchShadow #B8ADB4B0；顶部内边距 1.5'],
        ['近影','#3A403D；BlurRadius 3、深度2、透明度.20','#5F6662；BlurRadius 2、深度1、透明度.12'],
        ['按压位移','向下1.5；80ms按下 / 110ms回弹','向下1；80ms按下 / 110ms回弹']]))
    chunks.append('<p>凹槽边框不是单一灰线：从左上到右下依次为 <code>#28747B77 @0 → #14747B77 @0.42 → #8CFFFFFF @0.58 → #CCFFFFFF @1</code>，厚度 1.6。所有八位颜色按 <strong>ARGB</strong> 解读，不能按 RGBA 直接抄写。</p>')
    chunks.append('<h2>03 / 壳体与光影</h2>')
    chunks.append(table(['层','颜色 / 参数'],[
        ['外壳','垂直渐变 #E4FFFFFF@0 / #D6F7FAF9@.48 / #C8E8F0EF@.78 / #B8C7D3D3@1；边 #D9FFFFFF、2 DIP'],
        ['棱镜边','对角渐变 #FFFFFFFF@0 / #B8DFF8F3@.16 / #76FFFFFF@.46 / #8BC6EEE5@.78 / #D6FFFFFF@1；2 DIP；整体透明度.94'],
        ['深度板','底 #14748788；边 #78FFFFFF@0 / #5EACBDBB@.58 / #75859498@1；1 DIP'],
        ['内面','垂直渐变 #F4FFFFFF@0 / #EEF8FAF8@.5 / #E9F1F5F2@.82 / #E3E1EAE8@1；边 #A8FFFFFF、1 DIP'],
        ['外壳影','WPF DropShadow：Color #526E7B80；BlurRadius30；深度7；方向270°；Opacity.29'],
        ['白旋钮','面82 × 81，并非正圆；底82 × 79、回光78 × 80；渐变白→#F4F9F9@.38→#E3EDF0@.7→#B4C2C8；影Blur8、方向285°、深度3、Opacity.3'],
        ['旋钮指示条','6 × 30，R3，#6A7379；旋转42°；支点为底端中心(136,141)，非条形中心'],
        ['摇杆','Ø67；径向中心(.34,.27)、半径(.76,.76)；#50524F@0→#363936@.44→#222422@1；影Blur5、深度3、Opacity.42'],
        ['额度钮','面Ø58，#2D2925，中心(150,464)；底Ø64，中心(151,466)；三灯Ø7，中心(101.5,453/464/475)']]))
    chunks.append('<aside>WPF 的 BlurRadius、UIKit / Core Graphics 的 shadowRadius 和 CSS blur 参数不是同一个定义。源码参数可以精确记录，但没有核对渲染核就不能擅自“除以二”迁移。上一版在这里做了未经验证的换算。</aside>')
    chunks.append('<h2 id="lighting">04 / 光晕、回光与状态亮度</h2><p>外层宽光晕 106 × 106、R21、Blur28；近光晕100 × 100、R18、Blur16；内部光场Ø82、Blur5.5。所有外光晕必须先于所有实体键帽绘制，不能逐键把光晕盖到相邻键上。<a href="lighting.json">独立光效账本：原始图层、渐变、状态条件与源码位置</a>。</p>')
    l = data['lighting']
    chunks.append(table(['软件状态', *l['columns']], [[name, *l[key]] for name,key in [('后台活动','softwareBackgroundActive'),('选中活动','softwareSelectedActive'),('选中空闲 / ForDisplay 后','softwareSelectedIdleAfterForDisplay'),('未选中空闲','idleUnselected')]]))
    chunks.append('<p>这是软件状态映射经过 ForDisplay 的数值。彩色载体再乘 DisplayOpacity：后台活动的宽、近晕分别为 <strong>.3948、.2068</strong>；键帽、光场、圆井为 .1128、.4042、.376。这些是模糊与遮挡前的透明度系数，不是最终像素亮度。硬件 SlotLighting 的亮度另由协议提供，不能套软件状态的固定值。</p><aside>修正上份报告：中性选中态的共享外光晕直接使用纯白画刷，<strong>不乘 DisplayOpacity</strong>；薄荷层也使用各自颜色的 Alpha，不能统一乘状态亮度。</aside>')
    chunks.append('<h3>光从哪里出来</h3>')
    chunks.append(table(['层','相对键帽的 x, y, w, h','形状 / 模糊','颜色与运行时条件'], [
        [c['label'], ', '.join(f'{v:g}' for v in c['rectRelativeToCap']),
         {'AgentWideHalo':'R21 / Blur28','AgentNearHalo':'R18 / Blur16','MintSeamLight':'R15 / 厚1.6 / Blur5',
          'StatusCapWash':'R10 / Blur6.5','MintCapReturn':'R11 / 厚1.5 / Blur1.8',
          'StatusLightField':'圆面 / Blur5.5','MintWellLight':'圆环 / 厚3 / Blur3.2',
          'MintWellReturn':'径向渐变 / 无额外模糊','StatusWellWash':'圆面 / 无额外模糊',
          'AgentWellHighlight':'圆环 / 厚1.6','AgentGlyph':'圆点 / 零偏移辉光4，.38',
          'WhiteAgentGlyph':'圆点 / 边.8 / 辉光4，.38','MintAgentGlyph':'圆点 / 边.8 / 辉光4，.38'}[c['id']], c['behavior']]
        for c in l['details']['carriers']]))
    chunks.append('<p>坐标相对96 × 96键帽左上角；键帽1 DIP边框也占布局空间，因此内部染光实际86 × 86、回光边90 × 90。圆井基底为不透明 #FFF7F8F6，覆盖后面的部分光场；圆井上的染光是另一层，不能把两者合并。</p>')
    chunks.append('<h3>选中空闲：白光底，加四层薄荷回光和中心点</h3>')
    chunks.append(table(['层','原始颜色 / 渐变（ARGB）'], [
        ['接缝光','#756EF0B0；描边Alpha117/255，开启时层Opacity1'],
        ['键帽回光','左上→右下：#008CECB4@0 → #128CECB4@.42 → #668CECB4@1'],
        ['井边光','#6874E7AD；描边Alpha104/255，开启时层Opacity1'],
        ['井内回光','中心/原点(.46,.40)，半径(.54,.57)；#00FAFFFC@0 → #08C8FBDD@.40 → #2698EDC1@.74 → #4481E9B2@1'],
        ['中心点','#B9EFD2；边#28939A96，厚.8；同色零偏移辉光Blur4、Opacity.38']]))
    chunks.append('<p>薄荷层的条件为“当前会话且（不活动或白光回退）”。显式白色活动态使用白光与白点，但不自动开启薄荷层。普通状态保留紫点#685FAE、Opacity.6。CurrentSessionRing在运行时始终设为0，不能因为模板存在就画出来。</p>')
    chunks.append(table(['白光还改变阴影','源码变化'], l['details']['whiteLightShadowChanges']))
    chunks.append('<h3>叠放、按压与其他反光</h3><p>顺序：共享宽晕 → 共享近晕 → 每键远影 → 接缝薄荷光 → 键帽底 → 键帽染光/回光 → 内沿明暗 → 圆形光场/井边光 → 实体圆井 → 井内回光/染光 → 凹槽明暗沿 → 中心点。键帽整体另带近影；模板内自带的两层外晕在窗口中关闭，避免叠加两次。</p>')
    chunks.append(table(['项目','精确参数 / 行为'], [
        ['悬停','键帽边#99FFFFFF→#F7FFFFFF；凹槽明暗沿Opacity1→.86'],
        ['按压','80ms：Cap下移1.5，远影Opacity→.45；松开110ms：Cap以CubicEase EaseOut回位，远影→1。共享外光晕与接缝光不跟着Cap下移'],
        ['呼吸','当前渲染函数直接赋颜色和透明度；协议EffectName中的breath不等于软件实现了呼吸动画。上游快照变化仍可使亮度随时间变化'],
        ['壳体下缘折射','全画布(113,562,364,5)，R3；左→右 #0098E8D5@0 / #A598E8D5@.48 / #0098E8D5@1，层Opacity.15；峰值Alpha≈.09706，无额外Blur'],
        ['三颗小状态灯','Ø7；发光态同色DropShadow，Blur8、深度0、Opacity.78；中性#B8B98B不发光；健康#78A6FF、活动#304FFE、等待#FFC85A、错误#FF7994']]))
    chunks.append('<p>监视页整键透明度为空槽.42、过期.58、新鲜1，仅作用于键的子树；共享外光晕是同级节点，不能跟着乘这个值，过期状态由独立逻辑熄灯。控制页没有同一条整键透明度赋值。源码中的模糊值和Alpha已经记全，但跨平台的光斑扩散、边缘衰减及最终亮度仍需实际渲染标定，不能宣称已达到像素一致。</p>')
    chunks.append('<h2>05 / 图标、读数与文字</h2>')
    chunks.append(table(['图标','实际来源','原始 viewBox','各路径填充'], [[key, val.get('name','PaperFastGeometry'), ' × '.join(map(str,val['viewBox'])), ', '.join(p['fillRule'] for p in val['paths'])] for key,val in data['glyphs'].items()]))
    chunks.append('<p>命令图标声明 28 × 28，但默认0.75窗口下内部绘图扩为32 × 32设计单位，落到窗口上保持24 × 24 DIP。实际墨迹范围比绘图区小，必须用原始路径，不能把外接矩形宽高当作图案本身宽高。FAST 关闭时走本地路径；其余优先走 CodexOfficialArtwork。每条路径有自己的 EvenOdd / Nonzero 规则。</p>')
    chunks.append('<p>菜单栏品牌另用 <code>assets/CodexMicro.png</code> 的圆角框∞。原图512 × 512，非零透明度包围框为[31,31,481,481)，中部青色∞的阈值包围框为[113,179,399,333)。这些是位图像素测量，不是贝塞尔控制点；不能拿CODEX命令键图案代替品牌标志。</p>')
    chunks.append('<p>额度仪表以52 × 52单位绘制，再整体缩放58/52：双环直径47和41对应面上的 <strong>52.423077 与45.730769</strong>；轨道厚1.4，进度厚1.6，也必须随比例缩放。七段数字单字7.5 × 14，字距1.5，百分号宽6.5、前距4、笔宽.9。单额度框36 × 20；双额度布局34 × 32，两个值各不超过27 × 14。</p>')
    chunks.append('<p>侧面丝印字体8、Segoe UI Variable Text：左侧旋转后的左边界x=64，右侧右边界x=526，垂直中心y=305。底部字标底边y=560、图标10 × 10、间隔5。字形墨迹边界与行框高度需要真实字体排版，当前不把它们臆测成“8像素高”。</p>')
    chunks.append('<h2>06 / 上一版 Mac 的明确偏差</h2>')
    chunks.append(table(['部位','Windows 基线','Mac preview.2 源码'],[
        ['任务键构造','AgentKey与CommandKey独立模板','共用KeySurface；任务键也被缩成命令键的95 × 93.5'],
        ['命令键图案中心','随Cap中心上移.75','图案仍在整个槽位中心'],
        ['页签纵坐标','67','65'],
        ['背景任务宽/近晕透明度','.42 / .22，再乘.94','.30 / .42，次序和强度均不同'],
        ['选中任务宽/近晕透明度','.82 / .48','.50 / .62'],
        ['选中空闲','白光+独立薄荷回光层','整体薄荷描边'],
        ['控制页空槽','没有监视页的整键.42赋值','两页共用TaskKey，控制页也整键.opacity(.42)'],
        ['光晕叠放','集中在所有实体键下方','每颗键自己绘制，后一个可能覆盖前一个'],
        ['模糊换算','WPF参数需渲染标定','直接使用一半半径，未经对照验证'],
        ['字体','Segoe UI Variable Text','系统字体与估计中心；不能宣称字标精确对齐']]))
    chunks.append('<h2>07 / 图像实测与证据边界</h2><p>仓库原尺寸PNG为590 × 610，保留透明通道0–255；键帽内部采样(128,270)为RGBA(247,248,246,255)，与源码#FFF7F8F6一致。四个第二排紫色圆点的阈值外接框中心约为(137.5,253.5)、(244.5,253.5)、(349.5,253.5)、(455.5,253.5)，属于栅格证据，至少有±1px阈值边缘不确定性，不能直接替换源码中心。<a href="raster-observations.json">采样方法、边界、文件指纹</a>。</p><p>这个PNG的分叉图标仍是旧分支图案，当前源码默认使用worktree路径；不能混搭为同一版设计。展平的宣传图或用户Mac截图也无法唯一反推出原始透明度和模糊参数。</p><p>Mac preview.3 已按本账本重建为 UIKit / Mac Catalyst。模糊核进一步查证 WPF 的 CalculateSamplingWeights：标准差为半径/3，权重归一化；Mac 采用有限高斯分离卷积。实际渲染、边缘取整与颜色合成仍需独立核对，不以编译成功替代视觉验收。</p>')
    chunks.append('<details><summary>全部坐标与源码定位</summary>')
    chunks.append(table(['部件','x, y, w, h','源码'], [[r['id'], ', '.join(f'{n:g}' for n in r['rect']),f'{r["source"]["path"]}:{r["source"]["line"]}'] for r in data['layout']]))
    chunks.append('</details><details><summary>源文件指纹</summary>')
    chunks.append(table(['源文件','SHA-256'], [[r['path'],r['sha256']] for r in data['basis']['sources']]))
    chunks.append('</details></main></html>')
    return '\n'.join(chunks)


if __name__ == '__main__':
    main()
