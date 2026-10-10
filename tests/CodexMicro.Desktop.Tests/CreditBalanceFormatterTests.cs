using System.Globalization;
using CodexMicro.Desktop.Controls;
using Xunit;

namespace CodexMicro.Desktop.Tests;

public sealed class CreditBalanceFormatterTests
{
    [Theory]
    [InlineData("0", "0")]
    [InlineData("0.000000001", "<0.01")]
    [InlineData("0.0099", "<0.01")]
    [InlineData("0.01", "0.01")]
    [InlineData("99.999", "99.99")]
    [InlineData("999.999", "999.9")]
    [InlineData("1000", "1k")]
    [InlineData("12345.6789", "12.3k")]
    [InlineData("999999.99", "999.9k")]
    [InlineData("1000000", "1M")]
    [InlineData("1234567890", "1.2B")]
    [InlineData("1234567890000", "1.2T")]
    [InlineData("79228162514264337593543950335", "≈7.9E+28")]
    public void CompactAmountsHandleTinyBalancesAndLargeValuesWithoutAssumingAMaximum(string amount, string expected)
    {
        Assert.Equal(expected, CreditBalanceFormatter.Compact(
            decimal.Parse(amount, CultureInfo.InvariantCulture), CultureInfo.GetCultureInfo("en-US")));
    }

    [Theory]
    [InlineData("en-US", "12.34", "12,345.6789012345", "<0.01")]
    [InlineData("zh-CN", "12.34", "12,345.6789012345", "<0.01")]
    [InlineData("de-DE", "12,34", "12.345,6789012345", "<0,01")]
    public void DisplayUsesTheProvidedCultureAndDetailsKeepFullPrecision(
        string language, string compact, string full, string tiny)
    {
        var culture = CultureInfo.GetCultureInfo(language);
        Assert.Equal(compact, CreditBalanceFormatter.Compact(12.345m, culture));
        Assert.Equal(full, CreditBalanceFormatter.Full(12345.6789012345m, culture));
        Assert.Equal(tiny, CreditBalanceFormatter.Compact(0.000001m, culture));
    }
}
