using System.ComponentModel;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;
using Media = System.Windows.Media;
using Wpf = System.Windows;

namespace CodexMicro.Desktop.Controls;

// ContextMenuStrip preserves native tray activation and submenu navigation.
internal sealed class MicroTrayMenu : ContextMenuStrip
{
    private static readonly Wpf.ResourceDictionary Palette = new()
    {
        Source = new Uri(
            "/CodexMicro.Windows;component/Controls/MicroPopupPalette.xaml",
            UriKind.Relative),
    };

    private Font? _menuFont;

    internal MicroTrayMenu()
    {
        ShowImageMargin = false;
        ShowCheckMargin = true;
    }

    // ToolStripDropDownMenu restores DefaultPadding during every layout pass.
    // Keep its check/text gutter and reserve a separate inset for the surface.
    protected override Padding DefaultPadding
    {
        get
        {
            var native = base.DefaultPadding;
            if (SystemInformation.HighContrast) return native;
            var inset = LogicalToDeviceUnits(6);
            return new Padding(native.Left + inset, inset, native.Right + inset, inset);
        }
    }

    protected override void OnOpening(CancelEventArgs e)
    {
        var nextFont = (Font)SystemFonts.MenuFont!.Clone();
        var previousFont = _menuFont;
        Font = _menuFont = nextFont;
        previousFont?.Dispose();
        MinimumSize = new Size(LogicalToDeviceUnits(196), 0);
        var inset = SystemInformation.HighContrast ? 0 : LogicalToDeviceUnits(6);
        foreach (ToolStripItem item in Items)
        {
            // Native menu items subtract the menu's left padding from their
            // position. Margins preserve the inset without widening their text.
            item.Margin = new Padding(inset, 0, inset, 0);
            if (item is ToolStripSeparator)
            {
                // Separators ignore Padding when measuring their height.
                item.AutoSize = SystemInformation.HighContrast;
                if (!item.AutoSize) item.Height = LogicalToDeviceUnits(9);
                item.Padding = Padding.Empty;
            }
            else
            {
                item.Padding = new Padding(0, inset, 0, inset);
            }
        }

        Renderer = SystemInformation.HighContrast
            ? new ToolStripSystemRenderer()
            : new MenuRenderer();
        UpdateRegion();
        base.OnOpening(e);
    }

    protected override void OnSizeChanged(EventArgs e)
    {
        base.OnSizeChanged(e);
        UpdateRegion();
    }

    private void UpdateRegion()
    {
        var previous = Region;
        if (SystemInformation.HighContrast || Width < 2 || Height < 2)
        {
            Region = null;
        }
        else
        {
            using var path = RoundedRectangle(new RectangleF(0, 0, Width, Height), 8 * DeviceDpi / 96f);
            Region = new Region(path);
        }
        previous?.Dispose();
    }

    protected override void Dispose(bool disposing)
    {
        base.Dispose(disposing);
        if (disposing)
        {
            _menuFont?.Dispose();
            _menuFont = null;
        }
    }

    private static GraphicsPath RoundedRectangle(RectangleF bounds, float radius)
    {
        var diameter = Math.Min(2 * radius, Math.Min(bounds.Width, bounds.Height));
        var path = new GraphicsPath();
        path.AddArc(bounds.Left, bounds.Top, diameter, diameter, 180, 90);
        path.AddArc(bounds.Right - diameter, bounds.Top, diameter, diameter, 270, 90);
        path.AddArc(bounds.Right - diameter, bounds.Bottom - diameter, diameter, diameter, 0, 90);
        path.AddArc(bounds.Left, bounds.Bottom - diameter, diameter, diameter, 90, 90);
        path.CloseFigure();
        return path;
    }

    private static Color DrawingColor(Media.Color color) =>
        Color.FromArgb(color.A, color.R, color.G, color.B);

    private static Color PaletteColor(string key) =>
        DrawingColor(((Media.SolidColorBrush)Palette[key]).Color);

    private sealed class MenuRenderer : ToolStripProfessionalRenderer
    {
        private readonly Color _text = PaletteColor("MicroPopupInk");
        private readonly Color _muted = PaletteColor("MicroPopupMutedInk");
        private readonly Color _hover = PaletteColor("MicroPopupHover");
        private readonly Color _accent = PaletteColor("MicroPopupAccent");
        private readonly Color _line = PaletteColor("MicroPopupLine");

        internal MenuRenderer() => RoundedEdges = false;

        protected override void OnRenderToolStripBackground(ToolStripRenderEventArgs e)
        {
            using var brush = SurfaceBrush(e.ToolStrip.ClientRectangle, "MicroPopupFace", 90);
            e.Graphics.FillRectangle(brush, e.ToolStrip.ClientRectangle);
        }

