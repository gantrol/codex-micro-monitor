using System.ComponentModel;
using System.IO;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using CodexMicro.Desktop.Services;

namespace CodexMicro.Desktop;

public partial class MicroSettingsWindow : Window
{
    private sealed record ModelChoice(
        CodexQuickModel Model,
        string DisplayName)
    {
        public override string ToString() => DisplayName;
    }

    private sealed record SettingChoice(
        string Id,
        string DisplayName)
    {
        public override string ToString() => DisplayName;
    }

    private readonly MicroLocalization _localization;
    private readonly MicroProfileSettings _profileSettings;
    private readonly CodexMicroLayoutObserver _layoutObserver;
    private readonly CodexMicroConfigWriter _configWriter;
    private readonly MicroHarnessRegistry _harnessRegistry;
    private readonly bool _coreOnly;
    private readonly Func<Task>? _openOfficialSettings;
    private readonly Func<Task>? _reconnect;
    private readonly Func<bool> _isConnected;
    private readonly Func<Task>? _codexConfigChanged;
    private bool _lastConfigSaveSucceeded = true;
    private readonly CancellationTokenSource _catalogRefreshCancellation = new();
    // Ignore XAML control events until the saved profile has been applied.
    private bool _syncing = true;

    internal MicroSettingsWindow(
        MicroLocalization localization,
        MicroProfileSettings profileSettings,
        Visual previewVisual,
        CodexMicroLayoutObserver? layoutObserver = null,
        CodexMicroConfigWriter? configWriter = null,
        MicroHarnessRegistry? harnessRegistry = null,
        Func<Task>? openOfficialSettings = null,
        Func<Task>? reconnect = null,
        Func<bool>? isConnected = null,
        Func<Task>? codexConfigChanged = null,
        bool coreOnly = false)
    {
        _coreOnly = coreOnly;
        _localization = localization ??
            throw new ArgumentNullException(nameof(localization));
        _profileSettings = profileSettings ??
            throw new ArgumentNullException(nameof(profileSettings));
        ArgumentNullException.ThrowIfNull(previewVisual);
        _layoutObserver = layoutObserver ?? new CodexMicroLayoutObserver();
        _configWriter = configWriter ??
            new CodexMicroConfigWriter(_layoutObserver.ConfigPath);
        _harnessRegistry = harnessRegistry ?? new MicroHarnessRegistry();
        _openOfficialSettings = openOfficialSettings;
        _reconnect = reconnect;
        _isConnected = isConnected ?? (() => false);
        _codexConfigChanged = codexConfigChanged;

        InitializeComponent();
        RefreshSettingsPalette();
        SystemParameters.StaticPropertyChanged += SystemParameters_Changed;
        Loaded += (_, _) => MicroWindowLayout.FitDialog(this);
        LiveMicroPreviewBrush.Visual = previewVisual;
        _localization.LanguageChanged += Localization_LanguageChanged;
        _profileSettings.Changed += ProfileSettings_Changed;
        _layoutObserver.LayoutChanged += LayoutObserver_LayoutChanged;
        _harnessRegistry.Changed += HarnessRegistry_Changed;
        Closed += Window_Closed;
        Closed += (_, _) => _catalogRefreshCancellation.Cancel();
        Loaded += RefreshModelsOnLoaded;
        RefreshPresentation();
    }

    private async void RefreshModelsOnLoaded(object sender, RoutedEventArgs e)
    {
        Loaded -= RefreshModelsOnLoaded;
        try
        {
            await _profileSettings.RefreshModelsAsync(_catalogRefreshCancellation.Token);
        }
        catch (OperationCanceledException)
        {
        }
    }

