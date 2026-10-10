using System.Globalization;
using System.Runtime.ExceptionServices;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using CodexMicro.Desktop.Controls;
using CodexMicro.Desktop.Services;
using Xunit;

namespace CodexMicro.Desktop.Tests;

[Collection(WpfUiCollection.Name)]
public sealed class QuotaCreditDisplayTests
{
    [Theory]
    [InlineData(0, 80, true, true, true)]
    [InlineData(80, 0, true, true, true)]
    [InlineData(0, 0, true, true, true)]
    [InlineData(0.4, 0.1, true, true, false)]
    [InlineData(80, 90, true, true, false)]
    [InlineData(0, 90, false, true, false)]
    [InlineData(90, 0, true, false, false)]
    [InlineData(0, 0, false, false, false)]
    [InlineData(double.NaN, double.NaN, true, true, false)]
    public void OnlyAnExhaustedApplicableWindowReplacesPercentages(
        double fiveHour, double weekly, bool hasFiveHour, bool hasWeekly, bool expected)
    {
        RunSta(() =>
        {
            var knob = new QuotaKnob
            {
                HasFiveHourWindow = hasFiveHour,
                HasWeeklyWindow = hasWeekly,
                FiveHourRemaining = fiveHour,
                WeeklyRemaining = weekly,
                CreditBalance = 12345.6789m,
            };

            Assert.Equal(expected, CreditReadout(knob).Visibility == Visibility.Visible);
            if (expected)
            {
                Assert.Equal("12.3k", CreditValue(knob).Text);
                Assert.Contains("12,345.6789 Credits", AutomationProperties.GetName(knob));
            }
            else
            {
                Assert.DoesNotContain("Credits", AutomationProperties.GetName(knob));
            }
        });
    }

    [Fact]
    public void MissingQuotaOrMissingBalanceNeverBecomesZeroCredits()
    {
        RunSta(() =>
        {
            var knob = new QuotaKnob { CreditBalance = 25m };
            Assert.Equal(Visibility.Collapsed, CreditReadout(knob).Visibility);

            knob.WeeklyRemaining = 0;
            knob.CreditBalance = null;
            Assert.Equal(Visibility.Collapsed, CreditReadout(knob).Visibility);
            Assert.Contains("0%", AutomationProperties.GetName(knob));

            knob.CreditBalance = -1;
            Assert.Equal(Visibility.Collapsed, CreditReadout(knob).Visibility);
        });
    }

    [Fact]
    public void ZeroAndUnlimitedCreditsAreDistinctAndUnlimitedTakesPrecedence()
    {
        RunSta(() =>
        {
            var knob = new QuotaKnob { WeeklyRemaining = 0, CreditBalance = 0 };
            Assert.Equal(Visibility.Visible, CreditReadout(knob).Visibility);
            Assert.Equal("0", CreditValue(knob).Text);
            var depletedColor = Assert.IsType<SolidColorBrush>(CreditValue(knob).Foreground).Color;

            knob.HasUnlimitedCredits = true;
            Assert.Equal("∞", CreditValue(knob).Text);
            Assert.Contains("∞ Credits", AutomationProperties.GetName(knob));
            Assert.NotEqual(depletedColor, Assert.IsType<SolidColorBrush>(CreditValue(knob).Foreground).Color);

            knob.CreditBalance = null;
            Assert.Equal("∞", CreditValue(knob).Text);
            knob.HasUnlimitedCredits = false;
            Assert.Equal(Visibility.Collapsed, CreditReadout(knob).Visibility);
        });
    }

