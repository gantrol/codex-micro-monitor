using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Net.Http;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Effects;
using System.Windows.Shapes;
using CodexMicro.Control;
using CodexMicro.Desktop.Controls;
using CodexMicro.Desktop.Services;
using CodexMicro.Protocol;

namespace CodexMicro.Desktop;

internal readonly record struct QuickModelPresentationState(
    string? ThreadId,
    CodexQuickModel Model);

public partial class MicroSurfaceWindow : Window
{
    private static readonly TimeSpan EncoderStepInterval =
        TimeSpan.FromMilliseconds(24);
    private static readonly TimeSpan EncoderIntentMaximumAge =
        TimeSpan.FromMilliseconds(180);
    private TimeSpan CurrentEncoderIntentMaximumAge => TimeSpan.FromSeconds(5);
    private static readonly TimeSpan QuotaRefreshInterval =
        TimeSpan.FromMinutes(2);
    private static readonly TimeSpan HarnessStateRefreshInterval =
        TimeSpan.FromSeconds(1);
    private static readonly TimeSpan VoiceServiceHealthRefreshInterval =
        TimeSpan.FromSeconds(5);
    private static readonly TimeSpan ForegroundRefreshInterval =
        TimeSpan.FromMilliseconds(250);
    private static readonly TimeSpan SettingsLongPressThreshold =
        TimeSpan.FromMilliseconds(650);
    private static readonly TimeSpan AgentDoubleTapThreshold =
        TimeSpan.FromMilliseconds(520);
    private static readonly TimeSpan NewTaskDraftLeaseWait =
        TimeSpan.FromSeconds(2);
    private static readonly TimeSpan NewTaskNavigationEpochLifetime =
        TimeSpan.FromSeconds(5);
    private const double StatusLedGlowBlurRadius = 8;
    private const double StatusLedGlowOpacity = 0.78;

    private static readonly StatusLedAppearance NeutralStatusLed =
        new(Color.FromRgb(0xB8, 0xB9, 0x8B), Glow: false);
    private static readonly StatusLedAppearance HealthyStatusLed =
        new(Color.FromRgb(0x78, 0xA6, 0xFF), Glow: true);
    private static readonly StatusLedAppearance ActiveStatusLed =
        new(Color.FromRgb(0x30, 0x4F, 0xFE), Glow: true);
    private static readonly StatusLedAppearance WaitingStatusLed =
        new(Color.FromRgb(0xFF, 0xC8, 0x5A), Glow: true);
    private static readonly StatusLedAppearance ErrorStatusLed =
        new(Color.FromRgb(0xFF, 0x79, 0x94), Glow: true);

    private readonly record struct JoystickReport(
        double Angle,
        double Distance,
        string Label);

    private readonly record struct SettingsDisplayProgress(
        int Version,
        int Step,
        int TotalSteps,
        string Text,
        string Detail,
        MicroHarnessDispatchStage Stage);

    private readonly record struct VoiceSurfaceStatus(
        int Version,
        string Text,
        string Detail,
        MicroHarnessDispatchStage Stage,
        int? Step,
        int? TotalSteps);

    private readonly record struct HarnessVoiceResult(
        bool Success,
        bool Active,
        string Message);

    private readonly record struct StatusLedAppearance(
        Color Color,
        bool Glow);

    private readonly record struct NewTaskNavigationEpoch(
        IntPtr ForegroundWindow,
        DateTimeOffset DispatchedAt);

    private enum KeypadVoiceServiceState
    {
        Unconfigured,
        Checking,
        Ready,
        Listening,
        Unavailable,
        Error,
    }

    private readonly IMicroTransport _broker;
    private readonly MicroLocalization _localization;
    private readonly DialDirectionSettings _dialDirectionSettings;
    private readonly MicroProfileSettings _profileSettings;
    private readonly Action<string>? _openHarnessInNewKeypad;
    private readonly Action? _closeKeypad;
    private readonly string _keypadDisplayName;
    private readonly bool _canCloseKeypad;
    private readonly CodexMicroConfigWriter _configWriter;
    private readonly MicroHarnessRegistry _harnessRegistry;
    private readonly SemaphoreSlim _externalVoiceGate = new(1, 1);
    private readonly SemaphoreSlim _streamingDictationGate = new(1, 1);
    private readonly Dictionary<FrameworkElement, (string Title, string Detail)>
        _helpContent = [];
    private readonly CodexMicroLayoutObserver _layoutObserver = new();
    private readonly CodexMenuSelectionObserver _menuSelectionObserver = new();
    private readonly CodexQuotaService _quotaService = new();
    private readonly CodexModelToggleService _modelToggleService = new();
    private readonly CodexDraftComposerModelSelector
        _draftComposerModelSelector = new();
    private readonly DialGestureTracker _dialGesture = new();
    private readonly EncoderStepAccumulator _encoderSteps = new(3);
    private readonly SemaphoreSlim _encoderInputGate = new(1, 1);
    private readonly System.Windows.Threading.DispatcherTimer
        _dialSelectionHideTimer = new()
        {
            Interval = TimeSpan.FromMilliseconds(2400),
        };
    private readonly System.Windows.Threading.DispatcherTimer
        _quotaRefreshTimer = new()
        {
            Interval = QuotaRefreshInterval,
        };
    private readonly System.Windows.Threading.DispatcherTimer
        _harnessStateRefreshTimer = new()
        {
            Interval = HarnessStateRefreshInterval,
        };
    private readonly System.Windows.Threading.DispatcherTimer
        _voiceServiceHealthRefreshTimer = new()
        {
            Interval = VoiceServiceHealthRefreshInterval,
        };
    private readonly System.Windows.Threading.DispatcherTimer
        _harnessActionElapsedTimer = new()
        {
            Interval = TimeSpan.FromMilliseconds(500),
        };
    private readonly System.Windows.Threading.DispatcherTimer
        _foregroundRefreshTimer = new()
        {
            Interval = ForegroundRefreshInterval,
        };
    private readonly object _harnessActivationSync = new();
    private readonly LinkedList<JoystickReport> _joystickReportQueue = new();
    private readonly IReadOnlyDictionary<string, (Button Button, KeycapIcon Icon)>
        _actionKeys;
    private readonly IReadOnlyDictionary<string, Button> _joystickButtons;
    private readonly KeycapIcon[] _brandAwareIcons;
    private readonly Brush _codexDeviceFrameBackground;
    private readonly Brush _codexPearlLightGuideBackground;
    private readonly Brush _codexCrystalDepthBackground;
    private readonly Brush _codexCrystalPrismBorder;
    private readonly Brush _codexLowerRefractionBackground;
    private Button[] _agentKeys = [];
    private Border[] _agentWideGlows = [];
    private Border[] _agentNearGlows = [];
    private readonly ManualUnreadThreadTracker _manualUnreadThreads = new();
    private InactiveDialInputRouter? _inactiveDialInputRouter;
    private MicroSettingsWindow? _settingsWindow;
    private HwndSource? _windowSource;
    private bool _connecting;
    private bool _joystickDragging;
    private bool _joystickHasReportedState;
    private bool _joystickReportPumpActive;
    private bool _voicePressed;
    private Button? _voicePressedButton;
    private string? _voicePhysicalKey;
    private KeypadVoiceServiceState _voiceServiceState =
        KeypadVoiceServiceState.Unconfigured;
    private string _voiceServiceMessage =
        "请先在小键盘中完成语音配置。";
    private int _voiceDispatchStatusVersion;
    private int _joystickFeedbackVersion;
    private long _dialWheelRouteSequence;
    private long _lastSlotLightingSequence;
    private SlotLightingSnapshot? _latestSlotLighting;
    private CodexAgentRosterSnapshot? _latestAgentRoster;
    private int? _currentAgentSlotId;
    private int _dialSelectionFeedbackVersion;
    private int _dialSelectionHudVersion;
    private bool _encoderStepPumpRunning;
    private string? _dialSelectionText;
    private CancellationTokenSource? _quotaRefreshCancellation;
    private CancellationTokenSource? _modelActionCancellation;
    private CodexQuotaSnapshot? _quotaSnapshot;
    private MicroHarnessStateSnapshot? _harnessStateSnapshot;
    private string? _selectedHarnessSessionId;
    private string _activeHarnessContextId = "codex";
    private bool _quotaRefreshFailed;
    private CodexQuickModel _quickModel;
    private string? _quickModelEffort;
    private string? _quickModelThreadId;
    private bool _quickModelSwitching;
    private string? _quickModelSwitchingThreadId;
    private long _settingsPointerDownTimestamp;
    private int _backgroundServicesStarted;
    private long _lastAgentTapTimestamp;
    private string? _lastAgentTapKey;
    private string? _suppressedHarnessSelectionId;
    private int _harnessActionStatusVersion;
    private DateTimeOffset _harnessActionStartedAt;
    private string _harnessActionBaseText = string.Empty;
    private SettingsDisplayProgress? _settingsDisplayProgress;
    private VoiceSurfaceStatus? _voiceSurfaceStatus;
    private bool _actionTargetIsForeground;
    private IntPtr _lastForegroundWindow;
    private bool _windowClosed;
    private readonly TaskCompletionSource<bool> _closeCompletion = new(
        TaskCreationOptions.RunContinuationsAsynchronously);
    private int _closeCleanupStarted;
    private bool _allowApplicationClose;
    private bool _voiceCloseReleasePending;
    private bool _windowMoving;
    private Point _windowMoveStartScreen;
    private Point _windowMoveStartPosition;
    private DpiScale _windowMoveDpi;
    private Point _joystickDragOrigin;
    private string? _joystickActiveDirection;
    private double _dialVisualAngle = 42;
    private string _transportName = "Codex IPC";
    private string _status = "正在连接 Codex。";

    public MicroSurfaceWindow()
        : this(
            new MicroLocalization(),
            MicroProfileSettings.CreateTransient())
    {
    }

    internal MicroSurfaceWindow(
        MicroLocalization localization,
        MicroProfileSettings? profileSettings = null,
        Action<string>? openHarnessInNewKeypad = null,
        Action? closeKeypad = null,
        string? keypadDisplayName = null,
        bool canCloseKeypad = false,
        IMicroTransport? transport = null,
        Func<Task<bool>>? activateSoftwareApplication = null,
        Func<CancellationToken, Task<string?>>? readSoftwareSelection = null)
    {
        _broker = transport ?? new CodexMicro.Codex.SoftwareMicroTransport();
        _activateSoftwareApplication = activateSoftwareApplication ?? (() => ActivateCodexAsync(0, launchIfMissing: true));
        _readSoftwareSelection = readSoftwareSelection is null
            ? _softwareSelectionReader.ReadSelectionAsync
            : async token =>
            {
                var thread = await readSoftwareSelection(token);
                return new CodexThreadSelection(thread, thread);
            };
        _harnessRegistry = new MicroHarnessRegistry(codexOnly: true);
        _broker.CaptureContext = CaptureSoftwareContext;
        _broker.ThreadOpened = SelectSoftwareThread;
        _broker.ServiceTierApplied = _modelToggleService.ObserveServiceTierAcknowledged;
        _broker.ComposerFastApplied = ObserveComposerFastApplied;
        _broker.ValidateTargetAsync = ValidateSoftwareTargetAsync;
        _modelToggleService.ObserveSelectedThread(null);
        _status = _transportName = "Codex IPC";
        _localization = localization ??
            throw new ArgumentNullException(nameof(localization));
        _profileSettings = profileSettings ??
            MicroProfileSettings.CreateTransient();
        _dialDirectionSettings = new DialDirectionSettings(
            _profileSettings.Current.InvertDialDirection);
        _openHarnessInNewKeypad = openHarnessInNewKeypad;
        _closeKeypad = closeKeypad;
        _keypadDisplayName = string.IsNullOrWhiteSpace(keypadDisplayName)
            ? (_localization.IsEnglish ? "Keypad 1" : "小键盘 1")
            : keypadDisplayName.Trim();
        _canCloseKeypad = canCloseKeypad;
        _configWriter = new CodexMicroConfigWriter(_layoutObserver.ConfigPath);
        InitializeComponent();
        Loaded += (_, _) => MicroWindowLayout.SizeKeypad(this, _profileSettings.Current.WindowScale);
        SizeChanged += (_, _) =>
        {
            if (_actionKeys is not null)
                foreach (var (_, icon) in _actionKeys.Values) icon.InvalidateVisual();
        };
        DpiChanged += (_, _) => Dispatcher.BeginInvoke(new Action(() =>
            MicroWindowLayout.SizeKeypad(this, _profileSettings.Current.WindowScale)));
        InitializeMonitorPage();
        _codexDeviceFrameBackground = DeviceFrame.Background;
        _codexPearlLightGuideBackground = PearlLightGuide.Background;
        _codexCrystalDepthBackground = CrystalDepthPlate.Background;
        _codexCrystalPrismBorder = CrystalPrismRim.BorderBrush;
        _codexLowerRefractionBackground = CrystalLowerRefraction.Background;
        Topmost = _profileSettings.Current.WindowTopmost;
        CloseKeypadMenuItem.Visibility = _canCloseKeypad
            ? Visibility.Visible
            : Visibility.Collapsed;
        if (_profileSettings.Current is
            {
                WindowLeft: { } savedLeft,
                WindowTop: { } savedTop,
            } &&
            double.IsFinite(savedLeft) &&
            double.IsFinite(savedTop))
        {
            WindowStartupLocation = WindowStartupLocation.Manual;
            Left = savedLeft;
            Top = savedTop;
        }
        _agentKeys =
        [
            AgentKey0,
            AgentKey1,
            AgentKey2,
            AgentKey3,
            AgentKey4,
            AgentKey5,
        ];
        _agentWideGlows =
        [
            AgentGlowWide0,
            AgentGlowWide1,
            AgentGlowWide2,
            AgentGlowWide3,
            AgentGlowWide4,
            AgentGlowWide5,
        ];
        _agentNearGlows =
        [
            AgentGlowNear0,
            AgentGlowNear1,
            AgentGlowNear2,
            AgentGlowNear3,
            AgentGlowNear4,
            AgentGlowNear5,
        ];
        InitializeTaskKeyMotion();
        _actionKeys = new Dictionary<string, (Button, KeycapIcon)>(StringComparer.Ordinal)
        {
            ["ACT06"] = (ActionKey06, ActionIcon06),
            ["ACT07"] = (ActionKey07, ActionIcon07),
            ["ACT08"] = (ActionKey08, ActionIcon08),
            ["ACT09"] = (ActionKey09, ActionIcon09),
            ["ACT10"] = (ActionKey10Split, ActionIcon10Split),
            ["ACT11"] = (ActionKey11Split, ActionIcon11Split),
            ["ACT10_ACT11"] = (ActionKey10, ActionIcon10),
            ["ACT12"] = (ActionKey12, ActionIcon12),
        };
        _joystickButtons = new Dictionary<string, Button>(StringComparer.Ordinal)
        {
            ["up"] = JoystickUp,
            ["right"] = JoystickRight,
            ["down"] = JoystickDown,
            ["left"] = JoystickLeft,
        };
        _brandAwareIcons =
        [
            BrandCodexIcon,
            ActionIcon06,
            ActionIcon07,
            ActionIcon08,
            ActionIcon09,
            ActionIcon10,
            ActionIcon10Split,
            ActionIcon11Split,
            ActionIcon12,
        ];
        _broker.Log += Broker_Log;
        _broker.StateChanged += Broker_StateChanged;
        _broker.SlotLightingObserved += Broker_SlotLightingObserved;
        _layoutObserver.LayoutChanged += LayoutObserver_LayoutChanged;
        _dialSelectionHideTimer.Tick += DialSelectionHideTimer_Tick;
        _quotaRefreshTimer.Tick += QuotaRefreshTimer_Tick;
        _harnessStateRefreshTimer.Tick += HarnessStateRefreshTimer_Tick;
        _voiceServiceHealthRefreshTimer.Tick +=
            VoiceServiceHealthRefreshTimer_Tick;
        _harnessActionElapsedTimer.Tick += HarnessActionElapsedTimer_Tick;
        _foregroundRefreshTimer.Tick += ForegroundRefreshTimer_Tick;
        _localization.LanguageChanged += Localization_LanguageChanged;
        _profileSettings.Changed += ProfileSettings_Changed;
        _harnessRegistry.Changed += HarnessRegistry_Changed;
        _modelToggleService.CurrentThreadStateChanged +=
            ModelToggleService_CurrentThreadStateChanged;
        RefreshLocalizedChrome();
        InitializeHoverHelp();
        ApplyCoreSurface();
        UpdateQuotaPresentation();
        ApplyLayout(_layoutObserver.Current);
        ApplyHarnessContext();
        SetStatus(_status);
    }

    private void InitializeHoverHelp()
    {
        for (var slotId = 0; slotId < _agentKeys.Length; slotId++)
        {
            SetHelp(
                _agentKeys[slotId],
                $"Agent 槽位 {slotId + 1}",
                $"AG{slotId:00} · 单击切换到该槽位；颜色由 Codex 状态同步。");
        }

        SetHelp(
            JoystickSurface,
            "模拟摇杆",
            "拖动黑色圆帽进行连续输入，或单击四周阴刻方向键。");
        SetHelp(
            JoystickCap,
            "模拟摇杆",
            "按住并向任意方向拖动，松开后自动回中。");
        SetHelp(
            SettingsKey,
            "Codex 额度与 Micro 设置",
            "短按：切换设置中的两个快捷模型。\n长按：打开官方 Micro 设置。\n右键：直达右下角当前 Agent 的软件设置。");
        SetHelp(RuntimeLed, "Codex 运行时握手", "正在等待 Codex 运行时能力信号。");
        SetHelp(DriverLed, "Codex IPC", "正在连接 Codex。");
        SetHelp(ActivityLed, "最近事件", "尚未发送事件。");
    }

