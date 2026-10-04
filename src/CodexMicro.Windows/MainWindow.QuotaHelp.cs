using System.Globalization;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using CodexMicro.Desktop.Services;

namespace CodexMicro.Desktop;

public partial class MicroSurfaceWindow
{
    private (FrameworkElement Content, string Detail) BuildQuotaHelpDetail(CodexQuotaSnapshot snapshot)
    {
        var content = new StackPanel { MinWidth = 280, Margin = new Thickness(0, 10, 0, 0) };
        var help = new List<string>();
        var culture = CultureInfo.GetCultureInfo(
            MicroLocalization.ToSettingValue(_localization.EffectiveLanguage));

        string Format(string format, params object[] values) =>
            string.Format(culture, Localize(format), values);

        string Date(DateTimeOffset value) =>
            value.ToLocalTime().ToString(Localize("M月d日 HH:mm"), culture);

        TextBlock Text(string text, string style = "MicroHelpBody") => new()
        {
            Text = text,
            Style = (Style)FindResource(style),
        };

        Grid Row(TextBlock label, TextBlock value)
        {
            var row = new Grid();
            row.ColumnDefinitions.Add(new ColumnDefinition());
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            label.Margin = new Thickness(0, 0, 12, 0);
            label.VerticalAlignment = VerticalAlignment.Center;
            value.VerticalAlignment = VerticalAlignment.Center;
            value.TextAlignment = TextAlignment.Right;
            value.MaxWidth = 180;
            Grid.SetColumn(value, 1);
            row.Children.Add(label);
            row.Children.Add(value);
            return row;
        }

        void Divider() => content.Children.Add(new Border { Style = (Style)FindResource("MicroHelpDivider") });

        foreach (var window in snapshot.Windows.OrderBy(window => window.WindowDurationMinutes))
        {
            var section = new StackPanel();
            var label = FormatQuotaWindowLabel(window.WindowDurationMinutes, culture);
            var remaining = Math.Round(window.RemainingPercent, MidpointRounding.AwayFromZero);
            var remainingText = Format("剩余 {0}%", remaining);
            var value = Text(remaining.ToString("0", culture) + "%", "MicroHelpMetric");
            AutomationProperties.SetName(value, remainingText);
            section.Children.Add(Row(Text(label, "MicroHelpSection"), value));
            var progress = new ProgressBar
            {
                Value = window.RemainingPercent,
                Style = (Style)FindResource("MicroHelpProgress"),
                Focusable = false,
                IsHitTestVisible = false,
            };
            AutomationProperties.SetName(progress, label);
            section.Children.Add(progress);
            var resetTime = Format("重置于 {0}", Date(window.ResetsAt));
            section.Children.Add(Text(resetTime, "MicroHelpCaption"));
            if (content.Children.Count > 0)
            {
                section.Margin = new Thickness(0, 12, 0, 0);
            }

            content.Children.Add(section);
            help.Add($"{label} · {remainingText}\n{resetTime}");
        }

        Divider();
        if (snapshot.AvailableResets is { } resets)
        {
            content.Children.Add(Row(
                Text(Localize("额度重置"), "MicroHelpSection"),
                Text(Format("可用 {0} 次", resets.Count), "MicroHelpCaption")));
            help.Add(Format("额度重置 · 可用 {0} 次", resets.Count));
            foreach (var credit in resets)
            {
                var title = credit.Title.Equals("Full reset", StringComparison.OrdinalIgnoreCase)
                    ? Localize("全额重置")
                    : credit.Title;
                var expiration = Format("{0} 到期", Date(credit.ExpiresAt));
                var row = Row(Text(title), Text(expiration, "MicroHelpCaption"));
                row.Margin = new Thickness(0, 6, 0, 0);
                content.Children.Add(row);
                help.Add(Format("{0} · {1} 到期", title, Date(credit.ExpiresAt)));
            }
        }
        else
        {
            var unavailable = Localize("额度重置：暂不可用");
            content.Children.Add(Text(unavailable));
            help.Add(unavailable);
        }

        var updated = Format("更新于 {0}", snapshot.ReadAt.ToLocalTime().ToString("t", culture));
        var timestamp = Text(updated, "MicroHelpCaption");
        timestamp.Margin = new Thickness(0, 10, 0, 0);
        content.Children.Add(timestamp);
        help.Add(updated);
        if (_quotaRefreshFailed)
        {
            var failure = Localize("刷新失败 · 显示上次额度");
            content.Children.Add(Text(failure, "MicroHelpSection"));
            help.Add(failure);
        }

        Divider();
        var modelPair = FormatQuickModelPair(_profileSettings.Current);
        foreach (var (gesture, action) in new[]
        {
            (Localize("短按"), Format("{0}（下一轮）", modelPair)),
            (Localize("长按"), Localize("Micro 设置")),
            (Localize("右键"), Localize("当前 Agent 软件设置")),
        })
        {
            var row = Row(Text(gesture, "MicroHelpCaption"), Text(action, "MicroHelpCaption"));
            row.Margin = new Thickness(0, 2, 0, 0);
            content.Children.Add(row);
        }

        help.Add(Format("短按切换 {0}（下一轮）", modelPair));
        help.Add(Localize("长按 · Micro 设置"));
        help.Add(Localize("右键 · 当前 Agent 软件设置"));
        return (content, string.Join('\n', help));
    }

    private string FormatQuotaWindowLabel(int durationMinutes, CultureInfo culture)
    {
        const int minutesPerWeek = 7 * 24 * 60;
        const int minutesPerDay = 24 * 60;

        if (durationMinutes == minutesPerWeek)
        {
            return Localize("周额度");
        }

        var (format, duration) = durationMinutes switch
        {
            _ when durationMinutes % minutesPerWeek == 0 => ("{0} 周额度", durationMinutes / minutesPerWeek),
            _ when durationMinutes % minutesPerDay == 0 => ("{0} 天额度", durationMinutes / minutesPerDay),
            _ when durationMinutes % 60 == 0 => ("{0} 小时额度", durationMinutes / 60),
            _ => ("{0} 分钟额度", durationMinutes),
        };
        return string.Format(culture, Localize(format), duration);
    }
}