    private void RefreshPresentation()
    {
        var english = _localization.IsEnglish;
        var profile = _profileSettings.Current;
        var layout = _layoutObserver.Current;
        var harness = _harnessRegistry.Resolve(profile.ActiveHarnessId);


        _syncing = true;
        try
        {
            KeypadSizeSlider.Value = profile.WindowScale * 100;
            KeypadSizeValue.Text = $"{profile.WindowScale:P0}";
            var models = _profileSettings.GetModels()
                .Select(model => new ModelChoice(CodexQuickModel.FromId(model.Id), model.Label))
                .ToArray();
            QuickModelACombo.ItemsSource = models;
            QuickModelBCombo.ItemsSource = models;
            QuickModelACombo.SelectedItem = models.First(choice =>
                choice.Model == profile.QuickModelA);
            QuickModelBCombo.SelectedItem = models.First(choice =>
                choice.Model == profile.QuickModelB);

            SetChoices(
                QuickModelAEffortCombo,
                CreateReasoningEffortChoices(
                    profile.QuickModelA,
                    english,
                    profile.QuickModelAEffort),
                profile.QuickModelAEffort ?? "remember");
            SetChoices(
                QuickModelBEffortCombo,
                CreateReasoningEffortChoices(
                    profile.QuickModelB,
                    english,
                    profile.QuickModelBEffort),
                profile.QuickModelBEffort ?? "remember");

            SetChoices(
                AgentSourceCombo,
                [
                        new("recent", english ? "Most recent chats" : "最近任务"),
                        new("pinned", english ? "Pinned chats" : "已固定任务"),
                        new("priority", english ? "Priority order" : "优先级顺序"),
                        new("custom", english ? "Custom mapping" : "自定义映射"),
                    ],
                profile.AgentSource);
            SetChoices(
                KnobModeCombo,
                [
                        new("composer-navigation", english ? "Composer navigation" : "输入区导航"),
                        new("reasoning", english ? "Reasoning only" : "仅推理强度"),
                        new("conversation-scroll", english ? "Conversation scroll" : "对话滚动"),
                        new("custom", english ? "Custom" : "自定义"),
                    ],
                layout.EncoderMode);
            SetChoices(
                MicrophoneModeCombo,
                [
                        new("push-to-talk", english ? "Push to talk" : "按住说话"),
                        new(
                            "tap-to-toggle",
                            english ? "Tap to start / stop" : "点按开始 / 再点停止"),
                        new(
                            "realtime",
                            english ? "Codex realtime voice" : "Codex 实时语音"),
                    ],
                profile.TapToToggleVoice
                    ? "tap-to-toggle"
                    : layout.VoiceButtonMode);
            InvertDialDirectionToggle.IsChecked =
                profile.InvertDialDirection;
            AutoConfirmUltraToggle.IsChecked =
                profile.AutoConfirmUltraFullAccess;
            SingleTapToggle.IsChecked = profile.SingleTapAgentKeys;
        }
        finally
        {
            _syncing = false;
        }

        Title = english
                ? "Codex Micro · Software settings"
                : "Codex Micro · 软件设置";
        KeypadSizeTitle.Text = english ? "Size" : "大小";
        WindowTitleText.Text = english ? "Micro software settings" : "Micro 软件设置";
        LayoutHeadingText.Text = _localization.Text("布局");
        ResetButton.Content = english ? "Reset layout" : "重置布局";
        OptionsHeadingText.Text = _localization.Text("交互");
        AgentKeysTitleText.Text = _localization.Text("任务按键");
        KnobTitleText.Text = english ? "Knob" : "旋钮";
        InvertDialDirectionTitleText.Text = english
            ? "Reverse dial direction"
            : "反转旋钮方向";
        MicrophoneTitleText.Text = english ? "Microphone key" : "麦克风键";
        SingleTapTitleText.Text = english
            ? "Focus Codex with a single tap"
            : "单击聚焦 Codex";
        ExtensionsHeadingText.Text = _localization.Text("快捷模型");
        QuickModelATitleText.Text = english ? "Quick model A" : "快捷模型 A";
        QuickModelBTitleText.Text = english ? "Quick model B" : "快捷模型 B";
        AutoConfirmUltraTitleText.Text = english
            ? "Automatically choose Use Full access"
            : "自动选择 Use Full access";
        DiagnosticsHeadingText.Text = english ? "Connection" : "连接";
        OpenOfficialSettingsButton.Content = english
            ? "Official Micro settings"
            : "官方 Micro 设置";
        ReconnectButton.Content = english ? "Reconnect" : "重新连接";

        AutomationProperties.SetName(
            CloseButton,
            english ? "Close settings" : "关闭设置");
        AutomationProperties.SetName(
            AutoConfirmUltraToggle,
            AutoConfirmUltraTitleText.Text);
        AutomationProperties.SetName(ResetSizeButton, _localization.Text("恢复默认大小"));
        AutomationProperties.SetName(QuickModelAEffortCombo, _localization.Text("快捷模型 A 思考强度"));
        AutomationProperties.SetName(QuickModelBEffortCombo, _localization.Text("快捷模型 B 思考强度"));
        foreach (var button in PreviewKeyTargets.Children.OfType<Button>())
        {
            button.ToolTip = string.Format(_localization.Text("编辑按键 {0}"), button.Tag);
        }
        ApplyHarnessScope(harness);
        RefreshLayoutPresentation(layout);
        RefreshConnectionState();
        RefreshSaveState();
    }

