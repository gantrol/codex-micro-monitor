using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.Json.Nodes;
using CodexMicro.Desktop.Services;

namespace CodexMicro.Codex;

internal sealed class LocalAppServer : IAsyncDisposable
{
    private Process? _process;
    private long _requestId;

    internal async Task<JsonNode> CallAsync(string method, object parameters, CancellationToken cancellationToken)
    {
        if (_process is null)
        {
            var executable = CodexExecutableResolver.Resolve() ?? throw new IOException("Codex CLI is unavailable");
            if (executable.Contains("trash", StringComparison.OrdinalIgnoreCase)) throw new IOException("Invalid Codex path");
            var start = new ProcessStartInfo(executable)
            {
                UseShellExecute = false, CreateNoWindow = true, WindowStyle = ProcessWindowStyle.Hidden,
                RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true,
                StandardInputEncoding = new UTF8Encoding(false), StandardOutputEncoding = new UTF8Encoding(false)
            };
            start.ArgumentList.Add("app-server");
            start.ArgumentList.Add("--stdio");
            _process = Process.Start(start) ?? throw new IOException("Cannot start Codex app-server");
            _process.BeginErrorReadLine();
            await ExchangeAsync("initialize", new
            {
                clientInfo = new { name = "codex-micro-plugin", title = "Codex Micro Keypad", version = "0.3.0" },
                capabilities = new { experimentalApi = true },
            }, cancellationToken);
            await _process.StandardInput.WriteLineAsync("{\"method\":\"initialized\",\"params\":{}}");
        }
        return await ExchangeAsync(method, parameters, cancellationToken);
    }

    private async Task<JsonNode> ExchangeAsync(string method, object parameters, CancellationToken cancellationToken)
    {
        var process = _process ?? throw new IOException("Codex app-server is unavailable");
        var id = ++_requestId;
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(20));
        try
        {
            await process.StandardInput.WriteLineAsync(JsonSupport.Node(new { id, method, @params = parameters }).ToJsonString().AsMemory(), timeout.Token);
            await process.StandardInput.FlushAsync(timeout.Token);
            while (true)
            {
                var line = await process.StandardOutput.ReadLineAsync(timeout.Token) ?? throw new IOException("Codex app-server closed");
                if (line.Length > 16 * 1024 * 1024) throw new IOException("Oversized Codex response");
                var message = JsonNode.Parse(line);
                if (message?["id"]?.ToJsonString() != id.ToString(System.Globalization.CultureInfo.InvariantCulture)) continue;
                if (message["error"] is { } error) throw new IOException(error.Text("message") ?? "Codex rejected the request");
                return message["result"]?.DeepClone() ?? new JsonObject();
            }
        }
        catch
        {
            await DisposeAsync();
            throw;
        }
    }

    public async ValueTask DisposeAsync()
    {
        var process = _process;
        _process = null;
        if (process is null) return;
        try
        {
            process.StandardInput.Close();
            await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(2));
        }
        catch (Exception error) when (error is TimeoutException or InvalidOperationException or IOException)
        {
            if (!process.HasExited) process.Kill(entireProcessTree: true);
        }
        finally { process.Dispose(); }
    }
}