    private async void Window_Loaded(object sender, RoutedEventArgs e)
    {
        _inactiveDialInputRouter ??= new InactiveDialInputRouter(
            RouteInactiveDialWheel,
            RouteInactiveDialPointer);
        if (_inactiveDialInputRouter.Start())
        {
            AutomationProperties.SetItemStatus(
                DialButton,
                Localize("未激活窗口滚轮捕获已就绪"));
        }
        else
        {
            AutomationProperties.SetItemStatus(
                DialButton,
                Localize(
                    $"旋钮输入捕获失败 · Win32 {_inactiveDialInputRouter.LastError}"));
            SetHelp(
                DialButton,
                "选择旋钮",
                "全局旋钮捕获未启动；仍可按住左键上下或左右拖动选择。\n短按：打开或确认。");
        }

        _layoutObserver.Start();
        ResolveCurrentAgentSlot();
        RefreshAgentSlotPresentation();
        ApplyHarnessContext();
        StartForegroundRefresh();
        PromptForHarnessSetupIfNeeded();
        RestartVoiceBridgeMonitor();
        RestartKeypadVoiceWarmUp();
        StartBackgroundServices();
        UpdateMonitorRefresh();
        await ConnectAsync();
    }

    private async void Window_Deactivated(object? sender, EventArgs e)
    {
        if (_joystickDragging)
        {
            EndJoystickDrag();
        }

        if (_dialGesture.IsPointerDown)
        {
            CancelDialGesture();
        }

        if (_voicePressed &&
            VoiceGesturePolicy.StopOnDeactivation(
                _profileSettings.Current.TapToToggleVoice))
        {
            await ReleaseVoiceAsync();
        }
    }

    private void Window_Closed(object? sender, EventArgs e)
    {
        _ = CompleteWindowCloseAsync();
    }

    private async Task CompleteWindowCloseAsync()
    {
        if (Interlocked.Exchange(ref _closeCleanupStarted, 1) != 0)
        {
            return;
        }

        _windowClosed = true;
        CancelReasoningInput();
        StopMonitorPage();
        try
        {
            await _broker.DisposeAsync();
        }
        catch (Exception exception)
        {
            Debug.WriteLine(
                $"Codex Micro broker close cleanup failed: {exception}");
        }

        _modelToggleService.CurrentThreadStateChanged -=
            ModelToggleService_CurrentThreadStateChanged;
        try
        {

            _modelActionCancellation?.Cancel();
            _settingsWindow?.Close();
            _settingsWindow = null;
            _encoderSteps.Clear();
            _dialSelectionFeedbackVersion++;
            _dialSelectionHideTimer.Stop();
            _dialSelectionHideTimer.Tick -= DialSelectionHideTimer_Tick;
            PauseQuotaRefresh();
            PauseHarnessStateRefresh();
            _quotaRefreshTimer.Tick -= QuotaRefreshTimer_Tick;
            _harnessStateRefreshTimer.Tick -= HarnessStateRefreshTimer_Tick;
            _voiceServiceHealthRefreshTimer.Tick -=
                VoiceServiceHealthRefreshTimer_Tick;
            _harnessActionElapsedTimer.Stop();
            _harnessActionElapsedTimer.Tick -= HarnessActionElapsedTimer_Tick;
            PauseForegroundRefresh();
            _foregroundRefreshTimer.Tick -= ForegroundRefreshTimer_Tick;
            if (_windowSource is not null)
            {
                _windowSource.RemoveHook(WindowMessageHook);
                _windowSource = null;
            }

            _inactiveDialInputRouter?.Dispose();
            _inactiveDialInputRouter = null;
            _joystickReportQueue.Clear();
            _layoutObserver.LayoutChanged -= LayoutObserver_LayoutChanged;
            _layoutObserver.Dispose();
            _localization.LanguageChanged -= Localization_LanguageChanged;
            _profileSettings.Changed -= ProfileSettings_Changed;
            _harnessRegistry.Changed -= HarnessRegistry_Changed;
        }
        catch (Exception exception)
        {
            Debug.WriteLine(
                $"Codex Micro close cleanup failed: {exception}");
        }
        finally
        {

            try
            {
                await _modelToggleService.DisposeAsync();
            }
            catch (Exception exception)
            {
                Debug.WriteLine(
                    $"Codex Micro model bridge cleanup failed: {exception}");
            }

            try
            {
                _externalVoiceGate.Dispose();
            }
            catch (ObjectDisposedException)
            {
                // Cleanup is idempotent when shutdown paths converge.
            }

            _closeCompletion.TrySetResult(true);
        }
    }

    private void Window_IsVisibleChanged(
        object sender,
        DependencyPropertyChangedEventArgs e)
    {
        UpdateMonitorRefresh();
        if (e.NewValue is true)
        {
            StartQuotaRefresh();
            StartHarnessStateRefresh();
            StartForegroundRefresh();
        }
        else
        {
            CancelReasoningInput();
            PauseQuotaRefresh();
            PauseHarnessStateRefresh();
            PauseForegroundRefresh();
        }
    }

    private void StartForegroundRefresh()
    {
        if (_windowClosed || !IsVisible)
        {
            return;
        }

        RefreshActionTargetForegroundState();
        RefreshTopmostContinuity();
        _foregroundRefreshTimer.Start();
    }

    private void PauseForegroundRefresh()
    {
        _foregroundRefreshTimer.Stop();
        _lastForegroundWindow = IntPtr.Zero;
    }

    private void ForegroundRefreshTimer_Tick(
        object? sender,
        EventArgs e)
    {
        RefreshActionTargetForegroundState();
        RefreshTopmostContinuity();
        RefreshDraftQuickModelObservation();
        RefreshSoftwareThreadSelection();
    }

    private void RefreshActionTargetForegroundState()
    {
        var harness = ActiveHarness();
        ApplyActionTargetForegroundPresentation(
            IsHarnessForeground(harness));
    }

    private void RefreshTopmostContinuity()
    {
        var foregroundWindow =
            NonActivatingWindow.GetForegroundWindowHandle();
        if (foregroundWindow == _lastForegroundWindow)
        {
            return;
        }

        _lastForegroundWindow = foregroundWindow;
        _ = NonActivatingWindow.ReassertTopmostAfterForegroundChange(
            _windowSource?.Handle ?? IntPtr.Zero,
            foregroundWindow,
            Topmost && IsVisible);
    }

    private void ApplyActionTargetForegroundPresentation(bool isForeground)
    {
        if (_actionTargetIsForeground == isForeground)
        {
            return;
        }

        _actionTargetIsForeground = isForeground;
        RefreshActionKeyPresentation();
    }

    internal void ApplyActionTargetForegroundForVisualTest(bool isForeground) =>
        ApplyActionTargetForegroundPresentation(isForeground);

    private void StartQuotaRefresh()
    {
        if (_windowClosed ||
            !IsVisible)
        {
            return;
        }

        _quotaRefreshTimer.Start();
        _ = RefreshQuotaAsync();
    }

    private void PauseQuotaRefresh()
    {
        _quotaRefreshTimer.Stop();
        _quotaRefreshCancellation?.Cancel();
    }

    private void QuotaRefreshTimer_Tick(object? sender, EventArgs e)
    {
        _ = RefreshQuotaAsync();
    }

    private void StartHarnessStateRefresh()
    {
        {
            return;
        }
    }

    private void PauseHarnessStateRefresh()
    {
        _harnessStateRefreshTimer.Stop();
        _voiceServiceHealthRefreshTimer.Stop();


    }

    private void HarnessStateRefreshTimer_Tick(object? sender, EventArgs e)
    {
        _ = RefreshHarnessStateAsync();
    }

    private void VoiceServiceHealthRefreshTimer_Tick(object? sender, EventArgs e)
    {
        _ = RefreshVoiceServiceHealthAsync();
    }

    private async Task RefreshHarnessStateAsync()
    {
        var harness = ActiveHarness();
        {
            return;
        }
    }

    private async Task RefreshVoiceServiceHealthAsync()
{ await Task.CompletedTask; }
    private async Task RefreshQuotaAsync()
    {
        if (_windowClosed ||
            !IsVisible ||
            _quotaRefreshCancellation is not null)
        {
            return;
        }

        var refresh = new CancellationTokenSource();
        _quotaRefreshCancellation = refresh;
        try
        {
            if (_reasoningCatalog is not { IsFresh: true })
            {
                // The catalog loader reads a small local cache synchronously.
                // Keep that I/O off the UI thread and preserve newer action results.
                var catalog = await Task.Run(() => CodexModelCatalog.Load());
                if (refresh.IsCancellationRequested || _windowClosed)
                {
                    return;
                }
                if (_reasoningCatalog is not { IsFresh: true })
                {
                    _reasoningCatalog = catalog;
                }
                UpdateQuotaPresentation();
            }

            var snapshot = await _quotaService.ReadAsync(refresh.Token);
            if (refresh.IsCancellationRequested || _windowClosed)
            {
                return;
            }

            _quotaRefreshFailed = snapshot is null;
            if (snapshot is not null)
            {
                _quotaSnapshot = snapshot;
            }

            UpdateQuotaPresentation();
        }
        finally
        {
            if (ReferenceEquals(_quotaRefreshCancellation, refresh))
            {
                _quotaRefreshCancellation = null;
            }

            var retryAfterQuickReshow =
                refresh.IsCancellationRequested && IsVisible && !_windowClosed;
            refresh.Dispose();
            if (retryAfterQuickReshow)
            {
                _ = RefreshQuotaAsync();
            }
        }
    }

    private async Task ConnectAsync()
    {
        {
            await ConnectSoftwareAsync();
            return;
        }
    }

