using System.Collections.Concurrent;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Automation;

namespace CodexMicro.Desktop.Services;

internal sealed class CodexQuestionSkipObserver : IDisposable
{
    private sealed record RefreshRequest(
        IReadOnlyList<CodexMonitoredQuestion> Questions,
        int Generation,
        TaskCompletionSource Completion);

    private sealed class Subscription(
        AutomationElement button, CodexMonitoredQuestion question)
    {
        internal AutomationElement Button { get; } = button;
        internal CodexMonitoredQuestion Question { get; } = question;
        internal AutomationEventHandler Handler { get; set; } = null!;
        internal bool HandlerAttached { get; set; }
        internal int Active = 1;
        internal int Resolved;
    }

    private sealed record PointerTarget(
        string RuntimeId, nint Window, Rect Bounds, Subscription Subscription, long ObservedAt);

    private sealed record PendingClick(PointerTarget Target, long ReleasedAt);

    private readonly object _sync = new();
    private readonly BlockingCollection<RefreshRequest> _requests = new();
    private readonly Dictionary<string, Subscription> _subscriptions = new(StringComparer.Ordinal);
    private readonly ConcurrentQueue<PendingClick> _clicks = new();
    private PointerTarget[] _pointerTargets = [];
    private PointerTarget? _pressedTarget;
    private Thread? _worker;
    private int _generation;
    private volatile bool _disposed;

    internal event Action<CodexMonitoredQuestion>? QuestionSkipped;

    // Called by the existing mouse hook. Only inspect cached geometry and HWNDs
    // here; UIA and confirmation run on the observer's background thread.
    internal void ObservePointer(RoutedDialPointerInput input)
    {
        if (_disposed) return;
        if (input.Action == RoutedDialPointerAction.Pressed)
        {
            _pressedTarget = Volatile.Read(ref _pointerTargets).FirstOrDefault(target =>
                Environment.TickCount64 - target.ObservedAt <= 1000 &&
                Volatile.Read(ref target.Subscription.Active) == 1 &&
                IsTargetWindow(target, input.ScreenPoint));
        }
        else if (input.Action == RoutedDialPointerAction.Released)
        {
            var pressed = _pressedTarget;
            _pressedTarget = null;
            if (pressed is not null && IsTargetWindow(pressed, input.ScreenPoint))
                _clicks.Enqueue(new(pressed, Environment.TickCount64));
        }
    }

    private static bool IsTargetWindow(PointerTarget target, Point point) =>
        target.Bounds.Contains(point) && GetForegroundWindow() == target.Window &&
        GetAncestor(WindowFromPoint(new((int)point.X, (int)point.Y)), 2) == target.Window;

    internal Task RefreshAsync(IReadOnlyList<CodexMonitoredQuestion> questions)
    {
        lock (_sync)
        {
            if (_disposed || (_worker is null && questions.Count == 0))
            {
                return Task.CompletedTask;
            }

            var completion = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            _requests.Add(new(questions, Interlocked.Increment(ref _generation), completion));
            if (_worker is null)
            {
                _worker = new Thread(Observe) { IsBackground = true, Name = nameof(CodexQuestionSkipObserver) };
                _worker.SetApartmentState(ApartmentState.MTA);
                _worker.Start();
            }
            return completion.Task;
        }
    }

    private void Observe()
    {
        try
        {
            foreach (var request in _requests.GetConsumingEnumerable())
            {
                try
                {
                    if (request.Generation == Volatile.Read(ref _generation))
                    {
                        Refresh(request);
                    }
                }
                catch (Exception exception) when (IsUnavailable(exception))
                {
                    RemoveSubscriptions([]);
                }
                finally
                {
                    request.Completion.TrySetResult();
                }
            }
        }
        finally
        {
            Volatile.Write(ref _pointerTargets, []);
            RemoveSubscriptions([]);
            _requests.Dispose();
        }
    }

