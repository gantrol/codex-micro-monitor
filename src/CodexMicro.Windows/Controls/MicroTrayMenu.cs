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

    protected override void OnOpening(CancelEventArgs e)
    {
        var nextFont = SystemInformation.HighContrast
            ? (Font)SystemFonts.MenuFont!.Clone()
            : new Font("Segoe UI", Math.Max(10.5f, SystemFonts.MenuFont!.SizeInPoints));
        var previousFont = _menuFont;
        Font = _menuFont = nextFont;
        previousFont?.Dispose();
        Padding = new Padding(LogicalToDeviceUnits(6));
        MinimumSize = new Size(LogicalToDeviceUnits(196), 0);
        foreach (ToolStripItem item in Items)
        {
            item.Padding = item is ToolStripSeparator
                ? new Padding(0, LogicalToDeviceUnits(4), 0, LogicalToDeviceUnits(4))
                : new Padding(
                    LogicalToDeviceUnits(8), LogicalToDeviceUnits(6),
                    LogicalToDeviceUnits(8), LogicalToDeviceUnits(6));
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
            using var brush = SurfaceBrush(e.ToolStrip.ClientRectangle, "MicroPopupEdge", 45);
            using var pen = new Pen(brush, 1);
            var state = e.Graphics.Save();
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            e.Graphics.DrawPath(pen, path);
            e.Graphics.Restore(state);
        }

        protected override void OnRenderMenuItemBackground(ToolStripItemRenderEventArgs e)
        {
            if (!e.Item.Selected || !e.Item.Enabled) return;
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
            var y = e.ImageRectangle.Top + e.ImageRectangle.Height / 2f;
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
            e.ArrowColor = e.Item?.Enabled == false ? _muted : _text;
            base.OnRenderArrow(e);
        }

        protected override void OnRenderItemText(ToolStripItemTextRenderEventArgs e)
        {
            e.TextColor = e.Item.Enabled ? _text : _muted;
            base.OnRenderItemText(e);
        }

        protected override void OnRenderSeparator(ToolStripSeparatorRenderEventArgs e)
        {
            var inset = (int)Math.Round(8 * (e.ToolStrip?.DeviceDpi ?? 96) / 96d);
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