    private void ApplyHarnessScope(MicroHarnessDefinition harness)
    {

        LayoutCard.IsEnabled = true;
        LayoutCard.Opacity = 1;

        KnobModeCombo.IsEnabled = true;
        AgentSourceCombo.IsEnabled = true;
        MicrophoneModeCombo.IsEnabled = true;
        InvertDialDirectionOptionRow.Visibility = Visibility.Visible;
        InvertDialDirectionSeparator.Visibility =
            InvertDialDirectionOptionRow.Visibility;
        InvertDialDirectionToggle.IsEnabled = true;
        SingleTapToggle.IsEnabled = true;
        QuickModelARow.Visibility = Visibility.Visible;
        QuickModelBRow.Visibility = QuickModelARow.Visibility;
        AutoConfirmUltraRow.Visibility = QuickModelARow.Visibility;
        AutoConfirmUltraSeparator.Visibility = QuickModelARow.Visibility;
        AutoConfirmUltraToggle.IsEnabled = true;
        OpenOfficialSettingsButton.Visibility = Visibility.Visible;
        ReconnectButton.Visibility = OpenOfficialSettingsButton.Visibility;
        {
            MicrophoneOptionRow.Visibility = Visibility.Collapsed;
            AutoConfirmUltraRow.Visibility = Visibility.Collapsed;
            AutoConfirmUltraSeparator.Visibility = Visibility.Collapsed;
            OpenOfficialSettingsButton.Visibility = Visibility.Collapsed;
        }
    }

    private static void SetChoices(
        ComboBox comboBox,
        IReadOnlyList<SettingChoice> choices,
        string selectedId)
    {
        comboBox.ItemsSource = choices;
        comboBox.SelectedItem = choices.FirstOrDefault(choice =>
            choice.Id == selectedId) ?? choices[0];
    }

    private IReadOnlyList<SettingChoice> CreateReasoningEffortChoices(
        CodexQuickModel model,
        bool english,
        string? savedEffort)
    {
        var choices = new List<SettingChoice>
        {
            new("remember", english ? "Remember" : "记忆上次"),
        };
        choices.AddRange(
            _profileSettings.GetSupportedReasoningEfforts(model)
                .Select(effort => new SettingChoice(
                    effort,
                    effort switch
                    {
                        "low" => "Low",
                        "medium" => "Medium",
                        "high" => "High",
                        "xhigh" => "XHigh",
                        "max" => "Max",
                        "ultra" => "Ultra",
                        _ => effort,
                    })));
        if (savedEffort is not null && !choices.Any(choice => choice.Id == savedEffort))
        {
            choices.Add(new(savedEffort, savedEffort));
        }

        return choices;
    }

    private void RefreshLayoutPresentation(CodexMicroLayoutSnapshot layout)
    {
        EditCombinedMicrophoneButton.Visibility = layout.SeparateMicrophoneKeys
            ? Visibility.Collapsed
            : Visibility.Visible;
        EditMicrophone1Button.Visibility = layout.SeparateMicrophoneKeys
            ? Visibility.Visible
            : Visibility.Collapsed;
        EditMicrophone2Button.Visibility = layout.SeparateMicrophoneKeys
            ? Visibility.Visible
            : Visibility.Collapsed;
    }

