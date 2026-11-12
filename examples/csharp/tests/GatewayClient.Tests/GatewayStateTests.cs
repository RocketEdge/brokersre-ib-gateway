using AwesomeAssertions;
using Xunit;

namespace GatewayClient.Tests;

/// <summary>
/// Tests for <see cref="GatewayState"/>: what a client may do, derived from IBKR's message
/// codes. 1100 means stop sending and keep the connection; 1102 means continue; 1101 means
/// continue and re-subscribe; the data-farm codes never change readiness.
/// </summary>
public sealed class GatewayStateTests
{
    /// <summary>Before any connection nothing may be sent.</summary>
    [Fact]
    public void NewState_IsDisconnectedWithNoBrokenFarm()
    {
        var state = new GatewayState();

        state.Readiness.Should().Be(Readiness.Disconnected, "nothing is connected yet");
        state.BrokenFarms.Should().BeEmpty("no farm has been reported");
    }

    /// <summary>A fresh API session has no subscriptions: connecting always means subscribing.</summary>
    [Fact]
    public void OnConnected_MakesReadyAndAsksForSubscriptions()
    {
        var state = new GatewayState();

        var action = state.OnConnected();

        action.Should().Be(GatewayAction.Resubscribe, "a new session has no subscriptions");
        state.Readiness.Should().Be(Readiness.Ready, "the connection stands");
    }

    /// <summary>The three connectivity codes move a connected client as IBKR documents them.</summary>
    /// <param name="code">The IBKR code received after 1100.</param>
    /// <param name="expectedAction">What the client must do.</param>
    /// <param name="expectedReadiness">The readiness afterwards.</param>
    [Theory]
    [InlineData(1100, GatewayAction.Pause, Readiness.ConnectivityLost)]
    [InlineData(1101, GatewayAction.Resubscribe, Readiness.Ready)]
    [InlineData(1102, GatewayAction.Resume, Readiness.Ready)]
    public void OnError_ConnectivityCodeAfter1100_MovesTheState(int code, GatewayAction expectedAction, Readiness expectedReadiness)
    {
        var state = Connected();
        state.OnError(1100, "Connectivity between IBKR and the gateway has been lost")
            .Should().Be(GatewayAction.Pause, "1100 pauses a ready client");
        state.Readiness.Should().Be(Readiness.ConnectivityLost, "1100 keeps the connection but stops requests");

        var action = state.OnError(code, "text");

        action.Should().Be(expectedAction, "that is the documented meaning of code {0}", code);
        state.Readiness.Should().Be(expectedReadiness, "that is the documented meaning of code {0}", code);
    }

    /// <summary>A late message from a connection that is already gone must not make the client ready.</summary>
    /// <param name="code">Any code this state machine knows.</param>
    [Theory]
    [InlineData(1100)]
    [InlineData(1101)]
    [InlineData(1102)]
    [InlineData(2103)]
    [InlineData(2104)]
    [InlineData(2105)]
    [InlineData(2106)]
    [InlineData(2157)]
    [InlineData(2158)]
    public void OnError_WhileDisconnected_ChangesNothing(int code)
    {
        var state = new GatewayState();

        var action = state.OnError(code, "Market data farm connection is broken:usfarm");

        action.Should().Be(GatewayAction.None, "no connection means no transition");
        state.Readiness.Should().Be(Readiness.Disconnected, "a message code cannot connect");
        state.BrokenFarms.Should().BeEmpty("farm status belongs to a connection");
    }

