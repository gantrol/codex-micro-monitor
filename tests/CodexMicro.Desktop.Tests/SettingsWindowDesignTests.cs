using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using CodexMicro.Desktop.Services;
using Xunit;

namespace CodexMicro.Desktop.Tests;

[Collection(WpfUiCollection.Name)]
public sealed class SettingsWindowDesignTests
{

    [Fact]
    public void KeycapEditorUsesSearchableSixColumnCatalogAndActionPicker()
    {
        Exception? error = null;
        var thread = new Thread(() =>
        {
            try
            {
                _ = Application.Current ?? new Application
                {
                    ShutdownMode = ShutdownMode.OnExplicitShutdown,
                };
                var configPath = Path.Combine(
                    Path.GetTempPath(),
                    "codex-micro-editor-tests",
                    Guid.NewGuid().ToString("N"),
                    "config.toml");
                using var observer = new CodexMicroLayoutObserver(configPath);
                var editor = new KeycapEditorWindow(
                    "ACT07",
                    observer.Current.GetSlot("ACT07"),
                    new MicroLocalization(MicroLanguage.ZhCn),
                    new CodexMicroConfigWriter(configPath),
                    observer);

                editor.Measure(new Size(940, 820));
                editor.Arrange(new Rect(0, 0, 940, 820));
                var root = Assert.IsAssignableFrom<FrameworkElement>(
                    editor.Content);
                root.Measure(new Size(940, 820));
                root.Arrange(new Rect(0, 0, 940, 820));
                editor.UpdateLayout();

                Assert.Equal("编辑键帽", editor.EditorTitleText.Text);
                Assert.Contains("ACT07", editor.EditorSubtitleText.Text);
                Assert.True(editor.KeycapList.Items.Count > 30);
                Assert.Equal(
                    "APPR",
                    ((CodexKeycapDefinition)editor.KeycapList.SelectedItem).Id);
                Assert.True(typeof(CodexKeycapDefinition)
                    .GetProperty(nameof(CodexKeycapDefinition.IconId))!
                    .GetMethod!.IsPublic);
                Assert.Equal(
                    "FAST",
                    ((CodexKeycapDefinition)editor.KeycapList.Items[0]).IconId);
                Assert.True(editor.ActionCombo.Items.Count > 10);
                Assert.Equal(940, editor.Width, 3);
                Assert.Equal(820, editor.Height, 3);

                editor.SearchBox.Text = "LAB";
                var filteredKeycap = Assert.Single(
                    editor.KeycapList.Items.Cast<CodexKeycapDefinition>());
                Assert.Equal("LAB", filteredKeycap.Id);

                var previewPath = Environment.GetEnvironmentVariable(
                    "CODEX_MICRO_KEYCAP_EDITOR_PREVIEW");
                if (!string.IsNullOrWhiteSpace(previewPath))
                {
                    editor.SearchBox.Text = string.Empty;
                    editor.UpdateLayout();
                    var bitmap = new RenderTargetBitmap(
                        940,
                        820,
                        96,
                        96,
                        PixelFormats.Pbgra32);
                    bitmap.Render(root);
                    var encoder = new PngBitmapEncoder();
                    encoder.Frames.Add(BitmapFrame.Create(bitmap));
                    Directory.CreateDirectory(Path.GetDirectoryName(previewPath)!);
                    using var stream = File.Create(previewPath);
                    encoder.Save(stream);
                }

                editor.Close();
            }
            catch (Exception exception)
            {
                error = exception;
            }
        });
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        thread.Join();

        Assert.Null(error);
    }

    private static string WriteModelsCache(string directory)
    {
        Directory.CreateDirectory(directory);
        var path = Path.Combine(directory, "models_cache.json");
        File.WriteAllText(
            path,
            """
            {
              "models": [
                {
                  "slug": "gpt-5.6-sol",
                  "supported_reasoning_levels": [
                    { "effort": "low" },
                    { "effort": "medium" },
                    { "effort": "high" },
                    { "effort": "xhigh" },
                    { "effort": "max" },
                    { "effort": "ultra" }
                  ]
                },
                {
                  "slug": "gpt-5.6-terra",
                  "supported_reasoning_levels": [
                    { "effort": "low" },
                    { "effort": "medium" },
                    { "effort": "high" },
                    { "effort": "xhigh" },
                    { "effort": "max" },
                    { "effort": "ultra" }
                  ]
                },
                {
                  "slug": "gpt-5.6-luna",
                  "supported_reasoning_levels": [
                    { "effort": "low" },
                    { "effort": "medium" },
                    { "effort": "high" },
                    { "effort": "xhigh" },
                    { "effort": "max" }
                  ]
                }
              ]
            }
            """);
        return path;
    }
}