        protected override void OnRenderImageMargin(ToolStripRenderEventArgs e) { }

        protected override void OnRenderToolStripBorder(ToolStripRenderEventArgs e)
        {
            var bounds = new RectangleF(0.5f, 0.5f, e.ToolStrip.Width - 1, e.ToolStrip.Height - 1);
            using var path = RoundedRectangle(bounds, 8 * e.ToolStrip.DeviceDpi / 96f);
            using var pen = new Pen(_line, 1);
            var state = e.Graphics.Save();
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            e.Graphics.DrawPath(pen, path);
            e.Graphics.Restore(state);
        }

        protected override void OnRenderMenuItemBackground(ToolStripItemRenderEventArgs e)
        {
            if ((!e.Item.Selected && !e.Item.Pressed) || !e.Item.Enabled) return;
            using var path = RoundedRectangle(
                new RectangleF(1, 1, e.Item.Width - 2, e.Item.Height - 2),
                4 * (e.ToolStrip?.DeviceDpi ?? 96) / 96f);
            using var brush = new SolidBrush(_hover);
            var state = e.Graphics.Save();
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            e.Graphics.FillPath(brush, path);
            e.Graphics.Restore(state);
        }

        protected override void OnRenderItemCheck(ToolStripItemImageRenderEventArgs e)
        {
            var scale = (e.ToolStrip?.DeviceDpi ?? 96) / 96f;
            var x = e.ImageRectangle.Left + e.ImageRectangle.Width / 2f;
            var y = e.Item.Height / 2f;
            using var pen = new Pen(e.Item.Enabled ? _accent : _muted, 1.7f * scale)
            {
                StartCap = LineCap.Round, EndCap = LineCap.Round, LineJoin = LineJoin.Round,
            };
            var state = e.Graphics.Save();
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            e.Graphics.DrawLines(pen,
            [
                new PointF(x - 4 * scale, y),
                new PointF(x - scale, y + 3 * scale),
                new PointF(x + 4 * scale, y - 3 * scale),
            ]);
            e.Graphics.Restore(state);
        }

        protected override void OnRenderArrow(ToolStripArrowRenderEventArgs e)
        {
            if (e.Direction is not (ArrowDirection.Left or ArrowDirection.Right))
            {
                e.ArrowColor = e.Item?.Enabled == false ? _muted : _text;
                base.OnRenderArrow(e);
                return;
            }

            var scale = (e.Item?.Owner?.DeviceDpi ?? 96) / 96f;
            var x = e.ArrowRectangle.Left + e.ArrowRectangle.Width / 2f;
            var y = e.ArrowRectangle.Top + e.ArrowRectangle.Height / 2f;
            var direction = e.Direction == ArrowDirection.Right ? 1 : -1;
            using var pen = new Pen(e.Item?.Enabled == false ? _muted : _text, 1.4f * scale)
            {
                StartCap = LineCap.Round, EndCap = LineCap.Round, LineJoin = LineJoin.Round,
            };
            var state = e.Graphics.Save();
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            e.Graphics.DrawLines(pen,
            [
                new PointF(x - direction * 2 * scale, y - 4 * scale),
                new PointF(x + direction * 2 * scale, y),
                new PointF(x - direction * 2 * scale, y + 4 * scale),
            ]);
            e.Graphics.Restore(state);
        }

        protected override void OnRenderItemText(ToolStripItemTextRenderEventArgs e)
        {
            // Native text/check rectangles exclude item padding; the arrow
            // already uses the full row height. Center all three on that row.
            var bounds = e.TextRectangle;
            e.TextRectangle = new Rectangle(bounds.X, 0, bounds.Width, e.Item.Height);
            e.TextFormat |= TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine;
            e.TextColor = e.Item.Enabled ? _text : _muted;
            base.OnRenderItemText(e);
        }

        protected override void OnRenderSeparator(ToolStripSeparatorRenderEventArgs e)
        {
            // Native separators also ignore the item margins when positioned.
            var inset = (int)Math.Round(14 * (e.ToolStrip?.DeviceDpi ?? 96) / 96d) - e.Item.Bounds.Left;
            using var pen = new Pen(_line);
            e.Graphics.DrawLine(pen, inset, e.Item.Height / 2, e.Item.Width - inset, e.Item.Height / 2);
        }

        private static LinearGradientBrush SurfaceBrush(Rectangle bounds, string key, float angle)
        {
            var stops = ((Media.LinearGradientBrush)Palette[key]).GradientStops;
            return new LinearGradientBrush(bounds, Color.White, Color.White, angle)
            {
                InterpolationColors = new ColorBlend
                {
                    Colors = stops.Select(stop => DrawingColor(stop.Color)).ToArray(),
                    Positions = stops.Select(stop => (float)stop.Offset).ToArray(),
                },
            };
        }
    }
}