    private void Refresh(RefreshRequest request)
    {
        var matches = new Dictionary<string, (AutomationElement Button, CodexMonitoredQuestion Question, Rect Bounds)>();
        var window = request.Questions.Count == 0
            ? nint.Zero : CodexWindowActivator.CaptureForegroundWindow();
        if (window != nint.Zero)
        {
            var root = AutomationElement.FromHandle(window);
            var buttons = root.FindAll(TreeScope.Descendants,
                new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Button));
            foreach (AutomationElement button in buttons)
            {
                if (request.Generation != Volatile.Read(ref _generation))
                {
                    return;
                }
                if (button.Current.IsOffscreen || !button.Current.IsEnabled || !IsSkip(button.Current.Name))
                {
                    continue;
                }

                var card = TreeWalker.RawViewWalker.GetParent(button);
                for (var depth = 0; card is not null && depth < 16; depth++)
                {
                    if ((card.Current.ClassName ?? string.Empty).Contains(
                            "@container/request-card", StringComparison.Ordinal))
                    {
                        var text = card.FindAll(TreeScope.Descendants,
                            new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Text));
                        var visibleText = Normalize(string.Concat(text.Cast<AutomationElement>()
                            .Where(element => !element.Current.IsOffscreen)
                            .Select(element => element.Current.Name)));
                        var questions = request.Questions.Where(question =>
                            Normalize(question.Question.Title) is { Length: > 0 } title &&
                            visibleText.Contains(title, StringComparison.Ordinal)).Take(2).ToArray();
                        if (questions.Length == 1)
                        {
                            matches[string.Join(",", button.GetRuntimeId())] =
                                (button, questions[0], button.Current.BoundingRectangle);
                        }
                        break;
                    }
                    card = TreeWalker.RawViewWalker.GetParent(card);
                }
            }
        }

        if (request.Generation != Volatile.Read(ref _generation))
        {
            return;
        }

        // Skip can unmount its button before an Invoked event is delivered.
        // Require a press/release on that exact button AND a changed card.
        // A timeout, Escape, scrolling or navigation alone is never a skip.
        for (var remaining = _clicks.Count; remaining > 0 && _clicks.TryDequeue(out var click); remaining--)
        {
            var target = click.Target;
            if (window != target.Window || !CodexWindowActivator.IsForegroundWindow(window) ||
                !request.Questions.Contains(target.Subscription.Question) ||
                Environment.TickCount64 - click.ReleasedAt > 2000)
                continue;
            if (!matches.TryGetValue(target.RuntimeId, out var current) ||
                current.Question != target.Subscription.Question)
                ReportSkipped(target.Subscription);
            else
                _clicks.Enqueue(click);
        }

        RemoveSubscriptions(matches.Where(pair => _subscriptions.TryGetValue(pair.Key, out var current) &&
            current.Question == pair.Value.Question).Select(pair => pair.Key).ToHashSet(StringComparer.Ordinal));
        foreach (var (key, match) in matches)
        {
            if (_subscriptions.ContainsKey(key))
            {
                continue;
            }

            var subscription = new Subscription(match.Button, match.Question);
            subscription.Handler = (_, _) =>
            {
                if (!_disposed && CodexWindowActivator.IsForegroundWindow(window) &&
                    Volatile.Read(ref subscription.Active) == 1)
                {
                    ReportSkipped(subscription);
                }
            };
            try
            {
                Automation.AddAutomationEventHandler(InvokePattern.InvokedEvent,
                    subscription.Button, TreeScope.Element, subscription.Handler);
                subscription.HandlerAttached = true;
            }
            catch (Exception exception) when (IsUnavailable(exception))
            {
                // The native pointer observation can still confirm a click
                // when this provider does not support Invoke notifications.
            }
            _subscriptions.Add(key, subscription);
        }
        Volatile.Write(ref _pointerTargets, matches.Select(pair => new PointerTarget(
            pair.Key, window, pair.Value.Bounds, _subscriptions[pair.Key], Environment.TickCount64)).ToArray());
    }

    private void ReportSkipped(Subscription subscription)
    {
        if (!_disposed && Interlocked.Exchange(ref subscription.Resolved, 1) == 0)
            QuestionSkipped?.Invoke(subscription.Question);
    }

    private void RemoveSubscriptions(HashSet<string> retained)
    {
        foreach (var key in _subscriptions.Keys.Where(key => !retained.Contains(key)).ToArray())
        {
            var subscription = _subscriptions[key];
            Interlocked.Exchange(ref subscription.Active, 0);
            try
            {
                if (subscription.HandlerAttached)
                    Automation.RemoveAutomationEventHandler(InvokePattern.InvokedEvent,
                        subscription.Button, subscription.Handler);
            }
            catch (Exception exception) when (IsUnavailable(exception))
            {
            }
            _subscriptions.Remove(key);
        }
    }

    private static bool IsSkip(string? name) =>
        name is "Skip" or "跳过" or "跳過" or "略過" ||
        name?.StartsWith("Skip, ", StringComparison.OrdinalIgnoreCase) == true ||
        name?.StartsWith("跳过，", StringComparison.Ordinal) == true ||
        name?.StartsWith("跳過，", StringComparison.Ordinal) == true ||
        name?.StartsWith("略過，", StringComparison.Ordinal) == true;

    private static string Normalize(string text) =>
        string.Concat(text.Where(character => !char.IsWhiteSpace(character)));

    private static bool IsUnavailable(Exception exception) =>
        exception is ElementNotAvailableException or InvalidOperationException or
            COMException or Win32Exception or ArgumentException or UnauthorizedAccessException or
            System.Security.SecurityException;

    [StructLayout(LayoutKind.Sequential)]
    private readonly record struct NativePoint(int X, int Y);

    [DllImport("user32.dll")]
    private static extern nint GetForegroundWindow();

    [DllImport("user32.dll")]
    private static extern nint WindowFromPoint(NativePoint point);

    [DllImport("user32.dll")]
    private static extern nint GetAncestor(nint window, uint flags);

    public void Dispose()
    {
        lock (_sync)
        {
            if (_disposed)
            {
                return;
            }
            _disposed = true;
            Volatile.Write(ref _pointerTargets, []);
            _pressedTarget = null;
            _clicks.Clear();
            Interlocked.Increment(ref _generation);
            _requests.CompleteAdding();
            if (_worker is null)
            {
                _requests.Dispose();
            }
        }
    }
}
