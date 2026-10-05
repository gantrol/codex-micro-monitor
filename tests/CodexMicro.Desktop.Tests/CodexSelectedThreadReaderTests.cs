using CodexMicro.Desktop.Services;
using Xunit;

namespace CodexMicro.Desktop.Tests;

public sealed class CodexSelectedThreadReaderTests
{
    [Theory]
    [InlineData("app://-/index.html", false, null)]
    [InlineData("app://-/detached-window.html", false, null)]
    [InlineData("app://-/", true, null)]
    [InlineData("app://-/settings", true, null)]
    [InlineData("app://-/local/01000000-0000-0000-0000-000000000001", true, "01000000-0000-0000-0000-000000000001")]
    [InlineData("app://-/index.html?initialRoute=%2Flocal%2F01000000-0000-0000-0000-000000000001", true, "01000000-0000-0000-0000-000000000001")]
    [InlineData("https://example.com/local/01000000-0000-0000-0000-000000000001", false, null)]
    public void BootstrapDocumentAllowsSidebarFallbackButRealRoutesRemainAuthoritative(string value, bool authoritative, string? thread)
    {
        var url = new Uri(value);
        Assert.Equal(authoritative, CodexSelectedThreadReader.HasDocumentRoute(url));
        Assert.Equal(thread, CodexSelectedThreadReader.ResolveDocumentThreadId(url));
    }
}