    /// <summary>A broken data farm is recorded by name and cleared by the matching OK code.</summary>
    /// <param name="brokenCode">2103, 2105 or 2157.</param>
    /// <param name="okCode">2104, 2106 or 2158.</param>
    /// <param name="farm">Farm name as it follows the colon in IBKR's text.</param>
    [Theory]
    [InlineData(2103, 2104, "usfarm")]
    [InlineData(2105, 2106, "ushmds")]
    [InlineData(2157, 2158, "secdefil")]
    public void OnError_FarmCodes_MarkAndClearTheFarmWithoutTouchingReadiness(int brokenCode, int okCode, string farm)
    {
        var state = Connected();

        var brokenAction = state.OnError(brokenCode, $"A data farm connection is broken:{farm}");

        brokenAction.Should().Be(GatewayAction.None, "a farm code is not a connectivity event");
        state.BrokenFarms.Should().Equal([farm], "the farm after the colon is recorded");
        state.Readiness.Should().Be(Readiness.Ready, "a broken farm does not stop the API");

        var okAction = state.OnError(okCode, $"A data farm connection is OK:{farm}");

        okAction.Should().Be(GatewayAction.None, "a farm code is not a connectivity event");
        state.BrokenFarms.Should().BeEmpty("the OK code clears the farm");
        state.Readiness.Should().Be(Readiness.Ready, "readiness never depended on the farm");
    }

    /// <summary>The list is sorted so that a log line or an assertion is stable.</summary>
    [Fact]
    public void BrokenFarms_SeveralFarms_AreListedInNameOrder()
    {
        var state = Connected();

        state.OnError(2105, "HMDS data farm connection is broken:ushmds");
        state.OnError(2103, "Market data farm connection is broken:usfarm");
        state.OnError(2103, "Market data farm connection is broken:eufarm");
        state.OnError(2104, "Market data farm connection is OK:usfarm");

        state.BrokenFarms.Should().Equal(["eufarm", "ushmds"], "usfarm recovered and the rest is sorted by name");
    }

    /// <summary>IBKR's text is not a contract; a message without ':farm' still leaves a trace.</summary>
    [Fact]
    public void OnError_FarmMessageWithoutName_IsRecordedUnderItsKind()
    {
        var state = Connected();

        state.OnError(2103, "Market data farm connection is broken");

        state.BrokenFarms.Should().Equal(["market-data"], "the kind of farm is the fallback name");
    }

    /// <summary>Only 1101 and 1102 end an 1100; a farm coming back first does not.</summary>
    [Fact]
    public void OnError_FarmOkDuringOutage_DoesNotEndTheOutage()
    {
        var state = Connected();
        state.OnError(1100, "lost");

        state.OnError(2104, "Market data farm connection is OK:usfarm");

        state.Readiness.Should().Be(Readiness.ConnectivityLost, "a farm code is not 1101 or 1102");
    }

    /// <summary>Request errors and other notices do not move the state machine.</summary>
    /// <param name="code">A code that is neither a connectivity nor a farm code.</param>
    [Theory]
    [InlineData(0)]
    [InlineData(200)]
    [InlineData(326)]
    [InlineData(502)]
    [InlineData(2107)]
    [InlineData(2108)]
    public void OnError_AnyOtherCode_IsNotAConnectivityEvent(int code)
    {
        var state = Connected();

        var action = state.OnError(code, "something else");

        action.Should().Be(GatewayAction.None, "code {0} says nothing about connectivity", code);
        state.Readiness.Should().Be(Readiness.Ready, "code {0} says nothing about connectivity", code);
    }

    /// <summary>The next connection is a new session: farm status starts from scratch.</summary>
    [Fact]
    public void OnDisconnected_PausesAndForgetsTheFarms()
    {
        var state = Connected();
        state.OnError(2103, "Market data farm connection is broken:usfarm");

        var action = state.OnDisconnected();

        action.Should().Be(GatewayAction.Pause, "nothing may be sent without a connection");
        state.Readiness.Should().Be(Readiness.Disconnected, "the connection is gone");
        state.BrokenFarms.Should().BeEmpty("farm status belonged to the old session");
    }

    /// <summary>A connection that was dropped during an 1100 does not stay paused when it returns.</summary>
    [Fact]
    public void OnConnected_AfterAnOutageAndADisconnect_StartsReady()
    {
        var state = Connected();
        state.OnError(1100, "lost");
        state.OnDisconnected();

        var action = state.OnConnected();

        action.Should().Be(GatewayAction.Resubscribe, "a new session has no subscriptions");
        state.Readiness.Should().Be(Readiness.Ready, "the outage ended with the old session");
    }

    /// <summary>Returns a state machine that has seen a successful connection.</summary>
    private static GatewayState Connected()
    {
        var state = new GatewayState();
        state.OnConnected();
        return state;
    }
}