    [Fact]
    public void CreditsKeepQuotaRingsAndYieldToModelAndKeyboardPreview()
    {
        RunSta(() =>
        {
            var knob = new QuotaKnob
            {
                FiveHourRemaining = 0,
                WeeklyRemaining = 65,
                ModelId = "gpt-5.6-sol",
                ReasoningEffort = "high",
            };
            string[] Rings() => Gauge(knob).Children.OfType<System.Windows.Shapes.Path>()
                .Select(path => path.Data.ToString(CultureInfo.InvariantCulture)).ToArray();
            var quotaRings = Rings();

            knob.CreditBalance = 120;
            Assert.Equal(quotaRings, Rings());
            Assert.Equal(Visibility.Visible, CreditReadout(knob).Visibility);

            knob.DisplayMode = QuotaKnobDisplayMode.Model;
            Assert.Equal(Visibility.Collapsed, CreditReadout(knob).Visibility);
            Assert.Contains("5.6 Sol", AutomationProperties.GetName(knob));
            knob.DisplayMode = QuotaKnobDisplayMode.Auto;
            Assert.Equal(Visibility.Visible, CreditReadout(knob).Visibility);
            Assert.Equal(quotaRings, Rings());

            knob.RaiseEvent(new KeyboardFocusChangedEventArgs(Keyboard.PrimaryDevice, 0, null, knob)
                { RoutedEvent = Keyboard.GotKeyboardFocusEvent });
            Assert.Equal(Visibility.Collapsed, CreditReadout(knob).Visibility);
            knob.RaiseEvent(new KeyboardFocusChangedEventArgs(Keyboard.PrimaryDevice, 0, knob, null)
                { RoutedEvent = Keyboard.LostKeyboardFocusEvent });
            Assert.Equal(Visibility.Visible, CreditReadout(knob).Visibility);

            knob.UseQuotaReadout = false;
            knob.CreditBalance = 80;
            knob.UseQuotaReadout = true;
            Assert.Equal("80", CreditValue(knob).Text);

            knob.FiveHourRemaining = 100;
            Assert.Equal(Visibility.Collapsed, CreditReadout(knob).Visibility);
            Assert.Contains("100%", AutomationProperties.GetName(knob));
        });
    }

    [Fact]
    public void ReadoutCultureChangesRefreshVisibleAndAccessibleAmounts()
    {
        RunSta(() =>
        {
            var knob = new QuotaKnob { WeeklyRemaining = 0, CreditBalance = 12345.6789m };
            knob.ReadoutCulture = CultureInfo.GetCultureInfo("de-DE");
            Assert.Equal("12,3k", CreditValue(knob).Text);
            Assert.Contains("12.345,6789 Credits", AutomationProperties.GetName(knob));
        });
    }

    [Fact]
    public void ParsedBalanceSurvivesFailedRefreshAndClearsOnSuccessfulMissingData()
    {
        RunSta(() =>
        {
            var localization = new MicroLocalization(MicroLanguage.EnUs);
            var window = new MicroSurfaceWindow(localization, MicroProfileSettings.CreateTransient());
            try
            {
                window.ApplyQuotaSnapshot(null, refreshFailed: true);
                Assert.Null(window.SettingsKey.CreditBalance);
                Assert.DoesNotContain("0 Credits", AutomationProperties.GetName(window.SettingsKey));

                window.ApplyQuotaSnapshot(ParseSnapshot(100, """{"hasCredits":true,"unlimited":false,"balance":"12345.6789"}"""));
                Assert.Equal("12.3k", CreditValue(window.SettingsKey).Text);
                Assert.Equal(Visibility.Visible, CreditReadout(window.SettingsKey).Visibility);
                Assert.Contains("Credit balance · 12,345.6789", AutomationProperties.GetHelpText(window.SettingsKey));

                window.ApplyQuotaSnapshot(null, refreshFailed: true);
                Assert.Equal(12345.6789m, window.SettingsKey.CreditBalance);
                Assert.Equal(Visibility.Visible, CreditReadout(window.SettingsKey).Visibility);
                Assert.NotEmpty(AutomationProperties.GetItemStatus(window.SettingsKey));
                Assert.Contains("last", AutomationProperties.GetHelpText(window.SettingsKey), StringComparison.OrdinalIgnoreCase);

                window.ApplyQuotaSnapshot(ParseSnapshot(100, "null"));
                Assert.Null(window.SettingsKey.CreditBalance);
                Assert.Equal(Visibility.Collapsed, CreditReadout(window.SettingsKey).Visibility);
                Assert.Empty(AutomationProperties.GetItemStatus(window.SettingsKey));
                Assert.Contains("Balance unavailable", AutomationProperties.GetHelpText(window.SettingsKey));

                window.ApplyQuotaSnapshot(ParseSnapshot(100, """{"hasCredits":false,"unlimited":true}"""));
                Assert.Equal("∞", CreditValue(window.SettingsKey).Text);
                Assert.Contains("Unlimited", AutomationProperties.GetHelpText(window.SettingsKey));
                localization.SetLanguage(MicroLanguage.ZhCn);
                Assert.Contains("Credits 余额 · 无限", AutomationProperties.GetHelpText(window.SettingsKey));

                window.ApplyQuotaSnapshot(ParseSnapshot(1, """{"hasCredits":true,"unlimited":false,"balance":"12345"}"""));
                Assert.False(window.SettingsKey.HasUnlimitedCredits);
                Assert.Equal(Visibility.Collapsed, CreditReadout(window.SettingsKey).Visibility);
                Assert.Contains("99%", AutomationProperties.GetName(window.SettingsKey));
                Assert.Contains("12,345", AutomationProperties.GetHelpText(window.SettingsKey));
            }
            finally
            {
                window.CloseForApplicationExit();
            }
        });
    }

