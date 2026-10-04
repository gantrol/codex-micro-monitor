using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;

namespace CodexMicro.Desktop.Controls;

public static class MicroToolTipMotion
{
    public static readonly DependencyProperty IsEnabledProperty = DependencyProperty.RegisterAttached(
        "IsEnabled", typeof(bool), typeof(MicroToolTipMotion),
        new PropertyMetadata(false, OnIsEnabledChanged));

    public static bool GetIsEnabled(DependencyObject element) =>
        (bool)element.GetValue(IsEnabledProperty);

    public static void SetIsEnabled(DependencyObject element, bool value) =>
        element.SetValue(IsEnabledProperty, value);

    private static void OnIsEnabledChanged(DependencyObject sender, DependencyPropertyChangedEventArgs args)
    {
        if (sender is not ToolTip tooltip)
        {
            return;
        }

        tooltip.Opened -= OnOpened;
        tooltip.Closed -= OnClosed;
        Reset(tooltip);
        if ((bool)args.NewValue)
        {
            tooltip.Opened += OnOpened;
            tooltip.Closed += OnClosed;
        }
    }

    private static void OnOpened(object sender, RoutedEventArgs args)
    {
        var tooltip = (ToolTip)sender;
        tooltip.ApplyTemplate();
        Reset(tooltip);
        if (!SystemParameters.ClientAreaAnimation || !SystemParameters.ToolTipAnimation ||
            SystemParameters.HighContrast ||
            Part(tooltip, "CrystalRoot") is not { } root ||
            Part(tooltip, "CrystalSurface") is not { } surface ||
            Part(tooltip, "CrystalContent") is not { } content)
        {
            return;
        }

        // Animate the shell independently so text never stretches during expansion.
        var rise = new TranslateTransform();
        var expansion = new ScaleTransform();
        var contentRise = new TranslateTransform();
        root.RenderTransform = rise;
        surface.RenderTransform = expansion;
        content.RenderTransform = contentRise;
        rise.BeginAnimation(TranslateTransform.YProperty, Motion(6, 0, 180));
        expansion.BeginAnimation(ScaleTransform.ScaleXProperty, Motion(0.97, 1, 180));
        expansion.BeginAnimation(ScaleTransform.ScaleYProperty, Motion(0.84, 1, 180));
        root.BeginAnimation(UIElement.OpacityProperty, Motion(0, 1, 100));
        contentRise.BeginAnimation(TranslateTransform.YProperty, Motion(4, 0, 180));
        content.BeginAnimation(UIElement.OpacityProperty, new DoubleAnimationUsingKeyFrames
        {
            FillBehavior = FillBehavior.Stop,
            KeyFrames =
            {
                new DiscreteDoubleKeyFrame(0, KeyTime.FromTimeSpan(TimeSpan.Zero)),
                new DiscreteDoubleKeyFrame(0, KeyTime.FromTimeSpan(TimeSpan.FromMilliseconds(30))),
                new EasingDoubleKeyFrame(1, KeyTime.FromTimeSpan(TimeSpan.FromMilliseconds(160)))
                {
                    EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut },
                },
            },
        });
    }

    private static DoubleAnimation Motion(double from, double to, double milliseconds) =>
        new(from, to, TimeSpan.FromMilliseconds(milliseconds))
        {
            EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut },
            FillBehavior = FillBehavior.Stop,
        };

    private static void OnClosed(object sender, RoutedEventArgs args) => Reset((ToolTip)sender);

    private static FrameworkElement? Part(ToolTip tooltip, string name) =>
        tooltip.Template?.FindName(name, tooltip) as FrameworkElement;

    private static void Reset(ToolTip tooltip)
    {
        foreach (var name in new[] { "CrystalRoot", "CrystalSurface", "CrystalContent" })
        {
            if (Part(tooltip, name) is not { } part)
            {
                continue;
            }

            part.BeginAnimation(UIElement.OpacityProperty, null);
            if (part.RenderTransform is TranslateTransform translation)
            {
                translation.BeginAnimation(TranslateTransform.YProperty, null);
            }
            else if (part.RenderTransform is ScaleTransform scale)
            {
                scale.BeginAnimation(ScaleTransform.ScaleXProperty, null);
                scale.BeginAnimation(ScaleTransform.ScaleYProperty, null);
            }

            part.RenderTransform = Transform.Identity;
        }
    }
}
