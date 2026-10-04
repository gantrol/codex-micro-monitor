using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Markup;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using System.Xml.Linq;
using CodexMicro.Desktop;
using CodexMicro.Desktop.Controls;
using CodexMicro.Desktop.Services;

namespace CodexMicro.StoreAssets;

// Only render product XAML here. Copy, layout and output formats belong to Python/JSON.
internal static class Program
{
    private static readonly string[] Events = ["SourceInitialized", "Loaded", "Closing", "Closed", "Deactivated", "IsVisibleChanged", "Click", "Checked", "Unchecked", "Opened", "ContextMenuOpening", "MouseLeftButtonDown", "MouseLeftButtonUp", "MouseMove", "MouseWheel", "LostMouseCapture", "PreviewKeyDown", "PreviewKeyUp", "PreviewMouseLeftButtonDown", "PreviewMouseLeftButtonUp", "PreviewMouseRightButtonDown", "PreviewMouseMove"];
    // Match MainWindow.Software.RefreshSoftwareFeedback.
    private static readonly Dictionary<string, string> FastColors = new()
    {
        ["off"] = "#171717", ["pending"] = "#C28B21", ["on"] = "#14876D"
    };

    [STAThread]
    private static int Main(string[] args)
    {
        if (args.Length != 2) { Console.Error.WriteLine("Usage: CodexMicro.StoreAssets <config.json> <output-directory>"); return 2; }
        if (args.Any(path => path.Contains("trash", StringComparison.OrdinalIgnoreCase))) return 2;
        var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        var exitCode = 0;
        app.Dispatcher.BeginInvoke(new Action(async () =>
        {
            try
            {
                var config = JsonSerializer.Deserialize<Config>(await File.ReadAllTextAsync(args[0]),
                    new JsonSerializerOptions { PropertyNameCaseInsensitive = true }) ?? throw new InvalidDataException("Empty configuration.");
                if (config.RenderScale is < 1 or > 4) throw new InvalidDataException("renderScale must be 1–4.");
                var output = System.IO.Path.GetFullPath(args[1]);
                await Task.Run(() => Directory.CreateDirectory(output));
                var source = await File.ReadAllTextAsync(System.IO.Path.Combine(AppContext.BaseDirectory, "Surface.xaml"));
                foreach (var scene in config.Scenes)
                {
                    var surface = LoadSurface(source, config, scene);
                    await ExportAsync(surface.Visual, 590, 610, config.RenderScale, output, scene.Id);
                }
                var resources = LoadSurface(source, config, config.Scenes[0]).Window;
                foreach (var (name, model) in config.Models)
                    await ExportAsync(NewKnob(resources, config.Quota, model, "model"), 96, 96, config.RenderScale, output, "knob-" + name);
                await ExportAsync(NewKnob(resources, config.Quota, config.Models.Values.First(), "quota"), 96, 96, config.RenderScale, output, "knob-quota");
                foreach (var name in config.StateIds)
                    await ExportAsync(StatePreview(resources, State(name)), 160, 160, config.RenderScale, output, "state-" + name);
                foreach (var (name, color) in FastColors)
                {
                    var preview = new Grid { Width = 128, Height = 128 };
                    preview.Resources.MergedDictionaries.Add(resources.Resources);
                    preview.Children.Add(new Button
                    {
                        Width = 96, Height = 96, Style = (Style)resources.FindResource("CommandKey"),
                        Content = new KeycapIcon { Width = 28, Height = 28, KeycapId = "FAST", IconBrush = Brush(color) }
                    });
                    await ExportAsync(preview, 128, 128, config.RenderScale, output, "fast-" + name);
                }
            }
            catch (Exception error) { Console.Error.WriteLine(error); exitCode = 1; }
            finally { app.Shutdown(exitCode); }
        }));
        app.Run();
        return exitCode;
    }

