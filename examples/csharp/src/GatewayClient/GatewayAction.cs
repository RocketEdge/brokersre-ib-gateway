namespace GatewayClient;

/// <summary>
/// What the caller of <see cref="GatewayState"/> must do after an event.
/// </summary>
public enum GatewayAction
{
    /// <summary>Nothing changed for the caller.</summary>
    None,

    /// <summary>Stop sending requests until told otherwise.</summary>
    Pause,

    /// <summary>Requests may continue; subscriptions are intact.</summary>
    Resume,

    /// <summary>Requests may continue and every subscription must be made again.</summary>
    Resubscribe,
}