    internal void FocusHarnessOptions()
    {
        {
            FocusActiveAgentSettings();
            return;
        }
    }

    internal void FocusActiveAgentSettings()
    {
        Show();
        Activate();
        var harness = _harnessRegistry.Resolve(
            _profileSettings.Current.ActiveHarnessId);
        FrameworkElement target = QuickModelARow;
        target.BringIntoView();
        _ = Dispatcher.BeginInvoke(new Action(() =>
        {
            target.BringIntoView();
            ((IInputElement)QuickModelACombo).Focus();
        }));
    }

    internal void FocusHarnessSetup()
    {
        var harness = _harnessRegistry.Resolve(
            _profileSettings.Current.ActiveHarnessId);
        {
            FocusActiveAgentSettings();
            return;
        }
    }

    internal void FocusHarnessVoiceSettings()
    {
        return;
    }

    internal void RefreshConnectionState()
    {
        var harness = _harnessRegistry.Resolve(
            _profileSettings.Current.ActiveHarnessId);

        var connected = _isConnected();
        ConnectionStatusDot.SetResourceReference(
            System.Windows.Shapes.Shape.FillProperty,
            connected ? "SettingsSuccess" : "SettingsMuted");
        ConnectionStatusText.Text = _localization.Text(
            connected ? "Codex Plugin · 已连接" : "Codex Plugin · 未连接");
    }

    private void RefreshSaveState()
    {
        var saved = _profileSettings.LastSaveSucceeded &&
            _lastConfigSaveSucceeded &&
            _harnessRegistry.LastSaveSucceeded;
        SaveStatusText.Text = _localization.Text(saved
            ? "已保存"
            : "保存失败，改动仅本次有效");
        SaveStatusText.SetResourceReference(
            TextBlock.ForegroundProperty,
            saved ? "SettingsMuted" : "SettingsDanger");
    }

    private void QuickModelACombo_SelectionChanged(
        object sender,
        SelectionChangedEventArgs e)
    {
        if (!_syncing && QuickModelACombo.SelectedItem is ModelChoice choice)
        {
            _profileSettings.SetQuickModelA(choice.Model);
        }
    }

    private void QuickModelBCombo_SelectionChanged(
        object sender,
        SelectionChangedEventArgs e)
    {
        if (!_syncing && QuickModelBCombo.SelectedItem is ModelChoice choice)
        {
            _profileSettings.SetQuickModelB(choice.Model);
        }
    }

    private void QuickModelAEffortCombo_SelectionChanged(
        object sender,
        SelectionChangedEventArgs e)
    {
        if (!_syncing &&
            QuickModelAEffortCombo.SelectedItem is SettingChoice choice)
        {
            _profileSettings.SetQuickModelAEffort(
                choice.Id == "remember" ? null : choice.Id);
        }
    }

    private void QuickModelBEffortCombo_SelectionChanged(
        object sender,
        SelectionChangedEventArgs e)
    {
        if (!_syncing &&
            QuickModelBEffortCombo.SelectedItem is SettingChoice choice)
        {
            _profileSettings.SetQuickModelBEffort(
                choice.Id == "remember" ? null : choice.Id);
        }
    }

    private void AgentSourceCombo_SelectionChanged(
        object sender,
        SelectionChangedEventArgs e)
    {
        if (!_syncing && AgentSourceCombo.SelectedItem is SettingChoice choice)
        {
            _profileSettings.SetAgentSource(choice.Id);
        }
    }

    private void KnobModeCombo_SelectionChanged(
        object sender,
        SelectionChangedEventArgs e)
    {
        if (_syncing ||
            KnobModeCombo.SelectedItem is not SettingChoice choice)
        {
            return;
        }

        var harness = _harnessRegistry.Resolve(
            _profileSettings.Current.ActiveHarnessId);
        {
            SaveLayoutChange(() => _configWriter.SetEncoderMode(choice.Id));
        }
    }

