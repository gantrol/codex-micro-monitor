using System.Globalization;

namespace CodexMicro.Desktop.Controls;

internal static class CreditBalanceFormatter
{
    internal static string Full(decimal balance, CultureInfo culture) =>
        balance.ToString("#,0.############################", culture);

    internal static string Compact(decimal balance, CultureInfo culture)
    {
        if (balance is > 0 and < 0.01m)
        {
            return "<" + 0.01m.ToString("0.00", culture);
        }

        // Truncate compact amounts so a nearly depleted balance never rounds
        // up to a larger spendable amount or down to an apparent zero.
        var (divisor, suffix) = balance switch
        {
            >= 1_000_000_000_000m => (1_000_000_000_000m, "T"),
            >= 1_000_000_000m => (1_000_000_000m, "B"),
            >= 1_000_000m => (1_000_000m, "M"),
            >= 1_000m => (1_000m, "k"),
            _ => (1m, ""),
        };
        if (balance >= 1_000_000_000_000_000m)
        {
            return "≈" + balance.ToString("0.#E+0", culture);
        }

        var precision = balance < 100m ? 100m : 10m;
        var compact = decimal.Truncate(balance / divisor * precision) / precision;
        return compact.ToString("0.##", culture) + suffix;
    }
}