    private async void Key_Click(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: string key })
        {
            var isAgentKey = TryParseAgentSlot(key, out var selectedSlot);
            if (isAgentKey && (_taskKeyMotionActive || _pageSwitching))
            {
                return;
            }
            var selectedAgentThreadId = isAgentKey
                ? _latestAgentRoster?.GetSlot(selectedSlot)?.ThreadId
                : null;
            var harness = ActiveHarness();
            var isComposerTextKey = IsCodexComposerTextKey(
                key,
                _layoutObserver.Current);
            var focusAgentAfterTap = isAgentKey && ShouldFocusAgentAfterTap(key);
            var agentFocusResolvedBeforeTap = false;
            try
            {

                {
                    agentFocusResolvedBeforeTap = true;
                    await HandleSoftwareKeyAsync(key, isAgentKey);
                    return;
                }

            }
            finally
            {
                // Keep a safety net for failures that occur before Agent focus
                // can be resolved. Normal Agent dispatch activates before HID.
                if (focusAgentAfterTap &&
                    !agentFocusResolvedBeforeTap)
                {
                    _ = await ActivateCodexAsync(
                        initialDelayMilliseconds: isAgentKey ? 0 : 90);
                }
            }
        }
    }

    private async void Voice_PreviewMouseLeftButtonDown(
        object sender,
        MouseButtonEventArgs e)
    {
        e.Handled = true;
        if (e.LeftButton != MouseButtonState.Pressed ||
            sender is not Button button)
        {
            return;
        }

        var decision = VoiceGesturePolicy.Press(
            _profileSettings.Current.TapToToggleVoice,
            _voicePressed,
            false);
        if (decision == VoicePressDecision.Ignore)
        {
            return;
        }
        if (decision == VoicePressDecision.Stop)
        {
            await ReleaseVoiceAsync();
            return;
        }

        await HandleSoftwareKeyAsync(button.Tag as string ?? "ACT10_ACT11", agentKey: false);
    }

    private async void Voice_PreviewMouseLeftButtonUp(
        object sender,
        MouseButtonEventArgs e)
    {
        e.Handled = true;
        if (!VoiceGesturePolicy.StopOnRelease(
                _profileSettings.Current.TapToToggleVoice))
        {
            if (sender is Button button && Mouse.Captured == button)
            {
                button.ReleaseMouseCapture();
            }
            return;
        }
        await ReleaseVoiceAsync();
    }

    private async void Voice_LostMouseCapture(
        object sender,
        MouseEventArgs e)
    {
        if (_voicePressed &&
            ReferenceEquals(sender, _voicePressedButton) &&
            VoiceGesturePolicy.StopOnRelease(
                _profileSettings.Current.TapToToggleVoice))
        {
            await ReleaseVoiceAsync(releaseCapture: false);
        }
    }

    private async void Voice_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key is not (Key.Space or Key.Enter) || e.IsRepeat)
        {
            return;
        }

        e.Handled = true;
        if (sender is not Button button)
        {
            return;
        }

        var decision = VoiceGesturePolicy.Press(
            _profileSettings.Current.TapToToggleVoice,
            _voicePressed,
            false);
        if (decision == VoicePressDecision.Ignore)
        {
            return;
        }
        if (decision == VoicePressDecision.Stop)
        {
            await ReleaseVoiceAsync();
            return;
        }

        await HandleSoftwareKeyAsync(button.Tag as string ?? "ACT10_ACT11", agentKey: false);
    }

    private async void Voice_PreviewKeyUp(object sender, KeyEventArgs e)
    {
        if (e.Key is not (Key.Space or Key.Enter))
        {
            return;
        }

        e.Handled = true;
        if (!VoiceGesturePolicy.StopOnRelease(
                _profileSettings.Current.TapToToggleVoice))
        {
            return;
        }
        await ReleaseVoiceAsync();
    }

    private async Task ReleaseVoiceAsync(bool releaseCapture = true)
    {

        if (!_voicePressed)
        {
            return;
        }

        _voicePressed = false;
        _voiceDispatchStatusVersion++;
        SetVoiceRecordingVisual(recording: false);
        var pressedButton = _voicePressedButton;
        if (releaseCapture &&
            pressedButton is not null &&
            Mouse.Captured == pressedButton)
        {
            pressedButton.ReleaseMouseCapture();
        }

        var physicalKey = _voicePhysicalKey;
        _voicePressedButton = null;
        _voicePhysicalKey = null;
        if (_broker.IsReady && !string.IsNullOrWhiteSpace(physicalKey))
        {
            await RunActionAsync(
                () => _broker.SetKeyAsync(physicalKey, false),
            "voice up");
        }
    }

    private void RestartVoiceBridgeMonitor()
    {
        return;
    }

    private void ShowHarnessActionProgress(
        MicroHarnessDispatchProgress value,
        bool onVoiceKey = false,
        bool onSettingsKey = false) =>
        ShowHarnessActionStatus(
            value.Step is { } step && value.TotalSteps is { } totalSteps
                ? ProgressLabel(step, totalSteps, includeFraction: true)
                : HarnessProgressLabel(value.Stage),
            value.Stage,
            autoHide: false,
            onVoiceKey: onVoiceKey,
            onSettingsKey: onSettingsKey,
            detail: value.Message);

    internal void ApplyHarnessProgressForVisualTest(
        int step,
        int totalSteps,
        bool onVoiceKey = false,
        bool onSettingsKey = false) =>
        ShowHarnessActionProgress(
            new(
                MicroHarnessDispatchStage.Connecting,
                "Visual progress test.",
                step,
                totalSteps),
            onVoiceKey,
            onSettingsKey);

    internal void ApplyVoiceStatusForVisualTest(
        string text,
        bool failed = false) =>
        ShowHarnessActionStatus(
            text,
            failed
                ? MicroHarnessDispatchStage.Failed
                : MicroHarnessDispatchStage.Connecting,
            autoHide: false,
            onVoiceKey: true,
            detail: "Visual voice status test.");

    private string ProgressLabel(
        int step,
        int totalSteps,
        bool includeFraction)
    {
        var label = totalSteps switch
        {
            7 => ActivationProgressLabel(step, includeFraction: false),
            8 or 4 => VoiceProgressLabel(
                step,
                totalSteps,
                includeFraction: false),
            _ => _localization.IsEnglish ? "WORKING" : "处理中",
        };
        return includeFraction ? $"{step}/{totalSteps} {label}" : label;
    }

    private string ActivationProgressLabel(
        int step,
        bool includeFraction) =>
        (includeFraction ? $"{step}/7 " : string.Empty) +
        (step switch
        {
            0 => _localization.IsEnglish ? "PREPARING" : "准备开始",
            1 => _localization.IsEnglish ? "CHECK ADAPTER" : "检查适配器",
            2 => _localization.IsEnglish ? "START SERVICE" : "启动服务",
            3 => _localization.IsEnglish ? "WAIT ADAPTER" : "等待适配器",
            4 => _localization.IsEnglish ? "OPEN WINDOW" : "请求打开窗口",
            5 => _localization.IsEnglish ? "WAIT WEB BRIDGE" : "等待网页桥接",
            6 => _localization.IsEnglish ? "BRING TO FRONT" : "将窗口置前",
            _ => _localization.IsEnglish ? "READY" : "已就绪",
        });

    private string VoiceProgressLabel(
        int step,
        int totalSteps,
        bool includeFraction = true)
    {
        var label = totalSteps == 8
            ? step switch
            {
                1 => _localization.IsEnglish ? "CHECK VOICE" : "检查语音设置",
                2 => _localization.IsEnglish ? "CHECK ADAPTER" : "检查适配器",
                3 => _localization.IsEnglish ? "START SERVICE" : "启动并等待服务",
                4 => _localization.IsEnglish ? "CONNECT WEB" : "打开并连接网页",
                5 => _localization.IsEnglish ? "PREPARE ASR" : "准备识别引擎",
                6 => _localization.IsEnglish ? "VOICE CHANNEL" : "连接语音通道",
                7 => _localization.IsEnglish ? "GET MICROPHONE" : "获取麦克风",
                _ => _localization.IsEnglish ? "LISTENING" : "正在聆听",
            }
            : step switch
            {
                1 => _localization.IsEnglish ? "STOP CAPTURE" : "停止采集",
                2 => _localization.IsEnglish ? "FINAL TRANSCRIPT" : "等待最终转写",
                3 => _localization.IsEnglish ? "WRITE COMPOSER" : "写入输入框",
                _ => _localization.IsEnglish ? "COMPLETE" : "转写完成",
            };
        return includeFraction ? $"{step}/{totalSteps} {label}" : label;
    }

    private string HarnessProgressLabel(MicroHarnessDispatchStage stage) =>
        stage switch
        {
            MicroHarnessDispatchStage.Connecting =>
                _localization.IsEnglish ? "CHECKING" : "检查服务",
            MicroHarnessDispatchStage.Starting =>
                _localization.IsEnglish ? "STARTING SERVICE" : "启动服务",
            MicroHarnessDispatchStage.WaitingForAdapter =>
                _localization.IsEnglish ? "WAITING FOR PLUGIN" : "等待插件",
            MicroHarnessDispatchStage.Opening =>
                _localization.IsEnglish ? "OPENING WEB" : "正在打开网页",
            MicroHarnessDispatchStage.Foreground =>
                _localization.IsEnglish ? "IN FRONT" : "已置前",
            MicroHarnessDispatchStage.Background =>
                _localization.IsEnglish ? "BRINGING FRONT" : "正在置前",
            MicroHarnessDispatchStage.Failed =>
                _localization.IsEnglish ? "NEEDS ATTENTION" : "需要处理",
            _ => _localization.IsEnglish ? "READY" : "已完成",
        };

    private void ShowHarnessActionStatus(
        string text,
        MicroHarnessDispatchStage stage,
        bool autoHide,
        bool onVoiceKey = false,
        bool onSettingsKey = false,
        string? detail = null)
    {
        if (!Dispatcher.CheckAccess())
        {
            _ = Dispatcher.BeginInvoke(new Action(() =>
                ShowHarnessActionStatus(
                    text,
                    stage,
                    autoHide,
                    onVoiceKey,
                    onSettingsKey,
                    detail)));
            return;
        }

        var version = ++_harnessActionStatusVersion;
        if (onVoiceKey)
        {
            var hasProgress = TryReadProgressFraction(
                text,
                out var voiceStep,
                out var voiceTotalSteps);
            ShowVoiceSurfaceStatus(new(
                version,
                text,
                detail ?? string.Empty,
                stage,
                hasProgress ? voiceStep : null,
                hasProgress ? voiceTotalSteps : null),
                autoHide);
            return;
        }

        if (_settingsDisplayProgress is not null ||
            _voiceSurfaceStatus is not null)
        {
            _settingsDisplayProgress = null;
            _voiceSurfaceStatus = null;
            _harnessActionElapsedTimer.Stop();
            HideHarnessProgressStatus();
            UpdateQuotaPresentation();
        }

        var structuredProgress = text.Contains('/', StringComparison.Ordinal);
        Grid.SetColumn(
            HarnessActionStatusBadge,
            onVoiceKey
                ? 1
                : onSettingsKey
                    ? 0
                    : structuredProgress ? 2 : 3);
        Grid.SetColumnSpan(
            HarnessActionStatusBadge,
            onVoiceKey || onSettingsKey || structuredProgress ? 2 : 1);
        HarnessActionStatusBadge.Width = onVoiceKey
            ? 178
            : onSettingsKey || structuredProgress
                ? 160
                : 84;
        HarnessActionStatusBadge.Height =
            onVoiceKey || onSettingsKey || structuredProgress ? 24 : 20;
        Grid.SetColumn(
            HarnessActionProgressRing,
            onVoiceKey ? 1 : onSettingsKey ? 0 : 3);
        Grid.SetColumnSpan(HarnessActionProgressRing, onVoiceKey ? 2 : 1);
        var busy = !autoHide && stage is not (
            MicroHarnessDispatchStage.Failed or
            MicroHarnessDispatchStage.Foreground or
            MicroHarnessDispatchStage.Completed);
        if (busy)
        {
            if (!_harnessActionElapsedTimer.IsEnabled)
            {
                _harnessActionStartedAt = DateTimeOffset.UtcNow;
                _harnessActionElapsedTimer.Start();
            }

            _harnessActionBaseText = text;
            StartHarnessActionProgressRing(stage);
        }
        else
        {
            _harnessActionElapsedTimer.Stop();
            _harnessActionBaseText = text;
            StopHarnessActionProgressRing();
        }

        var colors = stage switch
        {
            MicroHarnessDispatchStage.Failed =>
                (Background: "#F5FFF0F2", Border: "#C8F0A4AF", Text: "#FF8B4055"),
            MicroHarnessDispatchStage.Foreground or
                MicroHarnessDispatchStage.Completed =>
                (Background: "#F3EDF9FF", Border: "#B8B8D8FF", Text: "#FF315A86"),
            MicroHarnessDispatchStage.Background =>
                (Background: "#F5FFF9E9", Border: "#C8E8CC89", Text: "#FF725B23"),
            _ =>
                (Background: "#F2EEF4FF", Border: "#B8C7D2FF", Text: "#FF34415B"),
        };
        HarnessActionStatusText.Text = FormatHarnessActionStatusText(text);
        HarnessActionStatusText.Foreground = new SolidColorBrush(
            (Color)ColorConverter.ConvertFromString(colors.Text));
        HarnessActionStatusBadge.Background = new SolidColorBrush(
            (Color)ColorConverter.ConvertFromString(colors.Background));
        HarnessActionStatusBadge.BorderBrush = new SolidColorBrush(
            (Color)ColorConverter.ConvertFromString(colors.Border));
        HarnessActionStatusBadge.BeginAnimation(OpacityProperty, null);
        HarnessActionStatusBadge.Visibility = Visibility.Visible;
        HarnessActionStatusBadge.Opacity = 1;
        AutomationProperties.SetItemStatus(
            onVoiceKey
                ? ActionKey10
                : onSettingsKey ? SettingsKey : ActionKey12,
            Localize(text));
        if (autoHide)
        {
            _ = HideHarnessActionStatusAsync(version);
        }
    }

    private void ApplySettingsDisplayProgress(SettingsDisplayProgress progress)
    {
        SettingsKey.UseQuotaReadout = false;
        ApplySettingsDisplayTheme(light: true);
        var step = Math.Clamp(progress.Step, 0, progress.TotalSteps);
        QuotaCaptionText.Visibility = Visibility.Collapsed;
        QuotaValueText.Text = $"{step}/{progress.TotalSteps}";
        QuotaValueText.FontSize = 16;
        QuotaGauge.Opacity = 1;
        QuotaProgressRing.Data = CreateQuotaArcGeometry(
            100d * step / progress.TotalSteps);
        QuotaProgressRing.Stroke = new SolidColorBrush(
            progress.Stage == MicroHarnessDispatchStage.Failed
                ? Color.FromRgb(0xA7, 0x42, 0x56)
                : progress.Stage is MicroHarnessDispatchStage.Foreground or
                    MicroHarnessDispatchStage.Completed
                    ? Color.FromRgb(0x28, 0x66, 0x4A)
                    : Color.FromRgb(0x22, 0x22, 0x22));

        BrandWordmarkPanel.Visibility = Visibility.Collapsed;
        HarnessProgressStatusText.Text = FormatHarnessActionStatusText(
            ProgressStageText(progress.Text));
        HarnessProgressStatusText.Foreground = new SolidColorBrush(
            progress.Stage == MicroHarnessDispatchStage.Failed
                ? Color.FromRgb(0x8B, 0x40, 0x55)
                : progress.Stage is MicroHarnessDispatchStage.Foreground or
                    MicroHarnessDispatchStage.Completed
                    ? Color.FromRgb(0x31, 0x5A, 0x86)
                    : progress.Stage == MicroHarnessDispatchStage.Background
                        ? Color.FromRgb(0x72, 0x5B, 0x23)
                        : Color.FromRgb(0x34, 0x41, 0x5B));
        HarnessProgressStatusText.Visibility = Visibility.Visible;

        var detail = FormatHarnessActionStatusText(progress.Text);
        if (!string.IsNullOrWhiteSpace(progress.Detail) &&
            !string.Equals(
                progress.Detail.Trim(),
                progress.Text.Trim(),
                StringComparison.OrdinalIgnoreCase))
        {
            detail += $"\n{progress.Detail.Trim()}";
        }

        ApplyHelp(
            SettingsKey,
            $"{ActiveHarness().DisplayName} · {step}/{progress.TotalSteps}",
            detail);
    }

    private static string ProgressStageText(string text)
    {
        if (!TryReadProgressFraction(text, out var step, out var totalSteps))
        {
            return text.Trim();
        }

        var fraction = $"{step}/{totalSteps}";
        if (!text.StartsWith(fraction, StringComparison.Ordinal))
        {
            return text.Trim();
        }

        return text[fraction.Length..].TrimStart(' ', '\t', ':', '：');
    }

    private void HideHarnessProgressStatus()
    {
        HarnessProgressStatusText.Visibility = Visibility.Collapsed;
        HarnessProgressStatusText.Text = string.Empty;
        BrandWordmarkPanel.Visibility = Visibility.Visible;
    }

    private static bool TryReadProgressFraction(
        string text,
        out int step,
        out int totalSteps)
    {
        step = 0;
        totalSteps = 0;
        for (var slash = text.IndexOf('/');
             slash >= 0;
             slash = text.IndexOf('/', slash + 1))
        {
            var left = slash - 1;
            while (left >= 0 && char.IsDigit(text[left]))
            {
                left--;
            }

            var right = slash + 1;
            while (right < text.Length && char.IsDigit(text[right]))
            {
                right++;
            }

            var stepSpan = text.AsSpan(left + 1, slash - left - 1);
            var totalSpan = text.AsSpan(slash + 1, right - slash - 1);
            if (stepSpan.Length > 0 &&
                totalSpan.Length > 0 &&
                int.TryParse(stepSpan, out step) &&
                int.TryParse(totalSpan, out totalSteps) &&
                step >= 0 &&
                totalSteps > 0)
            {
                return true;
            }
        }

        step = 0;
        totalSteps = 0;
        return false;
    }

    private void HarnessActionElapsedTimer_Tick(object? sender, EventArgs e)
    {
        if (_voiceSurfaceStatus is { } voiceStatus)
        {
            ApplyVoiceSurfaceStatus(voiceStatus);
            return;
        }

        if (_settingsDisplayProgress is { } settingsProgress)
        {
            ApplySettingsDisplayProgress(settingsProgress);
            return;
        }

        if (HarnessActionStatusBadge.Visibility == Visibility.Visible &&
            _harnessActionBaseText.Length > 0)
        {
            HarnessActionStatusText.Text = FormatHarnessActionStatusText(
                _harnessActionBaseText);
        }
    }

    private string FormatHarnessActionStatusText(string text)
    {
        if (!_harnessActionElapsedTimer.IsEnabled)
        {
            return text;
        }

        var elapsed = Math.Max(
            0,
            (int)(DateTimeOffset.UtcNow - _harnessActionStartedAt).TotalSeconds);
        return elapsed < 2 ? text : $"{text} · {elapsed}s";
    }

    private void StartHarnessActionProgressRing(MicroHarnessDispatchStage stage)
    {
        HarnessActionProgressRing.Stroke = new SolidColorBrush(
            (Color)ColorConverter.ConvertFromString(
                stage == MicroHarnessDispatchStage.Starting ||
                stage == MicroHarnessDispatchStage.WaitingForAdapter
                    ? "#FFE8B44B"
                    : "#FF7EA5F7"));
        if (HarnessActionProgressRing.Visibility == Visibility.Visible)
        {
            return;
        }

        HarnessActionProgressRing.Visibility = Visibility.Visible;
        HarnessActionProgressRotate.BeginAnimation(
            RotateTransform.AngleProperty,
            new DoubleAnimation
            {
                From = 0,
                To = 360,
                Duration = TimeSpan.FromMilliseconds(900),
                RepeatBehavior = RepeatBehavior.Forever,
            });
    }

    private void StopHarnessActionProgressRing()
    {
        HarnessActionProgressRotate.BeginAnimation(
            RotateTransform.AngleProperty,
            null);
        HarnessActionProgressRing.Visibility = Visibility.Collapsed;
    }

    private async Task HideHarnessActionStatusAsync(int version)
    {
        await Task.Delay(3200);
        if (_windowClosed || version != _harnessActionStatusVersion)
        {
            return;
        }

        if (_settingsDisplayProgress is { Version: var progressVersion } &&
            progressVersion == version)
        {
            _settingsDisplayProgress = null;
            _harnessActionElapsedTimer.Stop();
            HideHarnessProgressStatus();
            UpdateQuotaPresentation();
            return;
        }

        if (_voiceSurfaceStatus is { Version: var voiceVersion } &&
            voiceVersion == version)
        {
            _voiceSurfaceStatus = null;
            _harnessActionElapsedTimer.Stop();
            StopHarnessActionProgressRing();
            HideHarnessProgressStatus();
            UpdateQuotaPresentation();
            RefreshHarnessPresentation();
            return;
        }

        var fade = new DoubleAnimation
        {
            To = 0,
            Duration = TimeSpan.FromMilliseconds(180),
            FillBehavior = FillBehavior.HoldEnd,
        };
        fade.Completed += (_, _) =>
        {
            if (version == _harnessActionStatusVersion)
            {
                HarnessActionStatusBadge.Visibility = Visibility.Collapsed;
                RefreshHarnessPresentation();
            }
        };
        HarnessActionStatusBadge.BeginAnimation(
            OpacityProperty,
            fade,
            HandoffBehavior.SnapshotAndReplace);
    }

    private bool ShouldFocusAgentAfterTap(string key)
    {
        if (_profileSettings.Current.SingleTapAgentKeys)
        {
            _lastAgentTapKey = null;
            _lastAgentTapTimestamp = 0;
            return true;
        }

        var now = Stopwatch.GetTimestamp();
        var elapsed = _lastAgentTapTimestamp == 0
            ? TimeSpan.MaxValue
            : Stopwatch.GetElapsedTime(_lastAgentTapTimestamp, now);
        var isDoubleTap = key == _lastAgentTapKey &&
            elapsed <= AgentDoubleTapThreshold;
        _lastAgentTapKey = isDoubleTap ? null : key;
        _lastAgentTapTimestamp = isDoubleTap ? 0 : now;
        return isDoubleTap;
    }

    private static bool TryParseAgentSlot(string key, out int slotId)
    {
        slotId = -1;
        return
            key.Length == 4 &&
            key.StartsWith("AG", StringComparison.Ordinal) &&
            int.TryParse(
                key.AsSpan(2),
                NumberStyles.None,
                CultureInfo.InvariantCulture,
                out slotId) &&
            slotId is >= 0 and < 6;
    }

    internal static bool ShouldActivateCodexForKey(string key) =>
        key == "ACT12" || TryParseAgentSlot(key, out _);

    internal static bool IsCodexComposerTextKey(
        string key,
        CodexMicroLayoutSnapshot layout)
    {
        ArgumentNullException.ThrowIfNull(layout);
        if (!key.StartsWith("ACT", StringComparison.Ordinal))
        {
            return false;
        }

        var binding = layout.GetSlot(key);
        return binding.Action is null &&
            string.IsNullOrWhiteSpace(binding.CommandId) &&
            binding.KeycapId is "YOLO" or "YEET";
    }

    internal static bool ShouldActivateCodexBeforeHid(
        string key,
        bool codexIsForeground,
        bool focusAgentAfterTap) =>
        focusAgentAfterTap &&
        !codexIsForeground &&
        TryParseAgentSlot(key, out _);

    internal static bool ShouldSendCodexHidForKey(
        string key,
        bool codexIsForeground) =>
        key != "ACT12" || codexIsForeground;

    internal void SetVoiceRecordingVisual(bool recording)
    {
        var brush = new SolidColorBrush(
            recording
                ? Color.FromRgb(0x0C, 0x8E, 0x7E)
                : Color.FromRgb(0x17, 0x17, 0x17));
        ActionIcon10.IconBrush = brush;
        ActionIcon10Split.IconBrush = brush;
        ActionIcon11Split.IconBrush = brush;
    }

    private void Dial_MouseWheel(object sender, MouseWheelEventArgs e)
    {
        e.Handled = true;
        QueueDialWheelDelta(e.Delta);
    }

    private bool RouteInactiveDialWheel(Point screenPoint, int delta)
    {
        if (IsScreenPointOverControl(SettingsKey, screenPoint))
        {
            _ = Dispatcher.BeginInvoke(
                System.Windows.Threading.DispatcherPriority.Input,
                new Action(() => QueueReasoningWheelDelta(delta)));
            return true;
        }

        if (!IsScreenPointOverDial(screenPoint))
        {
            return false;
        }

        _ = Dispatcher.BeginInvoke(
            System.Windows.Threading.DispatcherPriority.Input,
            new Action(() =>
            {
                var routeSequence = ++_dialWheelRouteSequence;
                AutomationProperties.SetItemStatus(
                    DialButton,
                    Localize($"滚轮路由已接收 · #{routeSequence}"));
                QueueDialWheelDelta(delta);
            }));
        return true;
    }

    private bool RouteInactiveDialPointer(RoutedDialPointerInput input)
    {
        if (input.Action == RoutedDialPointerAction.Pressed &&
            !IsScreenPointOverDial(input.ScreenPoint))
        {
            return false;
        }

        if (!Dispatcher.CheckAccess() ||
            !IsVisible ||
            WindowState == WindowState.Minimized)
        {
            return false;
        }

        _ = Dispatcher.BeginInvoke(
            System.Windows.Threading.DispatcherPriority.Input,
            new Action(() => ProcessInactiveDialPointer(input)));
        return true;
    }

    private bool IsScreenPointOverDial(Point screenPoint) =>
        IsScreenPointOverControl(DialButton, screenPoint);

    private bool IsScreenPointOverControl(FrameworkElement control, Point screenPoint)
    {
        if (!Dispatcher.CheckAccess() || _pageSwitching ||
            !IsVisible ||
            WindowState == WindowState.Minimized ||
            !control.IsVisible ||
            !control.IsEnabled ||
            control.ActualWidth <= 0 ||
            control.ActualHeight <= 0)
        {
            return false;
        }

        Point localPoint;
        try
        {
            localPoint = control.PointFromScreen(screenPoint);
        }
        catch (InvalidOperationException)
        {
            return false;
        }

        return localPoint.X >= 0 &&
            localPoint.Y >= 0 &&
            localPoint.X < control.ActualWidth &&
            localPoint.Y < control.ActualHeight;
    }

    private void ProcessInactiveDialPointer(RoutedDialPointerInput input)
    {
        Point localPoint;
        try
        {
            localPoint = DialButton.PointFromScreen(input.ScreenPoint);
        }
        catch (InvalidOperationException)
        {
            CancelDialGesture();
            return;
        }

        switch (input.Action)
        {
            case RoutedDialPointerAction.Pressed:
                if (RequiresBrokerForDialPress(
                        true,
                        _broker.IsReady,
                        _layoutObserver.Current.EncoderMode))
                {
                    _ = RunDialInputSafelyAsync(
                        EnsureReadyFeedbackAsync,
                        "旋钮按压");
                    return;
                }

                if (!_dialGesture.IsPointerDown)
                {
                    _dialGesture.Begin(localPoint.X, localPoint.Y);
                }

                break;
            case RoutedDialPointerAction.Moved:
                if (!_dialGesture.IsPointerDown)
                {
                    return;
                }

                var update = _dialGesture.Move(localPoint.X, localPoint.Y);
                if (update.Steps != 0)
                {
                    EnqueueEncoderSteps(update.Steps, "旋钮拖动");
                }

                break;
            case RoutedDialPointerAction.Released:
                if (!_dialGesture.IsPointerDown)
                {
                    return;
                }

                if (_dialGesture.End())
                {
                    _ = RunDialInputSafelyAsync(TapEncoderAsync, "旋钮确认");
                }

                break;
        }
    }

    private void QueueDialWheelDelta(int delta)
    {
        if (_pageSwitching)
        {
            return;
        }

        if (RequiresBrokerForDialPress(
                true,
                _broker.IsReady,
                _layoutObserver.Current.EncoderMode))
        {
            _ = RunDialInputSafelyAsync(
                EnsureReadyFeedbackAsync,
                "旋钮滚轮");
            return;
        }

        var steps = _dialGesture.AddWheelDelta(delta);
        if (steps != 0)
        {
            EnqueueEncoderSteps(steps, "旋钮滚轮");
        }
    }

    private void Dial_PreviewMouseLeftButtonDown(
        object sender,
        MouseButtonEventArgs e)
    {
        e.Handled = true;
        if (e.LeftButton != MouseButtonState.Pressed || _dialGesture.IsPointerDown)
        {
            return;
        }

        if (!_broker.IsReady)
        {
            _ = RunDialInputSafelyAsync(
                EnsureReadyFeedbackAsync,
                "旋钮按压");
            return;
        }

        var pointer = e.GetPosition(DialButton);
        _dialGesture.Begin(pointer.X, pointer.Y);
        _ = DialButton.CaptureMouse();
    }

    internal static bool RequiresBrokerForDialPress(
        bool isCodexHarness,
        bool brokerReady,
        string? encoderMode) =>
        isCodexHarness &&
        !brokerReady &&
        !string.Equals(
            encoderMode,
            "reasoning",
            StringComparison.OrdinalIgnoreCase);

    private void Dial_MouseMove(object sender, MouseEventArgs e)
    {
        if (!_dialGesture.IsPointerDown)
        {
            return;
        }

        if (e.LeftButton != MouseButtonState.Pressed)
        {
            CancelDialGesture();
            return;
        }

        e.Handled = true;
        var pointer = e.GetPosition(DialButton);
        var update = _dialGesture.Move(pointer.X, pointer.Y);
        if (update.Steps != 0)
        {
            EnqueueEncoderSteps(update.Steps, "旋钮拖动");
        }
    }

    private void Dial_PreviewMouseLeftButtonUp(
        object sender,
        MouseButtonEventArgs e)
    {
        e.Handled = true;
        if (!_dialGesture.IsPointerDown)
        {
            return;
        }

        var shouldTap = _dialGesture.End();
        if (Mouse.Captured == DialButton)
        {
            DialButton.ReleaseMouseCapture();
        }

        if (shouldTap)
        {
            _ = RunDialInputSafelyAsync(TapEncoderAsync, "旋钮确认");
        }
    }

    private void Dial_LostMouseCapture(object sender, MouseEventArgs e)
    {
        if (_dialGesture.IsPointerDown)
        {
            _dialGesture.Cancel();
        }
    }

    private void CancelDialGesture()
    {
        _dialGesture.Cancel();
        if (Mouse.Captured == DialButton)
        {
            DialButton.ReleaseMouseCapture();
        }
    }

    private void EnqueueEncoderSteps(int steps, string operation)
    {
        _encoderSteps.Add(steps, Stopwatch.GetTimestamp());
        if (_encoderStepPumpRunning || _encoderSteps.Pending == 0)
        {
            return;
        }

        StartEncoderStepPump(operation);
    }

    private void StartEncoderStepPump(string operation)
    {
        _encoderStepPumpRunning = true;
        _ = RunDialInputSafelyAsync(
            PumpEncoderStepsAsync,
            operation);
    }

    private async Task PumpEncoderStepsAsync()
    {
        try
        {
            while (!_windowClosed)
            {
                var intent = _encoderSteps.TakeNext(
                    Stopwatch.GetTimestamp(),
                    ToStopwatchTicks(CurrentEncoderIntentMaximumAge));
                if (intent is null)
                {
                    return;
                }

                var sendStarted = Stopwatch.GetTimestamp();
                await SendEncoderStepAsync(intent.Value);
                // Software actions can take seconds. TakeNext expires old input while
                // retaining a fresh wheel step entered just as the previous result arrived.

                if (_encoderSteps.Pending != 0)
                {
                    await Task.Delay(EncoderStepInterval);
                }
            }
        }
        finally
        {
            _encoderStepPumpRunning = false;
            if (!_windowClosed && _encoderSteps.Pending != 0)
            {
                StartEncoderStepPump("旋钮合并输入");
            }
        }
    }

    private async Task SendEncoderStepAsync(EncoderStepIntent intent)
    {
        {
            AnimateDialStep(intent.Direction > 0);
            if (_layoutObserver.Current.EncoderMode == "reasoning")
                await StepReasoningAsync(_dialDirectionSettings.ToReasoningSteps(intent.Direction));
            else
                await RunActionAsync(
                    () => _broker.StepEncoderAsync(_dialDirectionSettings.ToReportedClockwise(intent.Direction > 0)),
                    "encoder");
            return;
        }
    }

    private async Task TapEncoderAsync()
    {
        _encoderSteps.Clear();
        {
            if (_layoutObserver.Current.EncoderMode == "reasoning") await ToggleQuickModelAsync();
            else await RunActionAsync(() => _broker.TapKeyAsync("ENC"), "encoder");
            return;
        }
    }

    private static long ToStopwatchTicks(TimeSpan duration) =>
        checked((long)(duration.TotalSeconds * Stopwatch.Frequency));

    internal void AnimateDialStep(bool clockwise)
    {
        DialButton.ApplyTemplate();
        if (DialButton.Template.FindName("DialIndicator", DialButton) is not
            Border { RenderTransform: RotateTransform rotation } indicator)
        {
            return;
        }

        rotation = rotation.CloneCurrentValue();
        indicator.RenderTransform = rotation;

        _dialVisualAngle += clockwise ? 18 : -18;
        rotation.BeginAnimation(
            RotateTransform.AngleProperty,
            new DoubleAnimation
            {
                To = _dialVisualAngle,
                Duration = TimeSpan.FromMilliseconds(105),
                EasingFunction = new CubicEase
                {
                    EasingMode = EasingMode.EaseOut,
                },
                FillBehavior = FillBehavior.HoldEnd,
            },
            HandoffBehavior.SnapshotAndReplace);
    }

    private void ShowDialSelectionFeedback(string text)
    {
        if (!Dispatcher.CheckAccess())
        {
            _ = Dispatcher.BeginInvoke(
                new Action(() => ShowDialSelectionFeedback(text)));
            return;
        }

        _dialSelectionHudVersion++;
        _dialSelectionText = text;
        var localizedText = Localize(text);
        DialSelectionText.Text = localizedText;
        DialSelectionHud.Visibility = Visibility.Visible;
        DialSelectionHud.BeginAnimation(OpacityProperty, null);
        DialSelectionHud.Opacity = 1;
        AutomationProperties.SetItemStatus(DialButton, localizedText);
        _dialSelectionHideTimer.Stop();
        _dialSelectionHideTimer.Start();
    }

    private void DialSelectionHideTimer_Tick(object? sender, EventArgs e)
    {
        _dialSelectionHideTimer.Stop();
        var version = _dialSelectionHudVersion;
        var fade = new DoubleAnimation
        {
            To = 0,
            Duration = TimeSpan.FromMilliseconds(180),
            EasingFunction = new CubicEase
            {
                EasingMode = EasingMode.EaseOut,
            },
            FillBehavior = FillBehavior.HoldEnd,
        };
        fade.Completed += (_, _) =>
        {
            if (version == _dialSelectionHudVersion)
            {
                DialSelectionHud.Visibility = Visibility.Collapsed;
            }
        };
        DialSelectionHud.BeginAnimation(
            OpacityProperty,
            fade,
            HandoffBehavior.SnapshotAndReplace);
    }

    private void Settings_PreviewMouseLeftButtonDown(
        object sender,
        MouseButtonEventArgs e)
    {
        _settingsPointerDownTimestamp = Stopwatch.GetTimestamp();
        _settingsWheelDuringPress = false;
    }

    private void Settings_PreviewMouseRightButtonDown(
        object sender,
        MouseButtonEventArgs e)
    {
        e.Handled = true;
        ShowSoftwareSettings();
        _settingsWindow?.FocusActiveAgentSettings();
    }

    private void Settings_ContextMenuOpening(
        object sender,
        ContextMenuEventArgs e)
    {
        e.Handled = true;
        ShowSoftwareSettings();
        _settingsWindow?.FocusActiveAgentSettings();
    }

    private async void Settings_Click(object sender, RoutedEventArgs e)
    {
        if (_settingsWheelDuringPress || _reasoningAdjusting)
        {
            _settingsPointerDownTimestamp = 0;
            _settingsWheelDuringPress = false;
            return;
        }

        var pressedAt = _settingsPointerDownTimestamp;
        _settingsPointerDownTimestamp = 0;
        if (pressedAt != 0 &&
            Stopwatch.GetElapsedTime(pressedAt) >=
                SettingsLongPressThreshold)
        {
            await OpenCodexMicroSettingsAsync("打开 Codex Micro 设置");
            return;
        }

        await ToggleQuickModelAsync();
    }

    private void ModelToggleService_CurrentThreadStateChanged(
        CodexThreadModelState? ignoredState)
    {
        if (_windowClosed)
        {
            return;
        }

        if (Dispatcher.CheckAccess())
        {
            RefreshCurrentCodexThreadPresentation();
            return;
        }

        if (Dispatcher.HasShutdownStarted || Dispatcher.HasShutdownFinished)
        {
            return;
        }

        try
        {
            _ = Dispatcher.BeginInvoke(
                System.Windows.Threading.DispatcherPriority.Send,
                new Action(() =>
                {
                    if (!_windowClosed)
                    {
                        RefreshCurrentCodexThreadPresentation();
                    }
                }));
        }
        catch (InvalidOperationException) when (
            _windowClosed ||
            Dispatcher.HasShutdownStarted ||
            Dispatcher.HasShutdownFinished)
        {
            // A reader notification can race the WPF dispatcher shutdown.
        }
    }

    private void RefreshCurrentCodexThreadPresentation()
    {
        ApplyAuthoritativeQuickModelState(_modelToggleService.CurrentThreadState);

        ResolveCurrentAgentSlot();
        RefreshAgentSlotPresentation();
        RefreshDraftQuickModelObservation();
        RefreshSoftwareFeedback();
    }

    private async void AgentKey_PreviewMouseRightButtonDown(
        object sender,
        MouseButtonEventArgs e)
    {
        if (sender is not Button { Tag: string key } ||
            !TryParseAgentSlot(key, out var slotId))
        {
            return;
        }

        // Right-click belongs to the Agent key even when the requested state
        // change is ineligible. Do not let it open the device-frame menu.
        e.Handled = true;
        if (_taskKeyMotionActive || _pageSwitching)
        {
            return;
        }
        var rosterEntry = _latestAgentRoster?.GetSlot(slotId);
        if (rosterEntry is null)
        {
            SetStatus(_localization.IsEnglish
                ? $"Agent {slotId + 1} is not mapped to a Codex chat yet."
                : $"Agent {slotId + 1} 尚未映射到 Codex 对话，无法标记未读。");
            return;
        }

        var lighting = _latestSlotLighting?.Slots.FirstOrDefault(
            slot => slot.SlotId == slotId);
        var appearance = ResolveCodexAgentAppearance(slotId, lighting, rosterEntry);
        var hasColoredProtocolSignal = appearance.IsActive &&
            appearance.Color != Colors.White;
        await MarkCodexThreadUnreadAsync(
            rosterEntry.ThreadId,
            rosterEntry.DisplayTitle,
            hasColoredProtocolSignal);
    }

    private async Task MarkCodexThreadUnreadAsync(
        string threadId,
        string displayTitle,
        bool hasColoredSignal)
    {
        if (!_manualUnreadThreads.TryMarkUnread(
                threadId,
                hasColoredSignal))
        {
            return;
        }

        RefreshAgentSlotPresentation();
        SetStatus(_localization.IsEnglish
            ? $"Marking “{displayTitle}” unread in Codex…"
            : $"正在 Codex 中将“{displayTitle}”标记为未读…");
        RefreshSoftwareFeedback();
        SetLed(ActivityLed, "#9EBDFF", "Mark unread", glow: true);

        var result = await _modelToggleService.MarkThreadUnreadAsync(threadId);
        if (_windowClosed)
        {
            return;
        }

        // A successful left-click can open the chat while the persistence
        // confirmation is still in flight. Do not overwrite that newer UI
        // outcome with the older right-click operation's status.
        if (!_manualUnreadThreads.IsUnread(threadId))
        {
            return;
        }

        if (!result.Confirmed)
        {
            _manualUnreadThreads.Clear(threadId);
            RefreshAgentSlotPresentation();
            RefreshSoftwareFeedback();
            SetLed(ActivityLed, "#FF7994", "Unread unconfirmed");
            SetStatus(_localization.IsEnglish
                ? $"Codex did not confirm “{displayTitle}” as unread. " +
                    "Make sure Codex is running, then try again."
                : $"Codex 未确认“{displayTitle}”的未读状态。" +
                    "请确认 Codex 正在运行后重试。");
            return;
        }

        _manualUnreadThreads.Confirm(threadId);
        if (_taskMonitor.ObserveUnreadConfirmed(threadId) is { } confirmedSnapshot)
            ApplyMonitorSnapshot(confirmedSnapshot);
        SetLed(ActivityLed, "#74D9A0", "Unread confirmed");
        ReconcileConfirmedUnreadProjectionWithLighting();
        RefreshAgentSlotPresentation();
        RefreshSoftwareFeedback();
        _ = RefreshMonitorAsync();
        SetStatus(_localization.IsEnglish
            ? $"Codex confirmed “{displayTitle}” as unread; the state " +
                "follows that chat if Agent slots reorder."
            : $"Codex 已确认“{displayTitle}”为未读；" +
                "Agent 槽位重排后该状态仍跟随此对话。");
    }

    private CodexModelToggleService.ForegroundDraftPresentationContext? _draftQuickModelContext;
    private (CodexQuickModel Model, string? Effort)? _draftQuickModelSelection;
    private bool _draftQuickModelObservationPending;
    private long _lastDraftQuickModelObservationAt;
    private int _quickModelPresentationRevision;

    private void RefreshDraftQuickModelObservation()
    {
        var context = !_windowClosed && IsVisible
            ? CaptureDraftPresentationContext()
            : null;
        var changed = context != _draftQuickModelContext;
        if (changed)
        {
            if (_reasoningPreview is { AwaitingObservation: true })
            {
                ClearReasoningFeedback();
            }
            _draftQuickModelContext = context;
            _draftQuickModelSelection = null;
            ApplyAuthoritativeQuickModelState(_modelToggleService.CurrentThreadState);
        }

        var awaitingReasoning = _reasoningPreview is { AwaitingObservation: true };
        var feedbackAge = Stopwatch.GetElapsedTime(_draftReasoningFeedbackChangedAt);
        if (context is not { } draft || _draftQuickModelObservationPending ||
            _quickModelSwitching || _reasoningAdjusting || _encoderStepPumpRunning ||
            (awaitingReasoning && feedbackAge < TimeSpan.FromMilliseconds(600)) ||
            (!changed && _lastDraftQuickModelObservationAt != 0 &&
                Stopwatch.GetElapsedTime(_lastDraftQuickModelObservationAt) <
                    TimeSpan.FromMilliseconds(
                        awaitingReasoning && feedbackAge < TimeSpan.FromSeconds(3) ? 250 : 1000)))
        {
            return;
        }

        _ = ObserveDraftQuickModelAsync(draft);
    }

    private async Task ObserveDraftQuickModelAsync(
        CodexModelToggleService.ForegroundDraftPresentationContext context)
    {
        _draftQuickModelObservationPending = true;
        var revision = _quickModelPresentationRevision;

        using var cancellation = new CancellationTokenSource(TimeSpan.FromSeconds(2));
        try
        {
            if (_draftQuickModelSelection is null)
            {
                await Task.Delay(TimeSpan.FromMilliseconds(200), cancellation.Token);
            }
            if (_windowClosed || !IsVisible ||
                _quickModelSwitching || _reasoningAdjusting || _encoderStepPumpRunning ||
                revision != _quickModelPresentationRevision || _draftQuickModelContext != context)
            {
                return;
            }

            var selection = await _draftComposerModelSelector.ObserveSelectionAsync(
                context,
                _reasoningPreview is { AwaitingObservation: true },
                () => CaptureDraftPresentationContext() == context,
                cancellation.Token);
            if (_windowClosed || !IsVisible ||
                _quickModelSwitching || _reasoningAdjusting || _encoderStepPumpRunning ||
                revision != _quickModelPresentationRevision ||
                _draftQuickModelContext != context ||
                CaptureDraftPresentationContext() != context)
            {
                return;
            }
            if (selection is not { } observed)
            {
                _draftReasoningObservationCandidate = null;
                return;
            }

            var confirmsReasoning = false;
            if (_reasoningPreview is { AwaitingObservation: true } preview)
            {
                if (observed.Effort is null)
                {
                    _draftReasoningObservationCandidate = null;
                    return;
                }

                // A differing snapshot can be an intermediate render. Require it
                // to repeat after input settles before replacing the latest preview.
                if ((preview.ModelId != observed.Model.Id ||
                        !string.Equals(preview.Effort, observed.Effort,
                            StringComparison.OrdinalIgnoreCase)) &&
                    _draftReasoningObservationCandidate != observed)
                {
                    _draftReasoningObservationCandidate = observed;
                    return;
                }

                _reasoningPreview = null;
                _draftReasoningObservationCandidate = null;
                confirmsReasoning = true;
            }

            // The collapsed picker can expose only the model. Missing effort is
            // a partial observation, not a reset of this draft's confirmed value.
            if (observed.Effort is null &&
                _draftQuickModelSelection is { } confirmed && confirmed.Model == observed.Model)
            {
                observed.Effort = confirmed.Effort;
            }

            if (confirmsReasoning || _draftQuickModelSelection != observed)
            {
                _draftQuickModelSelection = observed;
                ApplyQuickModelPresentationState(new(context.VisibleThreadId, observed.Model), observed.Effort);
            }
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested)
        {
        }
        catch (Exception exception)
        {
            Debug.WriteLine($"Draft model observation: {exception.Message}");
        }
        finally
        {
            _lastDraftQuickModelObservationAt =
                _draftQuickModelContext == context ? Stopwatch.GetTimestamp() : 0;
            _draftQuickModelObservationPending = false;
        }
    }

    private void ApplyAuthoritativeQuickModelState(
        CodexThreadModelState? state)
    {
        var foregroundCodexWindow =
            CodexWindowActivator.CaptureForegroundWindow();
        var visibleThreadId = _modelToggleService.CurrentForegroundVisibleThreadId(foregroundCodexWindow);
        visibleThreadId = ResolveSoftwareThreadId(visibleThreadId);
        var next = ReduceQuickModelSnapshot(state, visibleThreadId);
        var effort = state is not null && QuickModelThreadIdsEqual(state.ThreadId, next.ThreadId)
            ? state.Effort
            : null;
        if (_draftQuickModelContext is { } draft &&
            CaptureDraftPresentationContext() == draft &&
            QuickModelThreadIdsEqual(draft.VisibleThreadId, visibleThreadId) &&
            _draftQuickModelSelection is { } observed)
        {
            next = new(visibleThreadId, observed.Model);
            effort = observed.Effort;
        }
        if (!QuickModelThreadIdsEqual(_quickModelThreadId, next.ThreadId))
        {
            CancelReasoningInput();
        }

        if (_quickModelSwitching &&
            !string.IsNullOrWhiteSpace(_quickModelSwitchingThreadId) &&
            !CodexDraftModelToggleService.IsDraftOperationId(
                _quickModelSwitchingThreadId) &&
            !QuickModelThreadIdsEqual(
                _quickModelSwitchingThreadId,
                visibleThreadId))
        {
            // A toggle belongs to the task that was visible when it started.
            // A draft bootstrap is the exception: its expected result is a
            // transition from a renderer draft to a newly created real task.
            _modelActionCancellation?.Cancel();
        }

        ApplyQuickModelPresentationState(next, effort);
        ResolveCurrentAgentSlot();
        RefreshAgentSlotPresentation();
        _ = RefreshMonitorAsync();
    }

    internal static QuickModelPresentationState ReduceQuickModelSnapshot(
        CodexThreadModelState? state) =>
        state is null || string.IsNullOrWhiteSpace(state.ThreadId)
            ? new(null, CodexQuickModel.Unknown)
            : new(
                state.ThreadId.Trim(),
                CodexModelToggleService.ParseModelId(state.ModelId));

    internal static QuickModelPresentationState ReduceQuickModelSnapshot(
        CodexThreadModelState? state,
        string? visibleThreadId)
    {
        var normalizedVisibleThreadId = string.IsNullOrWhiteSpace(
            visibleThreadId)
                ? null
                : visibleThreadId.Trim();
        if (normalizedVisibleThreadId is null)
        {
            return new(null, CodexQuickModel.Unknown);
        }

        if (state is null ||
            !QuickModelThreadIdsEqual(
                state.ThreadId,
                normalizedVisibleThreadId))
        {
            // A real tracked task is already a safe semantic command target
            // before Codex records its first model selection. Renderer-only
            // drafts are handled by the isolated App Server bootstrap.
            return new(normalizedVisibleThreadId, CodexQuickModel.Unknown);
        }

        return new(
            normalizedVisibleThreadId,
            CodexModelToggleService.ParseModelId(state.ModelId));
    }

    internal static bool QuickModelResultTargetsCurrentThread(
        QuickModelPresentationState state,
        CodexModelToggleResult result)
    {
        ArgumentNullException.ThrowIfNull(result);
        return !string.IsNullOrWhiteSpace(state.ThreadId) &&
            !string.IsNullOrWhiteSpace(result.ThreadId) &&
            QuickModelThreadIdsEqual(state.ThreadId, result.ThreadId);
    }

    internal static bool QuickModelResultCanDescribeCurrentThread(
        QuickModelPresentationState state,
        string? operationThreadId,
        CodexModelToggleResult result)
    {
        ArgumentNullException.ThrowIfNull(result);
        return string.IsNullOrWhiteSpace(result.ThreadId)
            ? QuickModelThreadIdsEqual(state.ThreadId, operationThreadId)
            : QuickModelResultTargetsCurrentThread(state, result);
    }

    internal static bool DraftConfigResultTargetsCurrentDraft(
        string? currentVisibleThreadId,
        CodexModelToggleResult result)
    {
        ArgumentNullException.ThrowIfNull(result);
        return result.Succeeded &&
            CodexDraftModelToggleService.IsDraftOperationId(result.ThreadId) &&
            (string.IsNullOrWhiteSpace(currentVisibleThreadId) ||
                CodexDraftModelToggleService.IsDraftThreadId(
                    currentVisibleThreadId));
    }

    private static bool QuickModelThreadIdsEqual(
        string? first,
        string? second) =>
        string.Equals(
            first?.Trim(),
            second?.Trim(),
            StringComparison.Ordinal);

    private QuickModelPresentationState CurrentQuickModelPresentationState =>
        new(_quickModelThreadId, _quickModel);

    private void ApplyQuickModelPresentationState(
        QuickModelPresentationState state,
        string? effort = null)
    {
        if (CurrentQuickModelPresentationState != state ||
            !string.Equals(_quickModelEffort, effort, StringComparison.Ordinal))
        {
            _quickModelPresentationRevision++;
        }
        if (state.Model != CodexQuickModel.Unknown &&
            _draftQuickModelContext is { } draft &&
            QuickModelThreadIdsEqual(state.ThreadId, draft.VisibleThreadId) &&
            CaptureDraftPresentationContext() == draft)
        {
            _draftQuickModelSelection = (state.Model, effort);
        }

        if (!QuickModelThreadIdsEqual(_quickModelThreadId, state.ThreadId) ||
            !string.Equals(_quickModel.Id, state.Model.Id, StringComparison.Ordinal))
        {
            CancelReasoningInput();
        }
        else if (_reasoningTarget is null && _reasoningPreview is { AwaitingObservation: false } preview &&
            string.Equals(preview.Effort, effort, StringComparison.OrdinalIgnoreCase))
        {
            _reasoningPreview = null;
        }
        _quickModelThreadId = state.ThreadId;
        _quickModel = state.Model;
        _quickModelEffort = effort;
        UpdateQuotaPresentation();
    }

    private async Task ToggleQuickModelAsync()
    {
        {
            await ToggleSoftwareQuickModelAsync();
            return;
        }
    }

    internal static bool IsTransientQuickModelError(string? error) =>
        error is
            "cancelled" or
            "no-visible-thread" or
            "multiple-visible-threads" or
            "thread-owner-unavailable" or
            "thread-state-unavailable" or
            "ipc-timeout" or
            "ipc-disconnected" or
            "visible-thread-changed" ||
        error?.StartsWith(
            "draft-",
            StringComparison.Ordinal) == true;

    private static string FormatQuickModelName(CodexQuickModel model) =>
        model == CodexQuickModel.Unknown ? "快捷模型" : CodexModelCatalog.ShortLabel(model.Id);

    private async Task OpenCodexMicroSettingsAsync(string label)
    {
        // Codex's own Micro bridge owns this route: an ENC press held for
        // 500 ms navigates directly to /settings/codex-micro. Do not follow
        // it with a generic settings deep link, which would overwrite the
        // correct in-app destination with the settings landing page.
        MicroSendResult? result;
        await _encoderInputGate.WaitAsync();
        try
        {
            result = await RunActionAsync(
                () => _broker.OpenCodexMicroSettingsAsync(),
                label);
        }
        finally
        {
            _encoderInputGate.Release();
        }

        if (result is null || result.Value.Disposition is not (
            MicroSendDisposition.Accepted or
            MicroSendDisposition.OutcomeUnknown))
        {
            return;
        }

        if (await ActivateCodexAsync(140))
        {
            SetLed(ActivityLed, "#9EBDFF", "Codex Micro 设置已打开");
            SetStatus("Codex Micro 设置已打开，并已将 Codex 主窗口切到前台。");
        }
    }

    private async Task RunDialInputSafelyAsync(
        Func<Task> action,
        string operation)
    {
        try
        {
            await action();
        }
        catch (Exception exception)
        {
            CancelDialGesture();
            SetLed(ActivityLed, "#FF7994", $"{operation}失败");
            SetStatus($"{operation}失败，但模拟器仍在运行：{exception.Message}");
        }
    }

    private async Task<bool> ActivateCodexAsync(
        int initialDelayMilliseconds = 90,
        bool launchIfMissing = false)
    {
        await Task.Delay(initialDelayMilliseconds);
        var attemptsBeforeLaunch = launchIfMissing ? 1 : 5;
        for (var attempt = 0; attempt < attemptsBeforeLaunch; attempt++)
        {
            if (TryActivateCodexWindow(out var activationError))
            {
                return true;
            }

            if (activationError is not null)
            {
                SetLed(ActivityLed, "#FF7994", "Codex 主窗口激活失败");
                SetStatus($"Codex 主窗口激活失败。\n{activationError.Message}");
                return false;
            }

            if (attempt < attemptsBeforeLaunch - 1)
            {
                await Task.Delay(140);
            }
        }

        if (launchIfMissing)
        {
            if (!CodexWindowActivator.TryLaunch())
            {
                SetLed(ActivityLed, "#FF7994", "Codex 启动失败");
                SetStatus("没有找到 Codex 主窗口，也无法启动已安装的 Codex 应用。");
                return false;
            }

            ShowHarnessActionStatus(
                _localization.IsEnglish ? "STARTING CODEX" : "正在启动 Codex",
                MicroHarnessDispatchStage.Starting,
                autoHide: false);
            for (var attempt = 0; attempt < 50; attempt++)
            {
                await Task.Delay(200);
                if (_windowClosed)
                {
                    return false;
                }

                if (TryActivateCodexWindow(out var activationError))
                {
                    return true;
                }

                if (activationError is not null)
                {
                    SetLed(ActivityLed, "#FF7994", "Codex 主窗口激活失败");
                    SetStatus($"Codex 主窗口激活失败。\n{activationError.Message}");
                    return false;
                }
            }
        }

        SetLed(ActivityLed, "#FFD66E", "未找到 Codex 主窗口");
        SetStatus(launchIfMissing
            ? "已请求启动 Codex，但在等待时间内没有找到其主窗口。"
            : "当前没有可激活的 Codex 主窗口。");
        return false;
    }

    private static bool TryActivateCodexWindow(out Exception? error)
    {
        try
        {
            error = null;
            return CodexWindowActivator.TryActivate(packageRoot: null);
        }
        catch (Exception exception) when (
            exception is Win32Exception or
                EntryPointNotFoundException or
                DllNotFoundException)
        {
            error = exception;
            return false;
        }
    }

    private async void Joystick_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: string tag })
        {
            return;
        }

        var parts = tag.Split('|');
        if (
            parts.Length != 2 ||
            !double.TryParse(
                parts[0],
                NumberStyles.Float,
                CultureInfo.InvariantCulture,
                out var angle))
        {
            return;
        }

        var radians = angle * Math.Tau;
        var feedbackVersion = ++_joystickFeedbackVersion;
        StopJoystickAnimations();
        JoystickTranslate.X = Math.Cos(radians) * 11;
        JoystickTranslate.Y = Math.Sin(radians) * 11;
        JoystickScale.ScaleX = 0.965;
        JoystickScale.ScaleY = 0.965;
        try
        {
            {
                await RunActionAsync(
                    () => _broker.MoveJoystickAsync(angle, 1, parts[1]),
                    $"analog {parts[1]}");
            }
        }
        finally
        {
            if (feedbackVersion == _joystickFeedbackVersion)
            {
                AnimateJoystickReturn();
            }
        }
    }

    private async void JoystickCap_MouseLeftButtonDown(
        object sender,
        MouseButtonEventArgs e)
    {
        e.Handled = true;
        if (e.LeftButton != MouseButtonState.Pressed)
        {
            return;
        }

        ++_joystickFeedbackVersion;
        StopJoystickAnimations();
        JoystickScale.ScaleX = 0.965;
        JoystickScale.ScaleY = 0.965;
        _joystickDragging = true;
        _joystickHasReportedState = false;
        _joystickActiveDirection = null;
        _joystickDragOrigin = e.GetPosition(JoystickSurface);
        _ = JoystickCap.CaptureMouse();
        if (!_broker.IsReady)
        {
            await EnsureReadyFeedbackAsync();
        }
    }

    private void JoystickCap_MouseMove(
        object sender,
        MouseEventArgs e)
    {
        if (!_joystickDragging || e.LeftButton != MouseButtonState.Pressed)
        {
            return;
        }

        e.Handled = true;
        UpdateJoystickDrag(e.GetPosition(JoystickSurface));
    }

    private void JoystickCap_MouseLeftButtonUp(
        object sender,
        MouseButtonEventArgs e)
    {
        if (!_joystickDragging)
        {
            return;
        }

        e.Handled = true;
        UpdateJoystickDrag(e.GetPosition(JoystickSurface));
        EndJoystickDrag();
    }

    private void JoystickCap_LostMouseCapture(
        object sender,
        MouseEventArgs e)
    {
        if (_joystickDragging)
        {
            EndJoystickDrag(releaseCapture: false);
        }
    }

    private void UpdateJoystickDrag(Point position)
    {
        var vector = JoystickGeometry.ResolveDelta(
            position.X - _joystickDragOrigin.X,
            position.Y - _joystickDragOrigin.Y);
        JoystickTranslate.X = vector.VisualX;
        JoystickTranslate.Y = vector.VisualY;
        QueueJoystickReport(
            vector.Angle,
            vector.Distance,
            vector.Direction ?? "center");
        _joystickHasReportedState = true;

        if (vector.Distance < JoystickGeometry.ActivationDistance)
        {
            _joystickActiveDirection = null;
            return;
        }

        if (vector.Direction == _joystickActiveDirection)
        {
            return;
        }

        _joystickActiveDirection = vector.Direction;
        SetLed(
            ActivityLed,
            "#9EBDFF",
            $"摇杆 {vector.Direction} · {vector.Distance:P0}");
    }

    private void EndJoystickDrag(bool releaseCapture = true)
    {
        if (!_joystickDragging)
        {
            return;
        }

        _joystickDragging = false;
        _joystickActiveDirection = null;
        AnimateJoystickReturn();
        if (releaseCapture && Mouse.Captured == JoystickCap)
        {
            JoystickCap.ReleaseMouseCapture();
        }

        if (_joystickHasReportedState)
        {
            QueueJoystickReport(0, 0, "center");
            _joystickHasReportedState = false;
        }
    }

    private void StopJoystickAnimations()
    {
        JoystickTranslate.BeginAnimation(
            TranslateTransform.XProperty,
            null);
        JoystickTranslate.BeginAnimation(
            TranslateTransform.YProperty,
            null);
        JoystickScale.BeginAnimation(ScaleTransform.ScaleXProperty, null);
        JoystickScale.BeginAnimation(ScaleTransform.ScaleYProperty, null);
    }

    private void AnimateJoystickReturn()
    {
        var fromX = JoystickTranslate.X;
        var fromY = JoystickTranslate.Y;
        var fromScaleX = JoystickScale.ScaleX;
        var fromScaleY = JoystickScale.ScaleY;
        StopJoystickAnimations();

        JoystickTranslate.X = 0;
        JoystickTranslate.Y = 0;
        JoystickScale.ScaleX = 1;
        JoystickScale.ScaleY = 1;

        var easing = new BackEase
        {
            Amplitude = 0.28,
            EasingMode = EasingMode.EaseOut,
        };
        var duration = new Duration(TimeSpan.FromMilliseconds(180));
        JoystickTranslate.BeginAnimation(
            TranslateTransform.XProperty,
            new DoubleAnimation(fromX, 0, duration)
            {
                EasingFunction = easing,
                FillBehavior = FillBehavior.Stop,
            });
        JoystickTranslate.BeginAnimation(
            TranslateTransform.YProperty,
            new DoubleAnimation(fromY, 0, duration)
            {
                EasingFunction = easing,
                FillBehavior = FillBehavior.Stop,
            });
        JoystickScale.BeginAnimation(
            ScaleTransform.ScaleXProperty,
            new DoubleAnimation(fromScaleX, 1, duration)
            {
                EasingFunction = easing,
                FillBehavior = FillBehavior.Stop,
            });
        JoystickScale.BeginAnimation(
            ScaleTransform.ScaleYProperty,
            new DoubleAnimation(fromScaleY, 1, duration)
            {
                EasingFunction = easing,
                FillBehavior = FillBehavior.Stop,
            });
    }

    private void QueueJoystickReport(
        double angle,
        double distance,
        string label)
    {
        if (!_broker.IsReady)
        {
            return;
        }

        var report = new JoystickReport(angle, distance, label);
        var last = _joystickReportQueue.Last;
        if (last is not null && last.Value.Distance > 0 && distance > 0)
        {
            // Coalesce intermediate drag samples while preserving every
            // neutral report between separate gestures.
            last.Value = report;
        }
        else if (last is null || last.Value.Distance > 0 || distance > 0)
        {
            _joystickReportQueue.AddLast(report);
        }

        if (!_joystickReportPumpActive)
        {
            _ = DrainJoystickReportsAsync();
        }
    }

    private async Task DrainJoystickReportsAsync()
    {
        _joystickReportPumpActive = true;
        try
        {
            while (_joystickReportQueue.First is { } node)
            {

                var report = node.Value;
                _joystickReportQueue.RemoveFirst();
                var result = await _broker.SetJoystickStateAsync(
                    report.Angle,
                    report.Distance,
                    report.Label);
                if (result.Disposition is
                    MicroSendDisposition.NotSent or
                    MicroSendDisposition.Rejected)
                {
                    _joystickReportQueue.Clear();
                    PresentSoftwareActionResult($"analog {report.Label}", result);
                    await RecordSoftwareActionAsync($"analog {report.Label}", result);
                    break;
                }

                if (result.Disposition == MicroSendDisposition.OutcomeUnknown || result.IsBoundary)
                {
                    PresentSoftwareActionResult($"analog {report.Label}", result);
                    await RecordSoftwareActionAsync($"analog {report.Label}", result);
                }
            }
        }
        catch (Exception exception) when (
            exception is InvalidOperationException or
                IOException or
                Win32Exception or
                InvalidDataException)
        {
            _joystickReportQueue.Clear();
            var result = MicroSendResult.NotSent(exception.Message);
            PresentSoftwareActionResult("analog", result);
            await RecordSoftwareActionAsync("analog", result);
        }
        finally
        {
            _joystickReportPumpActive = false;
        }
    }

    private async Task<MicroSendResult?> RunActionAsync(
        Func<Task<MicroSendResult>> action,
        string label,
        string? transportLabel = null)
    {

        SetLed(ActivityLed, "#9EBDFF", $"正在发送 {label}", glow: true);
        try
        {
            var result = await action();
            PresentSoftwareActionResult(label, result, transportLabel);
            await RecordSoftwareActionAsync(label, result);
            return result;
        }
        catch (Exception exception) when (
            exception is InvalidOperationException or
                IOException or
                Win32Exception or
                InvalidDataException)
        {
            var result = MicroSendResult.NotSent(exception.Message);
            PresentSoftwareActionResult(label, result, transportLabel);
            await RecordSoftwareActionAsync(label, result);
            return null;
        }
    }

    private async Task EnsureReadyFeedbackAsync()
    {
        {
            await ConnectAsync();
            return;
        }
    }

    private void Window_SourceInitialized(object? sender, EventArgs e)
    {
        _windowSource = PresentationSource.FromVisual(this) as HwndSource;
        if (_windowSource is not null)
        {
            NonActivatingWindow.ApplyNoActivateStyle(_windowSource.Handle);
            _windowSource.AddHook(WindowMessageHook);
        }
    }

    private IntPtr WindowMessageHook(
        IntPtr windowHandle,
        int message,
        IntPtr wordParameter,
        IntPtr longParameter,
        ref bool handled)
    {
        if (NonActivatingWindow.TryHandleMessage(
            message,
            ref handled,
            out var nonActivatingResult))
        {
            return nonActivatingResult;
        }

        return IntPtr.Zero;
    }

    private void DeviceFrame_MouseLeftButtonDown(
        object sender,
        MouseButtonEventArgs e)
    {
        if (e.LeftButton != MouseButtonState.Pressed ||
            FindAncestor<ButtonBase>(e.OriginalSource as DependencyObject) is not null)
        {
            return;
        }

        _windowMoving = true;
        _windowMoveStartScreen = PointToScreen(e.GetPosition(this));
        _windowMoveStartPosition = new Point(Left, Top);
        _windowMoveDpi = VisualTreeHelper.GetDpi(this);
        _ = CaptureMouse();
        e.Handled = true;
    }

    private void Window_PreviewMouseMove(object sender, MouseEventArgs e)
    {
        if (!_windowMoving || e.LeftButton != MouseButtonState.Pressed)
        {
            return;
        }

        var screen = PointToScreen(e.GetPosition(this));
        Left = _windowMoveStartPosition.X +
            (screen.X - _windowMoveStartScreen.X) /
            Math.Max(_windowMoveDpi.DpiScaleX, 1);
        Top = _windowMoveStartPosition.Y +
            (screen.Y - _windowMoveStartScreen.Y) /
            Math.Max(_windowMoveDpi.DpiScaleY, 1);
        e.Handled = true;
    }

    private void Window_PreviewMouseLeftButtonUp(
        object sender,
        MouseButtonEventArgs e)
    {
        EndWindowMove();
    }

    private void Window_LostMouseCapture(
        object sender,
        MouseEventArgs e) => _windowMoving = false;

    private void EndWindowMove()
    {
        if (!_windowMoving)
        {
            return;
        }

        _windowMoving = false;
        if (IsMouseCaptured)
        {
            ReleaseMouseCapture();
        }

        _profileSettings.SetWindowPlacement(Left, Top, Topmost);
    }

    private void DeviceFrame_ContextMenuOpening(
        object sender,
        ContextMenuEventArgs e)
    {
        if (
            FindAncestor<Button>(e.OriginalSource as DependencyObject) is
                { ContextMenu: null })
        {
            e.Handled = true;
        }
    }

    private void DeviceContextMenu_Opened(object sender, RoutedEventArgs e)
    {
        TopmostMenuItem.IsChecked = Topmost;
    }

    private void HarnessContextMenu_Opened(object sender, RoutedEventArgs e)
        => PopulateHarnessContextMenu();

    internal void PopulateHarnessContextMenu()
    {
        return;
    }

    internal void AddHarnessInNewKeypad(string harnessId, string title)
    {
        if (_openHarnessInNewKeypad is null ||
            string.IsNullOrWhiteSpace(harnessId))
        {
            return;
        }

        var currentHarnessId = _profileSettings.Current.ActiveHarnessId;
        _suppressedHarnessSelectionId = harnessId;
        HarnessContextMenu.IsOpen = false;
        _openHarnessInNewKeypad(harnessId);

        // The controller callback is expected to create a separate profile.
        // Preserve the source window even if a future callback accidentally
        // mutates the profile while doing so.
        if (!string.Equals(
                _profileSettings.Current.ActiveHarnessId,
                currentHarnessId,
                StringComparison.OrdinalIgnoreCase))
        {
            _profileSettings.SetActiveHarness(currentHarnessId);
            RefreshHarnessPresentation();
        }

        SetStatus(_localization.IsEnglish
            ? $"Added a new {title} keypad; this keypad is unchanged."
            : $"已新增 {title} 小键盘；当前小键盘未改变。");
    }

    private void TopmostMenuItem_Click(object sender, RoutedEventArgs e) =>
        SetTopmostState(TopmostMenuItem.IsChecked);

    private async void ReconnectMenuItem_Click(object sender, RoutedEventArgs e) =>
        await ReconnectAsync();

    private async Task ReconnectAsync()
    {
        if (!_broker.IsReady)
        {
            await ConnectAsync();
            return;
        }

        if (_connecting)
        {
            return;
        }

        _connecting = true;
        try
        {
            var info = await _broker.RecoverCodexLinkAsync();
            _transportName = info.TransportName;
            ApplyTransportReadyState();
        }
        catch (Exception exception) when (
            exception is InvalidOperationException or
                Win32Exception or
                InvalidDataException or
                IOException)
        {
            SetStatus(LocalizeDriverError(exception));
        }
        finally
        {
            _connecting = false;
        }
    }

    private void OpenSoftwareSettingsMenuItem_Click(
        object sender,
        RoutedEventArgs e) => ShowSoftwareSettings();

    private async void OpenOfficialSettingsMenuItem_Click(
        object sender,
        RoutedEventArgs e) =>
        await OpenCodexMicroSettingsAsync("打开 Codex Micro 设置");

    private void ShowSoftwareSettings()
    {
        if (_settingsWindow is not null)
        {
            if (_settingsWindow.WindowState == WindowState.Minimized)
            {
                _settingsWindow.WindowState = WindowState.Normal;
            }

            _settingsWindow.Topmost = Topmost;
            _settingsWindow.Show();
            _settingsWindow.Activate();
            return;
        }

        var settings = new MicroSettingsWindow(
            _localization,
            _profileSettings,
            DesignSurface,
            _layoutObserver,
            _configWriter,
            _harnessRegistry,
            () => OpenCodexMicroSettingsAsync("打开 Codex Micro 设置"),
            ReconnectAsync,
            () => _broker.IsReady,
            () => _modelToggleService
                .BroadcastUserSavedConfigInvalidationAsync(),
            coreOnly: true)
        {
            Owner = this,
            Topmost = Topmost,
        };
        _settingsWindow = settings;
        settings.Closed += (_, _) =>
        {
            if (ReferenceEquals(_settingsWindow, settings))
            {
                _settingsWindow = null;
            }
        };
        settings.Show();
        settings.Activate();
    }

    private void ExitMenuItem_Click(object sender, RoutedEventArgs e) => Hide();

    private void CloseKeypadMenuItem_Click(
        object sender,
        RoutedEventArgs e)
    {
        if (_canCloseKeypad)
        {
            _closeKeypad?.Invoke();
        }
        else
        {
            Hide();
        }
    }

    private void SetTopmostState(bool value)
    {
        Topmost = value;
        TopmostMenuItem.IsChecked = value;
        _profileSettings.SetWindowPlacement(Left, Top, value);
        if (value)
        {
            _lastForegroundWindow = IntPtr.Zero;
            RefreshTopmostContinuity();
        }

        SetStatus(value
            ? "窗口已置顶。右击机身空白处可取消置顶。"
            : "窗口已取消置顶。右击机身空白处可再次置顶。");
    }

    private void Broker_Log(object? sender, string message)
    {
        _ = Dispatcher.InvokeAsync(() =>
        {
            SetHelp(ActivityLed, "最近事件", message);
        });
    }

    private void Broker_StateChanged(object? sender, string state)
    {
        _ = Dispatcher.InvokeAsync(() =>
        {
            {
                ApplySoftwareConnectionState(state == "ready");
                return;
            }
        });
    }

    private void ApplyTransportReadyState()
    {
        {
            ApplySoftwareConnectionState(_broker.IsReady);
            return;
        }
    }

    private void Broker_SlotLightingObserved(
        object? sender,
        SlotLightingSnapshot snapshot)
    {
        _ = Dispatcher.InvokeAsync(() =>
        {
            if (snapshot.Sequence <= _lastSlotLightingSequence)
            {
                return;
            }

            _lastSlotLightingSequence = snapshot.Sequence;
            _latestSlotLighting = snapshot;

            ReconcileConfirmedUnreadProjectionWithLighting();
            ResolveCurrentAgentSlot();
            RefreshAgentSlotPresentation();

            var lightingBySlot = snapshot.Slots
                .Where(slot => slot.SlotId is >= 0 and < 6)
                .ToDictionary(slot => slot.SlotId);
            var litSlots = Enumerable.Range(0, _agentKeys.Length).Count(slotId =>
            {
                lightingBySlot.TryGetValue(slotId, out var slot);
                return AgentLightingAppearance.From(
                    slot,
                    slotId == _currentAgentSlotId).IsActive;
            });

            SetHelp(
                DriverLed,
                "虚拟 HID",
                $"{_transportName} · Agent 状态已同步 · {litSlots} 个亮灯槽位");
        });
    }

    private void ResolveCurrentAgentSlot()
    {

        var currentThreadId = CurrentCodexAgentThreadId();
        if (currentThreadId is null)
        {
            _currentAgentSlotId = null;
            return;
        }

        if (_latestAgentRoster is { Source: CodexRecentThreadsService.SourceName } roster)
        {
            _currentAgentSlotId = roster.Entries
                .FirstOrDefault(entry => entry.ThreadId == currentThreadId)?.SlotId;
            return;
        }

        _currentAgentSlotId = AgentLightingAppearance.ResolveCurrentSessionSlot(
            _latestSlotLighting?.Slots ?? [],
            _currentAgentSlotId);
    }

    private AgentLightingAppearance ResolveCodexAgentAppearance(
        int slotId,
        SlotLighting? lighting,
        CodexAgentRosterEntry? rosterEntry)
    {
        var protocolAppearance = AgentLightingAppearance.From(lighting);
        var currentThreadId = CurrentCodexAgentThreadId();
        var isCurrentSession = currentThreadId is not null &&
            (rosterEntry is not null
                ? rosterEntry.ThreadId == currentThreadId
                : slotId == _currentAgentSlotId);
        if (_monitorAvailable && rosterEntry is not null &&
            _monitoredTasks?.FirstOrDefault(task => task.Id == rosterEntry.ThreadId) is { } task)
        {
            var status = ResolveMonitoredTaskStatus(task.Status);
            return ResolveMonitoredCodexAppearance(
                task.Id, status, isCurrentSession, task.HasPendingQuestion, task.ErrorCode);
        }

        var canShowUnread = !protocolAppearance.IsActive ||
            lighting?.Color == 0xFFFFFF;
        if (canShowUnread &&
            (_manualUnreadThreads.IsConfirmed(rosterEntry?.ThreadId)))
        {
            return AgentLightingAppearance.ManualUnread(isCurrentSession);
        }

        // Active work, input-required, errors, and other colored protocol
        // states take visual priority without erasing the optimistic unread
        // projection. White idle is lower priority while confirmation waits.
        return AgentLightingAppearance.From(lighting, isCurrentSession);
    }

    private void ReconcileConfirmedUnreadProjectionWithLighting()
    {
        if (_latestSlotLighting is null || _latestAgentRoster is null)
        {
            return;
        }

        foreach (var lighting in _latestSlotLighting.Slots)
        {
            if (lighting.Color != 0x00FF4C ||
                !AgentLightingAppearance.From(lighting).IsActive)
            {
                continue;
            }

            _manualUnreadThreads.ClearConfirmed(
                _latestAgentRoster.GetSlot(lighting.SlotId)?.ThreadId);
        }
    }

    private void RefreshAgentSlotPresentation()
    {
        RefreshMonitorPresentation();
        if (_pageMotionActive)
        {
            return;
        }
        var departures = CaptureDepartingTaskKeys(monitor: false,
            PageKeyVisuals(monitor: false).Select(visual => visual.Identity));

        AgentBackGlyph.Visibility = Visibility.Collapsed;

        var lightingBySlot = _latestSlotLighting?.Slots
            .Where(slot => slot.SlotId is >= 0 and < 6)
            .ToDictionary(slot => slot.SlotId) ?? [];

        for (var slotId = 0; slotId < _agentKeys.Length; slotId++)
        {
            _agentKeys[slotId].IsEnabled = true;
            lightingBySlot.TryGetValue(slotId, out var lighting);
            var rosterEntry = _latestAgentRoster?.GetSlot(slotId);
            var appearance = ResolveCodexAgentAppearance(
                slotId,
                lighting,
                rosterEntry);
            ApplyAgentLightingAppearance(slotId, appearance);

            var title = rosterEntry?.DisplayTitle ?? $"Agent 槽位 {slotId + 1}";
            var state = appearance.UsesNeutralSelectionRing
                ? appearance.StatusName
                : appearance.IsActive
                ? $"{appearance.StatusName} · " +
                    $"#{appearance.Color.R:X2}{appearance.Color.G:X2}" +
                    $"{appearance.Color.B:X2} · " +
                    $"{appearance.EffectName} · " +
                    $"显示亮度 {appearance.DisplayOpacity:P0}"
                : appearance.StatusName;
            if (appearance.IsCurrentSession && !appearance.UsesWhiteFallback)
            {
                state = $"当前会话 · {state}";
            }

            var localMatch = rosterEntry is null
                ? string.Empty
                : "\n项目与标题来自 Codex 本地最近任务索引。";
            SetHelp(
                _agentKeys[slotId],
                title,
                $"Agent 槽位 {slotId + 1} · AG{slotId:00} · {state} · 单击切换" +
                (rosterEntry is not null && !appearance.IsActive
                    ? "；右击标记为未读。"
                    : "。") +
                localMatch);
        }
        UpdateTaskKeyMotion(monitor: false, departures);
    }

    private bool IsHarnessMenuNavigationActive(MicroHarnessDefinition harness) =>
        false;

    internal static AgentLightingAppearance ApplyAgentLightingAppearance(
        Button key,
        AgentLightingAppearance appearance)
    {
        appearance = appearance.ForDisplay();
        var mintSelectionLight = appearance.UsesMintSelectionLight;
        var whiteLight = appearance.Color == Colors.White && appearance.DisplayOpacity > 0;
        key.BorderBrush = new SolidColorBrush(appearance.Color)
        {
            Opacity = appearance.DisplayOpacity,
        };
        key.ApplyTemplate();
        ApplyAgentShadowAppearance(key, whiteLight);
        SetTemplatePartOpacity(key, "AgentGlyph", whiteLight || mintSelectionLight ? 0 : 0.6);
        SetTemplatePartOpacity(key, "WhiteAgentGlyph", whiteLight && !mintSelectionLight ? 1 : 0);
        SetTemplatePartOpacity(key, "MintAgentGlyph", mintSelectionLight ? 1 : 0);
        SetTemplatePartOpacity(key, "MintSeamLight", mintSelectionLight ? 1 : 0);
        SetTemplatePartOpacity(key, "MintCapReturn", mintSelectionLight ? 1 : 0);
        SetTemplatePartOpacity(key, "MintWellLight", mintSelectionLight ? 1 : 0);
        SetTemplatePartOpacity(key, "MintWellReturn", mintSelectionLight ? 1 : 0);
        SetTemplatePartOpacity(key, "CurrentSessionRing", 0);
        if (key.Template.FindName("GlowWide", key) is Border wide &&
            key.Template.FindName("Glow", key) is Border near)
        {
            ApplyAgentGlowAppearance(wide, near, key.BorderBrush, appearance);
        }
        SetTemplatePartOpacity(key, "StatusCapWash", appearance.CapWashOpacity);
        SetTemplatePartOpacity(
            key,
            "StatusLightField",
            appearance.LightFieldOpacity);
        SetTemplatePartOpacity(key, "StatusWellWash", appearance.WellWashOpacity);
        return appearance;
    }

    private static void ApplyAgentShadowAppearance(Button key, bool whiteLight)
    {
        SetTemplatePartOpacity(key, "CapInsetShadow", whiteLight ? 0.25 : 1);
        if (key.Template.FindName("FarShadow", key) is Border farShadow)
        {
            farShadow.Background = (Brush)key.FindResource(
                whiteLight ? "AgentWhiteLightFarShadowBrush" : "AgentFarShadowBrush");
        }
        if (key.Template.FindName("Cap", key) is Border cap)
        {
            cap.Effect = (Effect)key.FindResource(
                whiteLight ? "AgentWhiteLightKeyShadow" : "AgentKeyShadow");
        }
        if (key.Template.FindName("AgentWellHighlight", key) is Ellipse wellHighlight)
        {
            if (whiteLight)
                wellHighlight.Stroke = (Brush)key.FindResource("PaperWhiteLightRecessRingBrush");
            else
                wellHighlight.ClearValue(Shape.StrokeProperty);
        }
    }

    internal void ApplyAgentLightingAppearance(
        int slotId,
        AgentLightingAppearance appearance)
    {
        var key = _agentKeys[slotId];
        appearance = ApplyAgentLightingAppearance(key, appearance);

        // The window renders all outer light before any physical key. Disable
        // the self-contained template bloom so later siblings cannot paint a
        // colored outline over earlier keycaps.
        SetTemplatePartOpacity(key, "GlowWide", 0);
        SetTemplatePartOpacity(key, "Glow", 0);

        ApplyAgentGlowAppearance(
            _agentWideGlows[slotId],
            _agentNearGlows[slotId],
            key.BorderBrush,
            appearance);
    }

    internal static void ApplyAgentGlowAppearance(
        Border wide,
        Border near,
        Brush brush,
        AgentLightingAppearance appearance)
    {
        var glowBrush = appearance.UsesNeutralSelectionRing
            ? Brushes.White
            : brush;
        wide.Background = glowBrush;
        near.Background = glowBrush;
        wide.Opacity = appearance.WideGlowOpacity;
        near.Opacity = appearance.OuterGlowOpacity;
    }

    private static void SetTemplatePartOpacity(
        Button key,
        string partName,
        double opacity)
    {
        if (key.Template.FindName(partName, key) is UIElement part)
        {
            part.Opacity = opacity;
        }
    }

    private void LayoutObserver_LayoutChanged(
        object? sender,
        CodexMicroLayoutSnapshot snapshot)
    {
        _ = Dispatcher.InvokeAsync(() => ApplyLayout(snapshot));
    }

    private void ApplyLayout(CodexMicroLayoutSnapshot snapshot)
    {
        ActionKey10.Visibility = snapshot.SeparateMicrophoneKeys
            ? Visibility.Collapsed
            : Visibility.Visible;
        ActionKey10Split.Visibility = snapshot.SeparateMicrophoneKeys
            ? Visibility.Visible
            : Visibility.Collapsed;
        ActionKey11Split.Visibility = snapshot.SeparateMicrophoneKeys
            ? Visibility.Visible
            : Visibility.Collapsed;

        foreach (var (slotId, presentation) in _actionKeys)
        {
            var binding = snapshot.GetSlot(slotId);
            presentation.Icon.KeycapId = _broker.UsesSoftwareControl
                ? _profileSettings.ResolveKeycapIcon(slotId, binding.KeycapId) : binding.KeycapId;
            SetActionKeyHelp(presentation.Button, binding);
        }

        RefreshDialHelp(snapshot);

        var defaultAnalog = new Dictionary<string, string>(StringComparer.Ordinal)
        {
            ["up"] = "composer.togglePlanMode",
            ["right"] = "navigateForward",
            ["down"] = "toggleSidebar",
            ["left"] = "navigateBack",
        };
        foreach (var (direction, button) in _joystickButtons)
        {
            var action = snapshot.AnalogActions.TryGetValue(direction, out var configured)
                ? configured
                : defaultAnalog[direction];
            SetHelp(
                button,
                $"摇杆方向 · {direction}",
                $"{action} · 单击触发并自动回中。");
        }

        RefreshHarnessPresentation();
        RefreshSoftwareFeedback();
    }

    private void RefreshDialHelp(CodexMicroLayoutSnapshot snapshot)
    {
        var harness = ActiveHarness();

        SetHelp(
            DialButton,
            snapshot.EncoderMode == "reasoning"
                ? "推理强度旋钮"
                : "选择旋钮",
            snapshot.EncoderMode == "reasoning"
                ? "滚轮/按住左键上下或左右拖动：只调节推理强度。\n短按：在快捷模型 A/B 间切换。"
                : "滚轮/按住左键上下或左右拖动：移动输入区控件或菜单选项。\n短按：打开或确认。");
    }

    private MicroHarnessDefinition ActiveHarness() =>
        _harnessRegistry.Resolve(_profileSettings.Current.ActiveHarnessId);

    private static bool IsHarnessForeground(MicroHarnessDefinition harness) =>
        CodexWindowActivator.IsForeground(packageRoot: null);

    private bool SupportsHarnessComposerSubmit(
        MicroHarnessDefinition harness) =>
        (_harnessStateSnapshot?.HarnessId == harness.Id &&
            _harnessStateSnapshot.Capabilities.Supports(
                MicroHarnessActionIds.ComposerSubmit));

    private void ApplyHarnessContext()
    {
        var harness = ActiveHarness();
        var changed = harness.Id != _activeHarnessContextId;
        _activeHarnessContextId = harness.Id;
        ApplyHarnessTheme(harness);
        if (changed)
        {
            _actionTargetIsForeground = false;
            _harnessActionStatusVersion++;
            _settingsDisplayProgress = null;
            _voiceSurfaceStatus = null;
            _harnessActionElapsedTimer.Stop();
            HideHarnessProgressStatus();

            _harnessStateSnapshot = null;
            _selectedHarnessSessionId = null;
            _currentAgentSlotId = null;
            _encoderSteps.Clear();
            CancelReasoningInput();
            _joystickReportQueue.Clear();
        }

        {
            PauseHarnessStateRefresh();
            ResolveCurrentAgentSlot();
            StartQuotaRefresh();
        }

        RefreshHarnessPresentation();
        var knobMode = _harnessRegistry.ResolveKnobMode(harness.Id);
        HarnessDialModeLabel.Text = knobMode switch
        {
            MicroHarnessKnobModes.ComposerNavigation => "INPUT",
            MicroHarnessKnobModes.ReasoningOnly => "MIND",
            _ => string.Empty,
        };
        HarnessDialModeLabel.Visibility = Visibility.Collapsed;
        RefreshDialHelp(_layoutObserver.Current);
        RefreshAgentSlotPresentation();
        UpdateQuotaPresentation();
        if (changed && IsLoaded)
        {
            UpdateMonitorRefresh();
            _ = Dispatcher.BeginInvoke(
                System.Windows.Threading.DispatcherPriority.ContextIdle,
                new Action(PromptForHarnessSetupIfNeeded));
        }
    }

    private void PromptForHarnessSetupIfNeeded()
    {
        var harness = ActiveHarness();
        {
            return;
        }
    }

    private void RefreshHarnessPresentation()
    {
        var harness = ActiveHarness();
        var english = _localization.IsEnglish;
        var connected = _harnessStateSnapshot?.HarnessId == harness.Id;
        ActionIcon12.KeycapId = _profileSettings.ResolveKeycapIcon("ACT12", _layoutObserver.Current.GetSlot("ACT12").KeycapId);
        SetHelp(
            ActionKey12,
            "Codex",
            english
                ? $"ACT12 · current target: {harness.DisplayName}. Left-click activates it; right-click switches Agent / Harness.{(string.Empty)}"
                : $"ACT12 · 当前目标：{harness.DisplayName}。左键激活；右键切换 Agent / Harness。{(string.Empty)}" );
        AutomationProperties.SetItemStatus(
            ActionKey12,
            english
                ? $"Current target: {harness.DisplayName}"
                : $"当前目标：{harness.DisplayName}");
        RefreshHarnessStatusLeds(harness);
        RefreshHarnessControlPresentation(harness);
        RefreshActionKeyPresentation();
    }

    private void RefreshActionKeyPresentation()
    {
        var harness = ActiveHarness();
        if (_broker.UsesSoftwareControl)
        {
            ActionSendBadge.Visibility = _actionTargetIsForeground &&
                _layoutObserver.Current.GetSlot("ACT12").ResolvedAction == "composer.submit"
                    ? Visibility.Visible : Visibility.Collapsed;
            SetActionKeyHelp(ActionKey12, _layoutObserver.Current.GetSlot("ACT12"));
            return;
        }
        var english = _localization.IsEnglish;
        var canSend = SupportsHarnessComposerSubmit(harness);
        var sends = canSend && _actionTargetIsForeground;
        ActionSendBadge.Visibility = sends
            ? Visibility.Visible
            : Visibility.Collapsed;

        var displayName = "Codex";
        SetHelp(
            ActionKey12,
            displayName,
            sends
                ? english
                    ? $"ACT12 · {displayName} is in the foreground. The paper-plane badge means this key sends the current input. Right-click switches Agent / Harness."
                    : $"ACT12 · {displayName} 正在前台。纸飞机角标表示此键会发送当前输入；右键可切换 Agent / Harness。"
                : canSend
                    ? english
                        ? $"ACT12 · Brings {displayName} to the foreground. Once it is in front, a paper-plane badge appears and this key sends the current input. Right-click switches Agent / Harness."
                        : $"ACT12 · 将 {displayName} 置于前台。置前后会出现纸飞机角标，此键随即用于发送当前输入；右键可切换 Agent / Harness。"
                    : english
                        ? $"ACT12 · Opens or focuses {displayName}. Its adapter has not advertised direct composer submit."
                        : $"ACT12 · 打开或置前 {displayName}。当前适配器尚未声明直接发送能力。");
        AutomationProperties.SetItemStatus(
            ActionKey12,
            sends
                ? english
                    ? $"{displayName} is in the foreground; send key"
                    : $"{displayName} 正在前台；发送键"
                : canSend
                    ? english
                        ? $"{displayName} is not in the foreground; activate key"
                        : $"{displayName} 不在前台；置前键"
                    : english
                        ? $"{displayName} direct send unavailable; activate key"
                        : $"{displayName} 直接发送不可用；置前键");
    }

    private void RefreshHarnessStatusLeds(MicroHarnessDefinition harness)
    {
        {
            return;
        }
    }

    private void SetVoiceServiceState(
        KeypadVoiceServiceState state,
        string message)
    {
        if (!Dispatcher.CheckAccess())
        {
            _ = Dispatcher.BeginInvoke(new Action(() =>
                SetVoiceServiceState(state, message)));
            return;
        }

        _voiceServiceState = state;
        _voiceServiceMessage = string.IsNullOrWhiteSpace(message)
            ? _localization.IsEnglish
                ? "Keypad voice status is unavailable."
                : "小键盘语音状态不可用。"
            : message.Trim();
    }

    private void ApplyHarnessTheme(MicroHarnessDefinition harness)
    {
        {
            RestoreCodexGlassTheme();
            LeftSilkScreen.Text = "CODEX  /  MICRO  /  CRYSTAL HID";
            BrandCodexIcon.KeycapId = "CODEX";
            BrandWordmarkText.Text = "OPENAI  CODEX";
            HarnessThemeWash.Opacity = 0;
            return;
        }
    }

    private void RestoreCodexGlassTheme()
    {
        DeviceFrame.Background = _codexDeviceFrameBackground;
        PearlLightGuide.Background = _codexPearlLightGuideBackground;
        CrystalDepthPlate.Background = _codexCrystalDepthBackground;
        CrystalPrismRim.BorderBrush = _codexCrystalPrismBorder;
        CrystalLowerRefraction.Background =
            _codexLowerRefractionBackground;
    }

    private void RefreshHarnessControlPresentation(
        MicroHarnessDefinition harness)
    {
        var snapshot = _layoutObserver.Current;
        {
            foreach (var (slotId, presentation) in _actionKeys)
            {
                var binding = snapshot.GetSlot(slotId);
                presentation.Icon.KeycapId = _broker.UsesSoftwareControl
                    ? _profileSettings.ResolveKeycapIcon(slotId, binding.KeycapId) : binding.KeycapId;
                SetActionKeyHelp(presentation.Button, binding);
            }

            var defaults = new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["up"] = "composer.togglePlanMode",
                ["right"] = "navigateForward",
                ["down"] = "toggleSidebar",
                ["left"] = "navigateBack",
            };
            foreach (var (direction, button) in _joystickButtons)
            {
                var action = snapshot.AnalogActions.TryGetValue(
                    direction,
                    out var configured)
                        ? configured
                        : defaults[direction];
                SetHelp(
                    button,
                    $"摇杆方向 · {direction}",
                    $"{action} · 单击触发并自动回中。");
            }

            RefreshSoftwareActionAvailability();
            return;
        }
    }

    internal void ApplyQuotaSnapshot(
        CodexQuotaSnapshot? snapshot,
        bool refreshFailed = false)
    {
        _quotaSnapshot = snapshot;
        _quotaRefreshFailed = refreshFailed;
        UpdateQuotaPresentation();
    }

    /// <summary>
    /// Applies one adapter snapshot without starting a real Harness. Off-screen
    /// visual QA uses the exact production mapping for running sessions and
    /// the Harness component status LEDs.
    /// </summary>
    internal void ApplyHarnessStateForVisualTest(
        MicroHarnessStateSnapshot snapshot)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        _harnessStateSnapshot = snapshot;
        _selectedHarnessSessionId = snapshot.CurrentSessionId;
        _currentAgentSlotId = snapshot.CurrentSessionId is null
            ? null
            : snapshot.Sessions
                .Select((session, index) => (session, index))
                .Where(item => item.session.Id == snapshot.CurrentSessionId)
                .Select(item => (int?)item.index)
                .FirstOrDefault();
        RefreshAgentSlotPresentation();
        RefreshHarnessPresentation();
        UpdateQuotaPresentation();
    }

    internal void ApplyVoiceServiceStateForVisualTest(
        bool ready,
        bool checking = false,
        bool error = false,
        bool listening = false)
    {
        var state = error
            ? KeypadVoiceServiceState.Error
            : checking
                ? KeypadVoiceServiceState.Checking
                : listening
                    ? KeypadVoiceServiceState.Listening
                    : ready
                        ? KeypadVoiceServiceState.Ready
                        : KeypadVoiceServiceState.Unavailable;
        SetVoiceServiceState(
            state,
            state switch
            {
                KeypadVoiceServiceState.Ready => "小键盘语音服务已就绪。",
                KeypadVoiceServiceState.Listening => "小键盘正在聆听。",
                KeypadVoiceServiceState.Checking => "正在检查小键盘语音服务。",
                KeypadVoiceServiceState.Error => "小键盘语音服务错误。",
                _ => "小键盘语音服务尚未启动。",
            });
    }

    internal void ApplyQuickModel(
        string threadId,
        CodexQuickModel model)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(threadId);
        ApplyQuickModelPresentationState(new(threadId.Trim(), model));
    }

    internal void ApplyQuickModel(CodexQuickModel model) =>
        ApplyQuickModel("visual-test-thread", model);

    private void UpdateQuotaPresentation()
    {
        var english = _localization.IsEnglish;
        var harness = ActiveHarness();
        var deepSeek = false;
        SettingsKey.UseQuotaReadout = _voiceSurfaceStatus is null;
        ApplySettingsDisplayTheme(light: deepSeek);
        if (_voiceSurfaceStatus is { } voiceStatus)
        {
            ApplyVoiceSurfaceStatus(voiceStatus);
            return;
        }
        if (deepSeek && _settingsDisplayProgress is { } progress)
        {
            ApplySettingsDisplayProgress(progress);
            return;
        }

        var quickModelSwitching = _quickModelSwitching &&
            (string.IsNullOrWhiteSpace(_quickModelSwitchingThreadId) ||
                (CodexModelToggleService.IsForegroundDraftOperationId(
                    _quickModelSwitchingThreadId)
                    ? string.IsNullOrWhiteSpace(_quickModelThreadId)
                    : QuickModelThreadIdsEqual(
                        _quickModelSwitchingThreadId,
                        _quickModelThreadId)));
        SettingsKey.ModelId = _quickModel.Id;
        SettingsKey.DisplayMode = _reasoningFeedbackCancellation is not null || _reasoningAdjusting
            ? QuotaKnobDisplayMode.Model
            : QuotaKnobDisplayMode.Auto;
        SettingsKey.ReasoningEffort = _reasoningPreview?.Effort ?? _quickModelEffort ?? string.Empty;
        SettingsKey.MaximumReasoningEffort = _reasoningCatalog is { IsFresh: true } catalog
            ? catalog.Find(_quickModel.Id)?.SupportedEfforts.LastOrDefault() ?? "ultra"
            : "ultra";
        SettingsKey.IsUpdating = quickModelSwitching || (_reasoningAdjusting);
        SettingsKey.HasFiveHourWindow = _quotaSnapshot?.FiveHourWindow is not null;
        SettingsKey.HasWeeklyWindow = _quotaSnapshot?.WeeklyWindow is not null;
        SettingsKey.FiveHourRemaining = _quotaSnapshot?.FiveHourWindow?.RemainingPercent;
        SettingsKey.WeeklyRemaining = _quotaSnapshot?.WeeklyWindow?.RemainingPercent;
        AutomationProperties.SetItemStatus(SettingsKey,
            _quotaRefreshFailed
                ? english ? "Quota refresh unavailable" : "额度刷新暂不可用"
                : string.Empty);
        if (_quotaSnapshot is { } snapshot)
        {
            var quotaHelp = BuildQuotaHelpDetail(snapshot);
            ApplyHelp(SettingsKey, "Codex 剩余额度", quotaHelp.Detail, quotaHelp.Content);
        }
        else
        {
            ApplyHelp(SettingsKey, "Codex 剩余额度", _quotaRefreshFailed
                ? "额度暂不可用"
                : "正在读取 Codex 剩余额度。");
        }
    }

    private void ApplySettingsDisplayTheme(bool light)
    {
        SettingsKey.Background = new SolidColorBrush(light
            ? Color.FromRgb(0xFA, 0xFA, 0xF8)
            : Color.FromRgb(0x2D, 0x29, 0x25));
        QuotaTrackRing.Stroke = new SolidColorBrush(light
            ? Color.FromRgb(0xC9, 0xCC, 0xCA)
            : Color.FromArgb(0x2E, 0xFF, 0xFF, 0xFF));
        QuotaValueText.Foreground = new SolidColorBrush(light
            ? Color.FromRgb(0x1D, 0x1D, 0x1B)
            : Color.FromRgb(0xF7, 0xFA, 0xFF));
        QuotaCaptionText.Foreground = new SolidColorBrush(light
            ? Color.FromRgb(0x4F, 0x53, 0x50)
            : Color.FromArgb(0xBF, 0xDD, 0xE7, 0xF2));
    }

    private static string FormatQuickModelPair(
        MicroProfileSnapshot snapshot) =>
        $"{FormatQuickModelName(snapshot.QuickModelA)} / " +
        FormatQuickModelName(snapshot.QuickModelB);

    internal static Geometry CreateQuotaArcGeometry(double remainingPercent)
    {
        var clamped = Math.Clamp(remainingPercent, 0, 100);
        if (clamped <= 0)
        {
            return Geometry.Empty;
        }

        const double center = 26;
        const double radius = 23.5;
        if (clamped >= 100)
        {
            var circle = new EllipseGeometry(
                new Point(center, center),
                radius,
                radius);
            circle.Freeze();
            return circle;
        }

        var sweepAngle = 360 * clamped / 100;
        var start = PointOnQuotaCircle(-90, center, radius);
        var end = PointOnQuotaCircle(-90 + sweepAngle, center, radius);
        var geometry = new StreamGeometry();
        using (var context = geometry.Open())
        {
            context.BeginFigure(start, isFilled: false, isClosed: false);
            context.ArcTo(
                end,
                new Size(radius, radius),
                rotationAngle: 0,
                isLargeArc: sweepAngle > 180,
                SweepDirection.Clockwise,
                isStroked: true,
                isSmoothJoin: false);
        }

        geometry.Freeze();
        return geometry;
    }

    private static Point PointOnQuotaCircle(
        double angleDegrees,
        double center,
        double radius)
    {
        var angleRadians = angleDegrees * Math.PI / 180;
        return new Point(
            center + (radius * Math.Cos(angleRadians)),
            center + (radius * Math.Sin(angleRadians)));
    }

    private void SetStatus(string value)
    {
        _status = value;
        AutomationProperties.SetHelpText(this, Localize(value));
        SetHelp(
            DeviceFrame,
            "Codex Micro Monitor",
            $"{value}\n\n拖动机身移动 · 右击机身打开窗口菜单 · 关闭时收起到托盘");
    }

    private void Localization_LanguageChanged(object? sender, EventArgs e)
    {
        if (!Dispatcher.CheckAccess())
        {
            _ = Dispatcher.BeginInvoke(
                new Action(RefreshLocalizedChrome));
            return;
        }

        RefreshLocalizedChrome();
    }

    private void ProfileSettings_Changed(object? sender, EventArgs e)
    {
        if (!Dispatcher.CheckAccess())
        {
            _ = Dispatcher.BeginInvoke(
                new Action(ApplyProfileSettingsChange));
            return;
        }

        ApplyProfileSettingsChange();
    }

    private void ApplyProfileSettingsChange()
    {
        MicroWindowLayout.SizeKeypad(this, _profileSettings.Current.WindowScale);
        CancelReasoningInput();
        _dialDirectionSettings.InvertDirection =
            _profileSettings.Current.InvertDialDirection;
        ApplyHarnessContext();
        RestartVoiceBridgeMonitor();
        RestartKeypadVoiceWarmUp();
    }

    private void RestartKeypadVoiceWarmUp()
    {
        return;
    }

    private void ShowVoiceSurfaceStatus(
        VoiceSurfaceStatus status,
        bool autoHide)
    {
        _settingsDisplayProgress = null;
        _voiceSurfaceStatus = status;
        HarnessActionStatusBadge.BeginAnimation(OpacityProperty, null);
        HarnessActionStatusBadge.Visibility = Visibility.Collapsed;
        HarnessActionStatusBadge.Opacity = 0;

        Grid.SetColumn(HarnessActionProgressRing, 1);
        Grid.SetColumnSpan(HarnessActionProgressRing, 2);
        var busy = !autoHide && status.Stage is not (
            MicroHarnessDispatchStage.Failed or
            MicroHarnessDispatchStage.Foreground or
            MicroHarnessDispatchStage.Completed);
        if (busy)
        {
            if (!_harnessActionElapsedTimer.IsEnabled)
            {
                _harnessActionStartedAt = DateTimeOffset.UtcNow;
                _harnessActionElapsedTimer.Start();
            }
            StartHarnessActionProgressRing(status.Stage);
        }
        else
        {
            _harnessActionElapsedTimer.Stop();
            StopHarnessActionProgressRing();
        }

        _harnessActionBaseText = status.Text;
        ApplyVoiceSurfaceStatus(status);
        AutomationProperties.SetItemStatus(
            ActionKey10,
            Localize(status.Text));
        AutomationProperties.SetItemStatus(
            SettingsKey,
            Localize(status.Text));
        if (autoHide)
        {
            _ = HideHarnessActionStatusAsync(status.Version);
        }
    }

    private void ApplyVoiceSurfaceStatus(VoiceSurfaceStatus status)
    {
        SettingsKey.UseQuotaReadout = false;
        ApplySettingsDisplayTheme(light: false);
        QuotaCaptionText.Visibility = Visibility.Collapsed;
        if (status.Step is { } step && status.TotalSteps is { } totalSteps)
        {
            var boundedStep = Math.Clamp(step, 0, totalSteps);
            QuotaValueText.Text = $"{boundedStep}/{totalSteps}";
            QuotaValueText.FontSize = 16;
            QuotaProgressRing.Data = CreateQuotaArcGeometry(
                100d * boundedStep / totalSteps);
        }
        else
        {
            QuotaValueText.Text = status.Stage == MicroHarnessDispatchStage.Failed
                ? "!"
                : status.Stage is MicroHarnessDispatchStage.Foreground or
                    MicroHarnessDispatchStage.Completed
                    ? "MIC"
                    : "···";
            QuotaValueText.FontSize = status.Stage == MicroHarnessDispatchStage.Failed
                ? 20
                : 13;
            QuotaProgressRing.Data = Geometry.Empty;
        }
        QuotaGauge.Opacity = 1;
        QuotaProgressRing.Stroke = new SolidColorBrush(
            status.Stage == MicroHarnessDispatchStage.Failed
                ? Color.FromRgb(0xA7, 0x42, 0x56)
                : status.Stage is MicroHarnessDispatchStage.Foreground or
                    MicroHarnessDispatchStage.Completed
                    ? Color.FromRgb(0x28, 0x66, 0x4A)
                    : Color.FromRgb(0x22, 0x22, 0x22));

        BrandWordmarkPanel.Visibility = Visibility.Collapsed;
        HarnessProgressStatusText.Text = FormatHarnessActionStatusText(
            ProgressStageText(status.Text));
        HarnessProgressStatusText.Foreground = new SolidColorBrush(
            status.Stage == MicroHarnessDispatchStage.Failed
                ? Color.FromRgb(0x8B, 0x40, 0x55)
                : status.Stage is MicroHarnessDispatchStage.Foreground or
                    MicroHarnessDispatchStage.Completed
                    ? Color.FromRgb(0x31, 0x5A, 0x86)
                    : status.Stage == MicroHarnessDispatchStage.Background
                        ? Color.FromRgb(0x72, 0x5B, 0x23)
                        : Color.FromRgb(0x34, 0x41, 0x5B));
        HarnessProgressStatusText.Visibility = Visibility.Visible;

        var detail = FormatHarnessActionStatusText(status.Text);
        if (!string.IsNullOrWhiteSpace(status.Detail) &&
            !string.Equals(
                status.Detail.Trim(),
                status.Text.Trim(),
                StringComparison.OrdinalIgnoreCase))
        {
            detail += $"\n{status.Detail.Trim()}";
        }
        ApplyHelp(
            SettingsKey,
            _localization.IsEnglish ? "Voice status" : "语音状态",
            detail);
        ApplyHelp(
            ActionKey10,
            _localization.IsEnglish ? "Voice status" : "语音状态",
            detail);
    }

    private void HarnessRegistry_Changed(object? sender, EventArgs e)
    {
        if (!Dispatcher.CheckAccess())
        {
            _ = Dispatcher.BeginInvoke(
                new Action(ApplyHarnessRegistryChange));
            return;
        }

        ApplyHarnessRegistryChange();
    }

    private void ApplyHarnessRegistryChange()
    {
        ApplyHarnessContext();
        RestartVoiceBridgeMonitor();
    }

    private void RefreshLocalizedChrome()
    {
        RefreshPageHelp();
        RefreshMonitorPresentation();
        Title = $"Codex Micro Monitor · {_keypadDisplayName}";
        TopmostMenuItem.Header = Localize("窗口置顶");
        SettingsMenuItem.Header = _localization.IsEnglish ? "Settings" : "设置";
        KnobSettingsMenuItem.Header = SettingsMenuItem.Header;
        OpenSoftwareSettingsMenuItem.Header = _localization.IsEnglish
            ? "Software settings"
            : "软件设置";
        KnobOpenSoftwareSettingsMenuItem.Header =
            OpenSoftwareSettingsMenuItem.Header;
        OpenOfficialSettingsMenuItem.Header = _localization.IsEnglish
            ? "Official Codex Micro settings"
            : "Codex Micro 官方设置";
        KnobOpenOfficialSettingsMenuItem.Header =
            OpenOfficialSettingsMenuItem.Header;
        ReconnectMenuItem.Header = (_localization.IsEnglish ? "Reconnect Codex" : "重新连接 Codex");
        KnobReconnectMenuItem.Header = ReconnectMenuItem.Header;
        HidePanelMenuItem.Header = Localize("隐藏面板");
        CloseKeypadMenuItem.Header = _localization.IsEnglish
            ? "Close this keypad"
            : "关闭此小键盘";
        AutomationProperties.SetHelpText(this, Localize(_status));

        foreach (var (element, content) in _helpContent.ToArray())
        {
            ApplyHelp(element, content.Title, content.Detail);
        }

        if (_dialSelectionText is not null)
        {
            var localized = Localize(_dialSelectionText);
            DialSelectionText.Text = localized;
            AutomationProperties.SetItemStatus(DialButton, localized);
        }

        UpdateQuotaPresentation();
        RefreshHarnessPresentation();
    }

    internal void ShowSurface()
    {
        if (!IsVisible)
        {
            Show();
        }

        if (WindowState == WindowState.Minimized)
        {
            WindowState = WindowState.Normal;
        }

        NonActivatingWindow.ShowWithoutActivation(
            _windowSource?.Handle ?? IntPtr.Zero,
            Topmost);
    }

    internal void StartBackgroundServices()
    {
        if (Interlocked.Exchange(ref _backgroundServicesStarted, 1) != 0)
        {
            return;
        }

        _broker.StartConnecting();
        _ = StartCodexModelBridgeAsync();
    }

    private async Task StartCodexModelBridgeAsync()
    {
        if (!await _modelToggleService.StartAsync())
        {
            return;
        }

        try
        {
            await _modelToggleService
                .BroadcastUserSavedConfigInvalidationAsync();
        }
        catch (Exception exception) when (
            exception is IOException or
                TimeoutException or
                InvalidDataException or
                InvalidOperationException or
                ObjectDisposedException)
        {
            // Config-file watching remains the fallback when the renderer
            // disconnects between initialization and invalidation.
        }
    }

    internal void CloseForApplicationExit()
    {
        _allowApplicationClose = true;
        Close();
    }

    internal Task CloseForApplicationExitAsync()
    {
        if (!_windowClosed)
        {
            CloseForApplicationExit();
        }

        return _closeCompletion.Task;
    }

    private async void Window_Closing(object? sender, CancelEventArgs e)
    {
        if (_voiceCloseReleasePending)
        {
            e.Cancel = true;
            return;
        }

        if (_voicePressed)
        {
            e.Cancel = true;
            var closeApplication = _allowApplicationClose;
            _voiceCloseReleasePending = true;
            try
            {
                await ReleaseVoiceAsync();
            }
            catch (Exception exception)
            {
                Debug.WriteLine(
                    $"Codex Micro voice release during close failed: {exception}");
            }
            finally
            {
                _voiceCloseReleasePending = false;
            }

            if (closeApplication || _allowApplicationClose)
            {
                Close();
            }
            else
            {
                Hide();
            }
            return;
        }

        if (_allowApplicationClose)
        {
            return;
        }

        e.Cancel = true;
        Hide();
    }

    private void SetLed(
        Ellipse led,
        StatusLedAppearance appearance,
        string tooltip,
        string? title = null) =>
        SetLed(led, appearance.Color, tooltip, appearance.Glow, title);

    private void SetLed(
        Ellipse led,
        string color,
        string tooltip,
        bool glow = false,
        string? title = null) =>
        SetLed(
            led,
            (Color)ColorConverter.ConvertFromString(color),
            tooltip,
            glow,
            title);

    private void SetLed(
        Ellipse led,
        Color color,
        string tooltip,
        bool glow,
        string? title)
    {

        led.Fill = new SolidColorBrush(color);
        if (led == ActivityLed)
        {
            var version = ++_softwareActivityVersion;
            if (color == (Color)ColorConverter.ConvertFromString("#74D9A0"))
                _ = ClearSoftwareActivityAsync(version);
            else if (color == ErrorStatusLed.Color || color == (Color)ColorConverter.ConvertFromString("#FFD66E"))
                _ = ClearSoftwareActivityAsync(version, delayMilliseconds: 5000);
        }
        led.Effect = glow
            ? new DropShadowEffect
            {
                Color = color,
                BlurRadius = StatusLedGlowBlurRadius,
                ShadowDepth = 0,
                Opacity = StatusLedGlowOpacity,
            }
            : null;
        var helpTitle = !string.IsNullOrWhiteSpace(title)
            ? title
            : led == RuntimeLed
                ? "Chat"
                : led == DriverLed
                    ? "Codex IPC"
                    : "最近事件";
        SetHelp(led, helpTitle, tooltip);
    }

    private void SetHelp(
        FrameworkElement element,
        string title,
        string detail)
    {
        _helpContent[element] = (title, detail);
        ApplyHelp(element, title, detail);
    }

    private void ApplyHelp(
        FrameworkElement element,
        string title,
        string detail,
        FrameworkElement? detailContent = null)
    {
        var localizedTitle = Localize(title);
        var localizedDetail = Localize(detail);
        var content = new StackPanel();
        content.Children.Add(new TextBlock
        {
            Text = localizedTitle,
            Style = (Style)FindResource("MicroHelpTitle"),
        });
        detailContent ??= new TextBlock
        {
            Text = localizedDetail,
            Style = (Style)FindResource("MicroHelpDetail"),
        };
        content.Children.Add(detailContent);

        var helpStyle = (Style)FindResource(typeof(ToolTip));
        if (element.ToolTip is ToolTip existing && ReferenceEquals(existing.Style, helpStyle))
        {
            // Refresh the content without reopening the popup or replaying its entrance.
            existing.Content = content;
        }
        else
        {
            element.ToolTip = new ToolTip
            {
                Content = content,
                Style = helpStyle,
                IsHitTestVisible = false,
            };
        }
        ToolTipService.SetInitialShowDelay(element, 320);
        ToolTipService.SetBetweenShowDelay(element, 100);
        ToolTipService.SetShowDuration(element, 16000);
        AutomationProperties.SetName(element, localizedTitle);
        AutomationProperties.SetHelpText(element, localizedDetail);
    }

    private string Localize(string value) => _localization.Text(value);

    private static string LocalizeDriverError(Exception exception) =>
        LocalizeDriverError(exception.Message);

    private static string LocalizeDriverError(string message) =>
        message.Contains("device interface is not present", StringComparison.OrdinalIgnoreCase)
            ? "Codex Micro 虚拟 HID 尚未出现。"
            : $"虚拟 HID 连接失败：{message}";

    private static T? FindAncestor<T>(DependencyObject? current)
        where T : DependencyObject
    {
        while (current is not null)
        {
            if (current is T match)
            {
                return match;
            }

            current = VisualTreeHelper.GetParent(current);
        }

        return null;
    }
}