    // No product window constructor, account data, interaction handlers or observers.
    private static Surface LoadSurface(string source, Config config, Scene scene)
    {
        XNamespace x = "http://schemas.microsoft.com/winfx/2006/xaml";
        var root = XDocument.Parse(source).Root!;
        root.Attribute(x + "Class")?.Remove();
        foreach (var attribute in root.DescendantsAndSelf().Attributes().ToArray())
        {
            if (Events.Contains(attribute.Name.LocalName)) attribute.Remove();
            else if (attribute.IsNamespaceDeclaration && attribute.Value.StartsWith("clr-namespace:"))
                attribute.Value += ";assembly=CodexMicro.Windows";
            else if (attribute.Name.LocalName == "Source" && attribute.Value == "MicroSurfaceResources.xaml")
                attribute.Value = "pack://application:,,,/CodexMicro.Windows;component/MicroSurfaceResources.xaml";
        }
        foreach (var element in root.DescendantsAndSelf())
            if (element.Name.NamespaceName.StartsWith("clr-namespace:"))
                element.Name = XName.Get(element.Name.LocalName, element.Name.NamespaceName + ";assembly=CodexMicro.Windows");
        var window = (Window)XamlReader.Parse(root.ToString());
        var surface = new Surface(window, (Grid)window.FindName("DesignSurface"));
        ((Viewbox)surface.Visual.Parent).Child = null;
        surface.Visual.Resources.MergedDictionaries.Add(window.Resources);
        ConfigureKnob(surface.Find<QuotaKnob>("SettingsKey"), config.Quota, config.Models[scene.Model], scene.Readout);
        surface.Find<KeycapIcon>("ActionIcon06").IconBrush = Brush(FastColors[scene.Fast]);
        foreach (var name in new[] { "RuntimeLed", "DriverLed", "ActivityLed" })
            surface.Find<Ellipse>(name).Fill = Brush("#9EBDFF");
        if (scene.Page == "control")
        {
            if (scene.Lights.Length != 6) throw new InvalidDataException("A control scene needs six lights.");
            for (var i = 0; i < 6; i++)
                ApplyState(surface.Find<Button>($"AgentKey{i}"), surface.Find<Border>($"AgentGlowWide{i}"),
                    surface.Find<Border>($"AgentGlowNear{i}"), State(scene.Lights[i]));
        }
        else if (scene.Page == "monitor")
        {
            if (scene.Lights.Length != 14) throw new InvalidDataException("A monitor scene needs fourteen lights.");
            var grid = surface.Find<Grid>("MonitorGrid");
            var controls = surface.Find<Grid>("ControlGrid");
            controls.Visibility = Visibility.Collapsed;
            grid.Visibility = Visibility.Visible;
            surface.Find<RadioButton>("MonitorPageButton").IsChecked = true;
            surface.Find<RadioButton>("ControlPageButton").IsChecked = false;
            for (var i = 0; i < 4; i++) { grid.RowDefinitions.Add(new() { Height = new GridLength(106) }); grid.ColumnDefinitions.Add(new() { Width = new GridLength(106) }); }
            for (var i = 0; i < 14; i++)
            {
                var key = new Button { Width = 96, Height = 96, Margin = new Thickness(5), Style = (Style)window.FindResource("AgentKey") };
                var wide = new Border { Style = (Style)window.FindResource("AgentWideHalo") };
                var near = new Border { Style = (Style)window.FindResource("AgentNearHalo") };
                var cell = i < 12 ? i : i + 1;
                foreach (var element in new FrameworkElement[] { wide, near, key }) { Grid.SetRow(element, cell / 4); Grid.SetColumn(element, cell % 4); grid.Children.Add(element); }
                Panel.SetZIndex(wide, -10); Panel.SetZIndex(near, -9);
                ApplyState(key, wide, near, State(scene.Lights[i]));
            }
            foreach (var name in new[] { "ModelKnob", "ActionKey12" }) { var control = surface.Find<FrameworkElement>(name); controls.Children.Remove(control); grid.Children.Add(control); }
        }
        else throw new InvalidDataException("Unknown page: " + scene.Page);
        return surface;
    }

    private static QuotaKnob NewKnob(Window window, Quota quota, Model model, string readout)
    {
        var knob = new QuotaKnob { Style = (Style)window.FindResource("DarkKnobButton") };
        ConfigureKnob(knob, quota, model, readout);
        return knob;
    }

    private static void ConfigureKnob(QuotaKnob knob, Quota quota, Model model, string readout)
    {
        // Reuse the product's Pro filtering and its quota/effort ring implementation.
        var snapshot = new CodexQuotaSnapshot(new(100 - quota.WeeklyRemaining, 10080, DateTimeOffset.UnixEpoch),
            quota.FiveHourRemaining is { } remaining ? new(100 - remaining, 300, DateTimeOffset.UnixEpoch) : null,
            quota.Plan, DateTimeOffset.UnixEpoch);
        knob.UseQuotaReadout = true;
        knob.HasFiveHourWindow = snapshot.FiveHourWindow is not null;
        knob.HasWeeklyWindow = snapshot.WeeklyWindow is not null;
        knob.FiveHourRemaining = snapshot.FiveHourWindow?.RemainingPercent;
        knob.WeeklyRemaining = snapshot.WeeklyWindow?.RemainingPercent;
        knob.ModelId = model.Id;
        knob.ReasoningEffort = model.Effort;
        knob.DisplayMode = readout switch { "model" => QuotaKnobDisplayMode.Model, "quota" => QuotaKnobDisplayMode.Quota, _ => throw new InvalidDataException("Unknown readout: " + readout) };
    }