    [Fact]
    public void ProIgnoresTheHiddenFiveHourWindowWhenSelectingTheReadout()
    {
        RunSta(() =>
        {
            var window = new MicroSurfaceWindow(new MicroLocalization(MicroLanguage.EnUs),
                MicroProfileSettings.CreateTransient());
            try
            {
                window.ApplyQuotaSnapshot(new CodexQuotaSnapshot(
                    new(100, 300, DateTimeOffset.UtcNow.AddHours(1)),
                    new(1, 10080, DateTimeOffset.UtcNow.AddDays(1)), "pro", DateTimeOffset.UtcNow)
                {
                    Credits = new(true, false, 25),
                });
                Assert.False(window.SettingsKey.HasFiveHourWindow);
                Assert.Equal(Visibility.Collapsed, CreditReadout(window.SettingsKey).Visibility);
                Assert.Contains("99%", AutomationProperties.GetName(window.SettingsKey));
            }
            finally
            {
                window.CloseForApplicationExit();
            }
        });
    }

    private static CodexQuotaSnapshot ParseSnapshot(int usedPercent, string credits) =>
        Assert.IsType<CodexQuotaSnapshot>(CodexQuotaService.Parse($$"""
            {"result":{"rateLimits":{"planType":"pro",
              "primary":{"usedPercent":{{usedPercent}},"windowDurationMins":10080,"resetsAt":1792233751},
              "credits":{{credits}}
            } } }
            """));

    private static Grid Gauge(QuotaKnob knob) =>
        Assert.IsType<Grid>(Assert.IsType<Viewbox>(knob.Content).Child);

    private static Viewbox CreditReadout(QuotaKnob knob) => Assert.Single(Gauge(knob).Children.OfType<Viewbox>(),
        viewbox => viewbox.Child is StackPanel panel && panel.Children.OfType<TextBlock>().Any(text => text.Text == "Credits"));

    private static TextBlock CreditValue(QuotaKnob knob) =>
        Assert.IsType<TextBlock>(Assert.IsType<StackPanel>(CreditReadout(knob).Child).Children[0]);

    private static void RunSta(Action action)
    {
        Exception? failure = null;
        var thread = new Thread(() =>
        {
            try { action(); }
            catch (Exception exception) { failure = exception; }
        }) { IsBackground = true };
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        Assert.True(thread.Join(TimeSpan.FromSeconds(30)), "Quota component test timed out.");
        if (failure is not null) ExceptionDispatchInfo.Capture(failure).Throw();
    }
}
