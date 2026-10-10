using System.Globalization;
using CodexMicro.Desktop.Services;
using Xunit;

namespace CodexMicro.Desktop.Tests;

public sealed class CodexQuotaServiceTests
{
    [Fact]
    public void ParsesQuotaWindowsAndChoosesTheTighterRemainingLimit()
    {
        const string response =
            """
            {
              "id": 2,
              "result": {
                "rateLimits": {
                  "limitId": "codex",
                  "primary": {
                    "usedPercent": 35.4,
                    "windowDurationMins": 300,
                    "resetsAt": 1786572000
                  },
                  "secondary": {
                    "usedPercent": 82,
                    "windowDurationMins": 10080,
                    "resetsAt": 1787176800
                  },
                  "planType": "pro"
                }
              }
            }
            """;
        var readAt = new DateTimeOffset(
            2026,
            8,
            12,
            20,
            0,
            0,
            TimeSpan.Zero);

        var snapshot = Assert.IsType<CodexQuotaSnapshot>(
            CodexQuotaService.Parse(response, readAt));

        Assert.Equal("pro", snapshot.PlanType);
        Assert.Equal(readAt, snapshot.ReadAt);
        Assert.Equal(2, snapshot.Windows.Count);
        Assert.Equal(64.6, snapshot.Primary.RemainingPercent, 3);
        Assert.NotNull(snapshot.Secondary);
        Assert.Equal(18, snapshot.Secondary.RemainingPercent, 3);
        Assert.Same(snapshot.Secondary, snapshot.DisplayWindow);
    }

    [Fact]
    public void FallsBackToTheCodexMultiBucketView()
    {
        const string response =
            """
            {
              "id": 2,
              "result": {
                "rateLimitsByLimitId": {
                  "codex": {
                    "primary": {
                      "usedPercent": 1,
                      "windowDurationMins": 10080,
                      "resetsAt": 1787196677
                    },
                    "secondary": null
                  },
                  "codex_other": {
                    "primary": {
                      "usedPercent": 99,
                      "windowDurationMins": 60,
                      "resetsAt": 1787190000
                    }
                  }
                }
              }
            }
            """;

        var snapshot = Assert.IsType<CodexQuotaSnapshot>(
            CodexQuotaService.Parse(response));

        Assert.Equal(99, snapshot.DisplayWindow.RemainingPercent, 3);
        Assert.Equal(10080, snapshot.DisplayWindow.WindowDurationMinutes);
        Assert.Null(snapshot.Secondary);
    }

    [Fact]
    public void ClampsOutOfRangeUsageWithoutInventingMoreThanFullQuota()
    {
        const string response =
            """
            {
              "result": {
                "rateLimits": {
                  "primary": {
                    "usedPercent": 125,
                    "windowDurationMins": 300,
                    "resetsAt": 1786572000
                  },
                  "secondary": {
                    "usedPercent": -4,
                    "windowDurationMins": 10080,
                    "resetsAt": 1787176800
                  }
                }
              }
            }
            """;

        var snapshot = Assert.IsType<CodexQuotaSnapshot>(
            CodexQuotaService.Parse(response));

        Assert.Equal(0, snapshot.Primary.RemainingPercent, 3);
        Assert.Equal(100, snapshot.Secondary!.RemainingPercent, 3);
        Assert.Same(snapshot.Primary, snapshot.DisplayWindow);
    }

    [Theory]
    [InlineData("""{"id":2,"result":{}}""")]
    [InlineData(
        """{"id":2,"result":{"rateLimits":{"primary":null}}}""")]
    [InlineData(
        """{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":20,"windowDurationMins":0,"resetsAt":1786572000}}}}""")]
    public void MissingOrInvalidPrimaryWindowReturnsNoSnapshot(string response)
    {
        Assert.Null(CodexQuotaService.Parse(response));
    }

    [Fact]
    public void ResolvesTheInstalledCodexExecutableWhenAvailable()
    {
        var executable = CodexQuotaService.ResolveCodexExecutable();

        Assert.EndsWith(
            "codex.exe",
            executable,
            StringComparison.OrdinalIgnoreCase);
        if (Path.IsPathRooted(executable))
        {
            Assert.True(File.Exists(executable));
        }
    }

    [Theory]
    [InlineData("en-US")]
    [InlineData("de-DE")]
    public void CreditBalancePreservesPrecisionIndependentOfMachineCulture(string culture)
    {
        var previous = CultureInfo.CurrentCulture;
        try
        {
            CultureInfo.CurrentCulture = CultureInfo.GetCultureInfo(culture);
            var snapshot = ParseCredits("""{"hasCredits":true,"unlimited":false,"balance":"12345.6789012345"}""");

            Assert.Equal(new CodexCreditBalance(true, false, 12345.6789012345m), snapshot.Credits);
            Assert.Equal(0, snapshot.Primary.RemainingPercent);
        }
        finally
        {
            CultureInfo.CurrentCulture = previous;
        }
    }