    private void MicrophoneModeCombo_SelectionChanged(
        object sender,
        SelectionChangedEventArgs e)
    {
        if (_syncing ||
            MicrophoneModeCombo.SelectedItem is not SettingChoice choice)
        {
            return;
        }

        var tapToToggle = choice.Id == "tap-to-toggle";
        _profileSettings.SetTapToToggleVoice(tapToToggle);
        {
            SaveLayoutChange(() => _configWriter.SetVoiceButtonMode(
                tapToToggle ? "push-to-talk" : choice.Id));
        }
    }

    private void SingleTapToggle_Changed(object sender, RoutedEventArgs e)
    {
        if (!_syncing)
        {
            _profileSettings.SetSingleTapAgentKeys(
                SingleTapToggle.IsChecked == true);
        }
    }

    private void InvertDialDirectionToggle_Changed(
        object sender,
        RoutedEventArgs e)
    {
        if (!_syncing &&
            _harnessRegistry.Resolve(_profileSettings.Current.ActiveHarnessId).Id ==
                "codex")
        {
            _profileSettings.SetInvertDialDirection(
                InvertDialDirectionToggle.IsChecked == true);
        }
    }

    private void SaveLayoutChange(Func<bool> save)
    {
        _lastConfigSaveSucceeded = save();
        if (_lastConfigSaveSucceeded)
        {
            _layoutObserver.ReloadNow();
            _ = NotifyCodexConfigChangedAsync();
        }

        RefreshSaveState();
    }

