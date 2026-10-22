using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;

namespace CodexMicro.Remote;

public static class HostCertificateManager
{
    public static (X509Certificate2 Certificate, string FingerprintSha256) LoadOrCreateCertificate(string storageDirectory, string hostId)
    {
        Directory.CreateDirectory(storageDirectory);
        var pfxPath = Path.Combine(storageDirectory, "host-tls-cert.pfx");

        if (File.Exists(pfxPath))
        {
            try
            {
                var existing = X509CertificateLoader.LoadPkcs12FromFile(
                    pfxPath,
                    password: null,
                    keyStorageFlags: X509KeyStorageFlags.Exportable);
                if (existing.NotAfter > DateTime.UtcNow.AddDays(7))
                {
                    var pin = MicroRemoteCrypto.Sha256Hex(existing.RawData);
                    return (existing, pin);
                }
                existing.Dispose();
            }
            catch
            {
                // Regenerate certificate if corrupt or unreadable
            }
        }

        using var ecdsa = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        var req = new CertificateRequest(
            $"CN=CodexMicro-{hostId}",
            ecdsa,
            HashAlgorithmName.SHA256);

        var sanBuilder = new SubjectAlternativeNameBuilder();
        sanBuilder.AddDnsName("localhost");
        sanBuilder.AddIpAddress(IPAddress.Loopback);
        foreach (var ip in GetCandidateIPv4Addresses())
        {
            sanBuilder.AddIpAddress(ip);
        }
        req.CertificateExtensions.Add(sanBuilder.Build());
        req.CertificateExtensions.Add(new X509BasicConstraintsExtension(false, false, 0, false));
        req.CertificateExtensions.Add(
            new X509KeyUsageExtension(
                X509KeyUsageFlags.DigitalSignature | X509KeyUsageFlags.KeyEncipherment,
                critical: false));

        using var ephemeral = req.CreateSelfSigned(
            DateTimeOffset.UtcNow.AddMinutes(-5),
            DateTimeOffset.UtcNow.AddYears(3));

        var pfxBytes = ephemeral.Export(X509ContentType.Pfx);
        File.WriteAllBytes(pfxPath, pfxBytes);

        var loaded = X509CertificateLoader.LoadPkcs12(
            pfxBytes,
            password: null,
            keyStorageFlags: X509KeyStorageFlags.Exportable);
        var fingerprint = MicroRemoteCrypto.Sha256Hex(loaded.RawData);
        return (loaded, fingerprint);
    }

    public static IReadOnlyList<string> DiscoverEndpoints(int port, bool useTls)
    {
        var scheme = useTls ? "wss" : "ws";
        var tailscale = new List<string>();
        var lan = new List<string>();

        foreach (var ip in GetCandidateIPv4Addresses())
        {
            var ep = $"{scheme}://{ip}:{port}{MicroRemoteConstants.DefaultWebSocketPath}";
            if (IsTailscaleIPv4(ip))
            {
                tailscale.Add(ep);
            }
            else
            {
                lan.Add(ep);
            }
        }

        var ordered = new List<string>(tailscale.Count + lan.Count + 1);
        ordered.AddRange(tailscale);
        ordered.AddRange(lan);
        if (ordered.Count == 0)
        {
            ordered.Add($"{scheme}://127.0.0.1:{port}{MicroRemoteConstants.DefaultWebSocketPath}");
        }
        return ordered;
    }

    private static IReadOnlyList<IPAddress> GetCandidateIPv4Addresses()
    {
        var list = new List<IPAddress>();
        try
        {
            foreach (var nic in NetworkInterface.GetAllNetworkInterfaces())
            {
                if (nic.OperationalStatus != OperationalStatus.Up ||
                    nic.NetworkInterfaceType == NetworkInterfaceType.Loopback)
                {
                    continue;
                }
                var props = nic.GetIPProperties();
                foreach (var unicast in props.UnicastAddresses)
                {
                    if (unicast.Address.AddressFamily != AddressFamily.InterNetwork)
                    {
                        continue;
                    }
                    var bytes = unicast.Address.GetAddressBytes();
                    if (bytes[0] == 169 && bytes[1] == 254)
                    {
                        continue;
                    }
                    list.Add(unicast.Address);
                }
            }
        }
        catch
        {
            // Ignore interface enumeration errors
        }
        return list;
    }

    private static bool IsTailscaleIPv4(IPAddress address)
    {
        var bytes = address.GetAddressBytes();
        return bytes.Length == 4 && bytes[0] == 100 && bytes[1] >= 64 && bytes[1] <= 127;
    }
}