    [Theory]
    [InlineData("null")]
    [InlineData("{}")]
    [InlineData("false")]
    [InlineData("[]")]
    [InlineData("""{"hasCredits":true}""")]
    [InlineData("""{"hasCredits":"true","unlimited":false,"balance":"100"}""")]
    [InlineData("""{"hasCredits":true,"unlimited":null,"balance":"100"}""")]
    [InlineData("""{"hasCredits":false,"unlimited":false,"balance":"100"}""")]
    public void MissingMalformedOrContradictoryCreditsDoNotDiscardQuota(string credits)
    {
        var snapshot = ParseCredits(credits);

        Assert.Null(snapshot.Credits);
        Assert.Equal(0, snapshot.Primary.RemainingPercent);
    }

    [Theory]
    [InlineData("null")]
    [InlineData("100")]
    [InlineData("\"\"")]
    [InlineData("\"invalid\"")]
    [InlineData("\"NaN\"")]
    [InlineData("\"Infinity\"")]
    [InlineData("\"-1\"")]
    [InlineData("\"1,234.50\"")]
    [InlineData("\"1.234,50\"")]
    [InlineData("\"99999999999999999999999999999999999999\"")]
    public void UnknownBalanceDoesNotBecomeZero(string amount)
    {
        var snapshot = ParseCredits($$"""{"hasCredits":true,"unlimited":false,"balance":{{amount}}}""");

        Assert.Equal(new CodexCreditBalance(true, false, null), snapshot.Credits);
    }

    [Fact]
    public void AbsentBalanceRemainsUnknownWhenCreditsAreAvailable()
    {
        Assert.Equal(new CodexCreditBalance(true, false, null),
            ParseCredits("""{"hasCredits":true,"unlimited":false}""").Credits);
    }

    [Theory]
    [InlineData("""{"hasCredits":false,"unlimited":false}""")]
    [InlineData("""{"hasCredits":false,"unlimited":false,"balance":null}""")]
    [InlineData("""{"hasCredits":false,"unlimited":false,"balance":"0.00"}""")]
    public void ExplicitlyNoCreditsEstablishesZero(string credits)
    {
        Assert.Equal(new CodexCreditBalance(false, false, 0), ParseCredits(credits).Credits);
    }

    [Fact]
    public void UnlimitedCreditsDoNotRequireAnAmountOrHasCreditsFlagToBeTrue()
    {
        Assert.Equal(new CodexCreditBalance(false, true, null),
            ParseCredits("""{"hasCredits":false,"unlimited":true,"balance":null}""").Credits);
    }

    [Fact]
    public void ReadsCreditsFromTheSelectedCodexBucketWithoutMixingFallbackData()
    {
        const string response = """
            {"result":{
              "rateLimits":{"primary":{"usedPercent":0,"windowDurationMins":10080,"resetsAt":1787196677},
                "credits":{"hasCredits":true,"unlimited":true}},
              "rateLimitsByLimitId":{
                "codex":{"primary":{"usedPercent":100,"windowDurationMins":10080,"resetsAt":1787196677},
                  "credits":{"hasCredits":true,"unlimited":false,"balance":"42.5"}},
                "codex_other":{"credits":{"hasCredits":true,"unlimited":false,"balance":"999"}}
              }}}
            """;

        var snapshot = Assert.IsType<CodexQuotaSnapshot>(CodexQuotaService.Parse(response));
        Assert.Equal(new CodexCreditBalance(true, false, 42.5m), snapshot.Credits);
        Assert.Equal(0, snapshot.Primary.RemainingPercent);

        var missing = response.Replace("\"balance\":\"42.5\"", "\"balance\":null", StringComparison.Ordinal);
        Assert.Null(CodexQuotaService.Parse(missing)!.Credits!.Balance);
    }

    [Fact]
    public void CreditBalanceAndResetVouchersRemainSeparate()
    {
        const string response = """
            {"result":{
              "rateLimits":{"primary":{"usedPercent":100,"windowDurationMins":10080,"resetsAt":1787196677},
                "credits":{"hasCredits":true,"unlimited":false,"balance":"123.45"}},
              "rateLimitResetCredits":{"credits":[
                {"status":"available","title":"Full reset","expiresAt":1787196677}
              ]}}}
            """;
        var snapshot = Assert.IsType<CodexQuotaSnapshot>(
            CodexQuotaService.Parse(response, DateTimeOffset.FromUnixTimeSeconds(1787000000)));

        Assert.Equal(123.45m, snapshot.Credits!.Balance);
        Assert.Single(snapshot.AvailableResets!);
    }

    private static CodexQuotaSnapshot ParseCredits(string credits) =>
        Assert.IsType<CodexQuotaSnapshot>(CodexQuotaService.Parse($$"""
            {"result":{"rateLimits":{
              "primary":{"usedPercent":100,"windowDurationMins":10080,"resetsAt":1787196677},
              "credits":{{credits}}
            } } }
            """));
}
