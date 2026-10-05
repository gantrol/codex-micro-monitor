using System.Windows;
using CodexMicro.Codex;
using CodexMicro.Desktop;
using CodexMicro.Desktop.Services;

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        if (args is ["--running-controls-inspect", var inspectReport])
            return Task.Run(() => RunningControlsVerification.InspectAsync(inspectReport)).GetAwaiter().GetResult();
        if (args is ["--running-controls-e2e", var controlsReport])
            return Task.Run(() => RunningControlsE2e.RunAsync(controlsReport)).GetAwaiter().GetResult();
        if (args is ["--native-composer-probe"])
            return Task.Run(RunningControlsE2e.ProbeAsync).GetAwaiter().GetResult();
        var startup = System.Diagnostics.Stopwatch.StartNew();
        var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        var profile = MicroProfileSettings.CreateTransient();
        var window = new MicroSurfaceWindow(new(MicroLanguage.ZhCn),
            profileSettings: profile, transport: new SoftwareMicroTransport())
        {
            // Make this test host discoverable by desktop automation; use the product's window and controls.
            ShowInTaskbar = true,
            Title = "Micro Live Smoke",
        };
        var constructedMs = startup.ElapsedMilliseconds;
        if (args.Length > 0)
        {
            var startupFast = args.Length == 2 && args[0] == "--startup-fast";
            var draft = args.Length is 3 or 5 && args[0] == "--draft" && Guid.TryParse(args[1], out _);
            var lights = args.Length == 4 && args[0] == "--lights" &&
                Guid.TryParse(args[1], out _) && Guid.TryParse(args[2], out _);
            if (!startupFast && !draft && !lights && (args.Length != 4 || args.Take(3).Any(value => !Guid.TryParse(value, out _))))
                throw new ArgumentException("Expected: idle-thread-id second-idle-thread-id restore-thread-id report-path");
            EventHandler? run = null;
            run = async (_, _) =>
            {
                window.ContentRendered -= run;
                var exit = startupFast ? await StartupFastVerification.RunAsync(window, startup, constructedMs, args[1])
                    : lights ? await LightVerification.RunAsync(window, args[1], args[2], args[3]) : draft
                    ? await DraftVerification.RunAsync(window, profile, args[1], args[2],
                        args.Length == 5 ? args[3] : null, args.Length == 5 ? args[4] : null)
                    : await ReversibleVerification.RunAsync(window, args[0], args[1], args[2], args[3]);
                app.Shutdown(exit);
            };
            window.ContentRendered += run;
        }
        else window.Closed += (_, _) => app.Shutdown();
        window.Show();
        return app.Run();
    }
}