    private static AgentLightingAppearance State(string id) => id switch
    {
        "current-running" => AgentLightingAppearance.FromCodexSession(MicroHarnessSessionStatus.Running, true),
        "running" => AgentLightingAppearance.FromCodexSession(MicroHarnessSessionStatus.Running, false),
        "input" => AgentLightingAppearance.FromCodexSession(MicroHarnessSessionStatus.WaitingForInput, false),
        "question" => AgentLightingAppearance.Question(false),
        "unread" => AgentLightingAppearance.ManualUnread(false),
        "error" => AgentLightingAppearance.FromCodexSession(MicroHarnessSessionStatus.Error, false),
        "idle" => AgentLightingAppearance.FromCodexSession(MicroHarnessSessionStatus.Idle, false),
        "current-idle" => AgentLightingAppearance.FromCodexSession(MicroHarnessSessionStatus.Idle, true),
        _ => throw new InvalidDataException("Unknown task state: " + id)
    };

    private static void ApplyState(Button key, Border wide, Border near, AgentLightingAppearance state)
    {
        var appearance = MicroSurfaceWindow.ApplyAgentLightingAppearance(key, state);
        foreach (var name in new[] { "GlowWide", "Glow" }) if (key.Template.FindName(name, key) is UIElement glow) glow.Opacity = 0;
        MicroSurfaceWindow.ApplyAgentGlowAppearance(wide, near, key.BorderBrush, appearance);
    }

    private static Grid StatePreview(Window window, AgentLightingAppearance state)
    {
        var preview = new Grid { Width = 160, Height = 160 };
        preview.Resources.MergedDictionaries.Add(window.Resources);
        var wide = new Border { Style = (Style)window.FindResource("AgentWideHalo") };
        var near = new Border { Style = (Style)window.FindResource("AgentNearHalo") };
        var key = new Button { Width = 96, Height = 96, Style = (Style)window.FindResource("AgentKey") };
        preview.Children.Add(wide); preview.Children.Add(near); preview.Children.Add(key);
        ApplyState(key, wide, near, state);
        return preview;
    }

    private static async Task ExportAsync(FrameworkElement element, int width, int height, int scale, string output, string name)
    {
        if (name.Length == 0 || name.Any(c => !char.IsAsciiLetterOrDigit(c) && c != '-')) throw new InvalidDataException("Invalid asset name.");
        // Reparent the detached Window content so WPF recomputes visibility.
        var root = new Grid { Width = width, Height = height };
        root.Children.Add(element);
        root.Measure(new Size(width, height)); root.Arrange(new Rect(0, 0, width, height)); root.UpdateLayout();
        var bitmap = new RenderTargetBitmap(width * scale, height * scale, 96 * scale, 96 * scale, PixelFormats.Pbgra32);
        bitmap.Render(root); bitmap.Freeze();
        await Task.Run(async () =>
        {
            var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(bitmap));
            using var memory = new MemoryStream(); encoder.Save(memory);
            await File.WriteAllBytesAsync(System.IO.Path.Combine(output, name + ".png"), memory.ToArray());
        });
        Console.WriteLine(name + ".png");
    }

    private static SolidColorBrush Brush(string color) { var brush = new SolidColorBrush((Color)ColorConverter.ConvertFromString(color)); brush.Freeze(); return brush; }
    private sealed record Surface(Window Window, Grid Visual) { internal T Find<T>(string name) where T : class => (T)Window.FindName(name); }
    private sealed record Config(int RenderScale, Quota Quota, Dictionary<string, Model> Models, Scene[] Scenes, string[] StateIds);
    private sealed record Quota(string Plan, double WeeklyRemaining, double? FiveHourRemaining);
    private sealed record Model(string Id, string Effort);
    private sealed record Scene(string Id, string Page, string Model, string Readout, string Fast, string[] Lights);
}