    private async void PreviewSlotButton_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: string slotId })
        {
            return;
        }

        var harness = _harnessRegistry.Resolve(
            _profileSettings.Current.ActiveHarnessId);

        try
        {
            var editor = new KeycapEditorWindow(
                    slotId,
                    _layoutObserver.Current.GetSlot(slotId),
                    _localization,
                    _configWriter,
                    _layoutObserver,
                    softwareProfile: _profileSettings);
            editor.Owner = this;
            editor.Topmost = Topmost;
            if (editor.ShowDialog() == true)
            {
                await NotifyCodexConfigChangedAsync();
            }
        }
        catch (Exception exception) when (
            exception is InvalidOperationException or IOException)
        {
            SaveStatusText.Text = _localization.IsEnglish
                ? $"Could not open the {slotId} editor: {exception.Message}"
                : $"无法打开 {slotId} 编辑器：{exception.Message}";
            SaveStatusText.Foreground = new SolidColorBrush(
                Color.FromRgb(0xB0, 0x6B, 0x4F));
        }
    }

    private void AutoConfirmUltraToggle_Changed(
        object sender,
        RoutedEventArgs e)
    {
        if (!_syncing &&
            _harnessRegistry.Resolve(_profileSettings.Current.ActiveHarnessId).Id ==
                "codex")
        {
            _profileSettings.SetAutoConfirmUltraFullAccess(
                AutoConfirmUltraToggle.IsChecked == true);
        }
    }

    private async Task NotifyCodexConfigChangedAsync()
    {
        if (_codexConfigChanged is null)
        {
            return;
        }

        try
        {
            await _codexConfigChanged();
        }
        catch (Exception exception) when (
            exception is IOException or
                TimeoutException or
                InvalidDataException or
                InvalidOperationException or
                ObjectDisposedException)
        {
            SaveStatusText.Text = _localization.IsEnglish
                ? "Saved, but Codex has not reloaded the setting yet. " +
                    "Reconnect or restart Codex."
                : "设置已保存，但 Codex 尚未重新加载；请重新连接或重启 Codex。";
            SaveStatusText.Foreground = new SolidColorBrush(
                Color.FromRgb(0xB0, 0x6B, 0x4F));
        }
    }

    private void ResetButton_Click(object sender, RoutedEventArgs e)
    {
        var harness = _harnessRegistry.Resolve(
            _profileSettings.Current.ActiveHarnessId);
        {
            SaveLayoutChange(_configWriter.ResetLayout);
            if (_lastConfigSaveSucceeded) _profileSettings.ResetKeycapIcons();
        }
    }

    private async void OpenOfficialSettingsButton_Click(
        object sender,
        RoutedEventArgs e)
    {
        if (_openOfficialSettings is null)
        {
            return;
        }

        OpenOfficialSettingsButton.IsEnabled = false;
        try
        {
            await _openOfficialSettings();
        }
        finally
        {
            OpenOfficialSettingsButton.IsEnabled = true;
        }
    }

    private async void ReconnectButton_Click(object sender, RoutedEventArgs e)
    {
        if (_reconnect is null)
        {
            return;
        }

        ReconnectButton.IsEnabled = false;
        try
        {
            await _reconnect();
        }
        finally
        {
            ReconnectButton.IsEnabled = true;
            RefreshConnectionState();
        }
    }

    private void TitleBar_MouseLeftButtonDown(
        object sender,
        MouseButtonEventArgs e)
    {
        MicroWindowLayout.DragTitle(this, e);
    }

    private void KeypadSizeSlider_ValueChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (_syncing || KeypadSizeValue is null) return;
        KeypadSizeValue.Text = $"{e.NewValue / 100:P0}";
        _profileSettings.SetWindowScale(e.NewValue / 100);
    }

    private void ResetSizeButton_Click(object sender, RoutedEventArgs e) => _profileSettings.SetWindowScale(1);

    private void Window_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Escape)
        {
            e.Handled = true;
            Close();
        }
    }

    private void CloseButton_Click(object sender, RoutedEventArgs e) => Close();

    private void Localization_LanguageChanged(object? sender, EventArgs e) =>
        RunOnDispatcher(RefreshPresentation);

    private void ProfileSettings_Changed(object? sender, EventArgs e) =>
        RunOnDispatcher(RefreshPresentation);

    private void HarnessRegistry_Changed(object? sender, EventArgs e) =>
        RunOnDispatcher(RefreshPresentation);

    private void LayoutObserver_LayoutChanged(
        object? sender,
        CodexMicroLayoutSnapshot snapshot) =>
        RunOnDispatcher(RefreshPresentation);

    private void RunOnDispatcher(Action action)
    {
        if (Dispatcher.CheckAccess())
        {
            action();
        }
        else
        {
            _ = Dispatcher.BeginInvoke(action);
        }
    }

    private void SystemParameters_Changed(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(SystemParameters.HighContrast) or null or "")
        {
            RunOnDispatcher(RefreshSettingsPalette);
        }
    }

    private void RefreshSettingsPalette()
    {
        (string Key, Brush Brush)[] overrides =
        [
            ("SettingsSurface", SystemColors.WindowBrush),
            ("SettingsInk", SystemColors.WindowTextBrush),
            ("SettingsMuted", SystemColors.WindowTextBrush),
            ("SettingsLine", SystemColors.WindowTextBrush),
            ("SettingsStrongLine", SystemColors.WindowTextBrush),
            ("SettingsHover", SystemColors.ControlBrush),
            ("SettingsAccent", SystemColors.HighlightBrush),
            ("SettingsSelected", SystemColors.HighlightBrush),
            ("SettingsSelectedInk", SystemColors.HighlightTextBrush),
            ("SettingsOnAccent", SystemColors.HighlightTextBrush),
            ("SettingsSuccess", SystemColors.WindowTextBrush),
            ("SettingsDanger", SystemColors.WindowTextBrush),
        ];
        foreach (var (key, brush) in overrides)
        {
            if (SystemParameters.HighContrast)
            {
                Resources[key] = brush;
            }
            else
            {
                Resources.Remove(key);
            }
        }
    }

    private void Window_Closed(object? sender, EventArgs e)
    {
        LiveMicroPreviewBrush.Visual = null;
        _localization.LanguageChanged -= Localization_LanguageChanged;
        _profileSettings.Changed -= ProfileSettings_Changed;
        _layoutObserver.LayoutChanged -= LayoutObserver_LayoutChanged;
        _harnessRegistry.Changed -= HarnessRegistry_Changed;
        SystemParameters.StaticPropertyChanged -= SystemParameters_Changed;
        Closed -= Window_Closed;
    }
}
