namespace GatewayClient;

/// <summary>
/// The IBKR system message codes this sample acts on (TWS API, "System Message Codes").
/// They arrive through the API's error callback although most of them are not errors.
/// </summary>
public static class IbkrCodes
{
    /// <summary>Connectivity between the gateway and IBKR has been lost.</summary>
    public const int ConnectivityLost = 1100;

    /// <summary>Connectivity restored, data lost: subscriptions must be made again.</summary>
    public const int ConnectivityRestoredDataLost = 1101;

    /// <summary>Connectivity restored, data maintained: carry on.</summary>
    public const int ConnectivityRestoredDataKept = 1102;

    /// <summary>The client id is already in use on this gateway.</summary>
    public const int ClientIdInUse = 326;

    /// <summary>
    /// Returns the kind of data farm a "farm broken" code is about, or <c>null</c> when
    /// <paramref name="code"/> is not one of 2103, 2105 and 2157.
    /// </summary>
    /// <param name="code">An IBKR message code.</param>
    /// <returns><c>market-data</c>, <c>hmds</c>, <c>sec-def</c> or <c>null</c>.</returns>
    public static string? BrokenFarmKind(int code) => code switch
    {
        2103 => "market-data",
        2105 => "hmds",
        2157 => "sec-def",
        _ => null,
    };

    /// <summary>
    /// Returns the kind of data farm a "farm OK" code is about, or <c>null</c> when
    /// <paramref name="code"/> is not one of 2104, 2106 and 2158.
    /// </summary>
    /// <param name="code">An IBKR message code.</param>
    /// <returns><c>market-data</c>, <c>hmds</c>, <c>sec-def</c> or <c>null</c>.</returns>
    public static string? RestoredFarmKind(int code) => code switch
    {
        2104 => "market-data",
        2106 => "hmds",
        2158 => "sec-def",
        _ => null,
    };
}
