using AwesomeAssertions;
using Microsoft.Extensions.Logging;
using Xunit;

namespace GatewayClient.Tests;

/// <summary>
/// Tests for <see cref="ResilientClient"/> against a scriptable session: no socket, no IBKR
/// assembly, no waiting. A refused connection means "not ready, try again"; 1100 means stop
/// sending and keep the connection; 1101 means re-subscribe; the daily restart closes the
/// socket and the client must come back by itself.
/// </summary>
public sealed class ResilientClientTests
{
    private static readonly TimeSpan PollInterval = TimeSpan.FromSeconds(30);

    private readonly FakeBrokerSession session = new();
    private readonly RecordingLogger<ResilientClient> logger = new();
    private readonly List<string> resubscribed = [];

    /// <summary>Host, port, client id and timeout reach the session unchanged.</summary>
    /// <returns>A task that completes with the test.</returns>
    [Fact]
    public async Task ConnectOnceAsync_GatewayReady_ConnectsWithTheConfiguredEndpoint()
    {
        var client = CreateClient();

        var connected = await client.ConnectOnceAsync(TestContext.Current.CancellationToken);

        connected.Should().BeTrue("the session accepted the connection");
        session.ConnectCalls.Should().Equal([("gateway.test", 4004, 7, TimeSpan.FromSeconds(10))], "the options are passed on unchanged");
        client.Readiness.Should().Be(Readiness.Ready, "a connected client may send requests");
    }

    /// <summary>Refused, timed out or cut off: the attempt reports false and nothing is thrown.</summary>
    /// <returns>A task that completes with the test.</returns>
    [Fact]
    public async Task ConnectOnceAsync_GatewayNotReady_ReturnsFalseWithoutThrowing()
    {
        session.ConnectScript.Enqueue(new GatewayNotReadyException("connection refused"));
        var client = CreateClient();

        var connected = await client.ConnectOnceAsync(TestContext.Current.CancellationToken);

        connected.Should().BeFalse("a gateway that is not ready is a normal condition");
        client.Readiness.Should().Be(Readiness.Disconnected, "nothing is connected");
    }

    /// <summary>Only "gateway not ready" means retry; anything else must surface.</summary>
    /// <returns>A task that completes with the test.</returns>
    [Fact]
    public async Task ConnectOnceAsync_ProgrammingError_IsNotSwallowed()
    {
        session.ConnectScript.Enqueue(new InvalidOperationException("bad state"));
        var client = CreateClient();

        var act = () => client.ConnectOnceAsync(TestContext.Current.CancellationToken);

        await act.Should().ThrowAsync<InvalidOperationException>("a defect must not look like a gateway that is not ready");
    }

    /// <summary>Three refusals, then success: three pauses, each inside its back-off band.</summary>
    /// <returns>A task that completes with the test.</returns>
    [Fact]
    public async Task ConnectUntilReadyAsync_GatewayComesUpLate_RetriesWithGrowingJitteredPauses()
    {
        EnqueueRefusals(3);
        var delay = new RecordingDelay();
        var client = CreateClient(delay);

        await client.ConnectUntilReadyAsync(TestContext.Current.CancellationToken);

        session.ConnectCalls.Should().HaveCount(4, "three refusals are followed by the attempt that succeeds");
        client.Readiness.Should().Be(Readiness.Ready, "the last attempt succeeded");
        delay.Delays.Should().HaveCount(3, "one pause follows every failed attempt");
        delay.Delays[0].TotalSeconds.Should().BeInRange(0.75, 1.0, "the first pause is the base delay less jitter");
        delay.Delays[1].TotalSeconds.Should().BeInRange(1.5, 2.0, "the second pause is twice the base less jitter");
        delay.Delays[2].TotalSeconds.Should().BeInRange(3.0, 4.0, "the third pause is four times the base less jitter");
    }

    /// <summary>Twelve refusals in a row: every pause is at most the 30 s cap.</summary>
    /// <returns>A task that completes with the test.</returns>
    [Fact]
    public async Task ConnectUntilReadyAsync_GatewayStaysAway_NeverPausesLongerThanTheCap()
    {
        EnqueueRefusals(12);
        var delay = new RecordingDelay();
        var client = CreateClient(delay);

        await client.ConnectUntilReadyAsync(TestContext.Current.CancellationToken);

        delay.Delays.Should().HaveCount(12, "one pause follows every failed attempt");
        delay.Delays.Max().Should().BeLessThanOrEqualTo(TimeSpan.FromSeconds(30), "the cap is a hard upper bound");
        delay.Delays[^1].Should().BeGreaterThanOrEqualTo(TimeSpan.FromSeconds(22.5), "late pauses sit at the cap less jitter");
    }

    /// <summary>A later outage is retried quickly at first, not at the cap reached last time.</summary>
    /// <returns>A task that completes with the test.</returns>
    [Fact]
    public async Task ConnectUntilReadyAsync_AfterASuccessfulConnection_StartsTheBackoffAgain()
    {
        EnqueueRefusals(3);
        session.ConnectScript.Enqueue(null);
        EnqueueRefusals(1);
        var delay = new RecordingDelay();
        var client = CreateClient(delay);

        await client.ConnectUntilReadyAsync(TestContext.Current.CancellationToken);
        session.Drop();
        await client.ConnectUntilReadyAsync(TestContext.Current.CancellationToken);

        delay.Delays.Should().HaveCount(4, "three pauses before the first connection and one before the second");
        delay.Delays[3].TotalSeconds.Should().BeInRange(0.75, 1.0, "the back-off restarts from the base delay");
    }

    /// <summary>The one request of the sample: the IBKR server time, with the request timeout.</summary>
    /// <returns>A task that completes with the test.</returns>
    [Fact]
    public async Task PollOnceAsync_Ready_AsksForTheServerTimeAndKeepsIt()
    {
        var client = await CreateConnectedClientAsync();

        var answer = await client.PollOnceAsync(TestContext.Current.CancellationToken);

        answer.Should().Be(FakeBrokerSession.ServerTime, "the gateway answered");
        client.LastServerTime.Should().Be(FakeBrokerSession.ServerTime, "the last answer is kept");
        session.TimeRequests.Should().Equal([TimeSpan.FromSeconds(5)], "one request went out with the request timeout");
    }

    /// <summary>Without a connection a poll is skipped, not attempted.</summary>
    /// <returns>A task that completes with the test.</returns>
    [Fact]
    public async Task PollOnceAsync_Disconnected_SendsNothing()
    {
        var client = CreateClient();

        var answer = await client.PollOnceAsync(TestContext.Current.CancellationToken);

        answer.Should().BeNull("nothing was asked");
        session.TimeRequests.Should().BeEmpty("a disconnected client must not send");
    }

    /// <summary>Connectivity lost: no request goes out, and the socket is neither closed nor reopened.</summary>
    /// <returns>A task that completes with the test.</returns>
    [Fact]
    public async Task PollOnceAsync_After1100_SendsNothingAndKeepsTheConnection()
    {
        var client = await CreateConnectedClientAsync();

        session.EmitError(1100, "Connectivity between IBKR and the gateway has been lost");
        var answer = await client.PollOnceAsync(TestContext.Current.CancellationToken);

        answer.Should().BeNull("requests are paused during an outage");
        session.TimeRequests.Should().BeEmpty("1100 means stop sending");
        client.Readiness.Should().Be(Readiness.ConnectivityLost, "1100 was received");
        session.DisconnectCalls.Should().Be(0, "1100 means keep the connection");
        session.IsConnected.Should().BeTrue("the socket was not touched");
        session.ConnectCalls.Should().HaveCount(1, "no reconnect is attempted during an outage");
    }

    /// <summary>Connectivity restored, data maintained: polling resumes on the same connection.</summary>
    /// <returns>A task that completes with the test.</returns>
    [Fact]
    public async Task PollOnceAsync_After1102_ContinuesWithoutResubscribing()
    {
        var client = await CreateConnectedClientAsync();
        session.EmitError(1100, "lost");

        session.EmitError(1102, "Connectivity restored - data maintained");
        var answer = await client.PollOnceAsync(TestContext.Current.CancellationToken);

        answer.Should().Be(FakeBrokerSession.ServerTime, "requests continue after 1102");
        client.Readiness.Should().Be(Readiness.Ready, "1102 ends the outage");
        resubscribed.Should().HaveCount(1, "only the connection itself asked for subscriptions; 1102 keeps them");
        session.ConnectCalls.Should().HaveCount(1, "the same connection is used");
    }

    /// <summary>Connectivity restored, data lost: the re-subscribe hook runs a second time.</summary>
    /// <returns>A task that completes with the test.</returns>
    [Fact]
    public async Task PollOnceAsync_After1101_ContinuesAndResubscribes()
    {
        var client = await CreateConnectedClientAsync();
        session.EmitError(1100, "lost");

        session.EmitError(1101, "Connectivity restored - data lost");
        var answer = await client.PollOnceAsync(TestContext.Current.CancellationToken);

        answer.Should().Be(FakeBrokerSession.ServerTime, "requests continue after 1101");
        resubscribed.Should().HaveCount(2, "once for the connection and once for 1101");
        client.Resubscriptions.Should().Be(2, "the counter follows the hook");
        session.ConnectCalls.Should().HaveCount(1, "the same connection is used");
    }

    /// <summary>Farm codes describe market-data routes; the API connection is still usable.</summary>
    /// <param name="brokenCode">2103, 2105 or 2157.</param>
    /// <param name="okCode">The matching OK code.</param>
    /// <returns>A task that completes with the test.</returns>
    [Theory]
    [InlineData(2103, 2104)]
    [InlineData(2105, 2106)]
    [InlineData(2157, 2158)]
    public async Task PollOnceAsync_BrokenDataFarm_KeepsPollingAndTracksTheFarm(int brokenCode, int okCode)
    {
        var client = await CreateConnectedClientAsync();

        session.EmitError(brokenCode, "A data farm connection is broken:usfarm");
        var answer = await client.PollOnceAsync(TestContext.Current.CancellationToken);

        answer.Should().Be(FakeBrokerSession.ServerTime, "a broken farm does not stop the API");
        client.BrokenFarms.Should().Equal(["usfarm"], "the farm is recorded by name");
        session.DisconnectCalls.Should().Be(0, "a farm code is no reason to disconnect");

        session.EmitError(okCode, "A data farm connection is OK:usfarm");

        client.BrokenFarms.Should().BeEmpty("the OK code clears the farm");
    }

    /// <summary>The peer closing the connection (daily restart) is noticed without a request.</summary>
    /// <returns>A task that completes with the test.</returns>
    [Fact]
    public async Task Disconnected_SocketClosedByThePeer_MakesTheClientDisconnected()
    {
        var client = await CreateConnectedClientAsync();

        session.Drop();

        client.Readiness.Should().Be(Readiness.Disconnected, "the socket is gone");
    }

    /// <summary>A request cut off by a disconnect closes the session and reports nothing.</summary>
    /// <returns>A task that completes with the test.</returns>
    [Fact]
    public async Task PollOnceAsync_ConnectionClosesDuringTheRequest_DropsTheSession()
    {
        session.TimeScript.Enqueue(new GatewayNotReadyException("connection closed"));
        var client = await CreateConnectedClientAsync();

        var answer = await client.PollOnceAsync(TestContext.Current.CancellationToken);

        answer.Should().BeNull("there was no answer");
        client.Readiness.Should().Be(Readiness.Disconnected, "the connection closed");
        session.DisconnectCalls.Should().Be(1, "the client makes sure the socket is closed");
    }

    /// <summary>A half-open socket never reports a disconnect; silence is the only signal.</summary>
    /// <returns>A task that completes with the test.</returns>
    [Fact]
    public async Task PollOnceAsync_ThreeUnansweredRequestsInARow_DropsAConnectionThatLooksDead()
    {
        session.TimeScript.Enqueue(new TimeoutException());
        session.TimeScript.Enqueue(new TimeoutException());
        session.TimeScript.Enqueue(new TimeoutException());
        var client = await CreateConnectedClientAsync();

        for (var poll = 0; poll < 3; poll++)
        {
            (await client.PollOnceAsync(TestContext.Current.CancellationToken)).Should().BeNull("request {0} was not answered", poll);
        }

        session.DisconnectCalls.Should().Be(1, "three misses in a row replace the connection");
        client.Readiness.Should().Be(Readiness.Disconnected, "the next step is a reconnect");
    }

    /// <summary>Two misses, an answer, two misses: never three in a row, so the connection stays.</summary>
    /// <returns>A task that completes with the test.</returns>
    [Fact]
    public async Task PollOnceAsync_AnAnswerBetweenMisses_ResetsTheCount()
    {
        session.TimeScript.Enqueue(new TimeoutException());
        session.TimeScript.Enqueue(new TimeoutException());
        session.TimeScript.Enqueue(FakeBrokerSession.ServerTime);
        session.TimeScript.Enqueue(new TimeoutException());
        session.TimeScript.Enqueue(new TimeoutException());
        var client = await CreateConnectedClientAsync();

        for (var poll = 0; poll < 5; poll++)
        {
            await client.PollOnceAsync(TestContext.Current.CancellationToken);
        }

        session.DisconnectCalls.Should().Be(0, "there were never three misses in a row");
        client.Readiness.Should().Be(Readiness.Ready, "the connection is still considered alive");
    }

    /// <summary>A client id that is already in use is a configuration problem worth a clear line.</summary>
    /// <returns>A task that completes with the test.</returns>
    [Fact]
    public async Task ErrorReceived_Code326_IsLoggedWithTheWayOut()
    {
        var client = await CreateConnectedClientAsync();

        session.EmitError(326, "Unable to connect as the client id is already in use");

        client.Readiness.Should().Be(Readiness.Ready, "326 is not a connectivity code");
        logger.Entries.Should().Contain(
            entry => entry.Level == LogLevel.Error && entry.Message.Contains("client id 7", StringComparison.Ordinal),
            "the operator must learn which client id clashes");
    }

    /// <summary>The raw text of an IBKR message can name an account; only the code is logged.</summary>
    /// <returns>A task that completes with the test.</returns>
    [Fact]
    public async Task ErrorReceived_AnyCode_NeverLogsTheRawMessageText()
    {
        await CreateConnectedClientAsync();

        session.EmitError(1100, "CANARY_ACCOUNT_TEXT lost");
        session.EmitError(2103, "CANARY_ACCOUNT_TEXT broken:usfarm");
        session.EmitError(326, "CANARY_ACCOUNT_TEXT in use");

        logger.Entries.Should().NotContain(
            entry => entry.Message.Contains("CANARY_ACCOUNT_TEXT", StringComparison.Ordinal),
            "log lines carry codes and farm names, never IBKR's raw text");
    }

    /// <summary>Start before the gateway: two refusals, a connection, one server time, then stop.</summary>
    /// <returns>A task that completes with the test.</returns>
    [Fact]
    public async Task RunAsync_GatewayNotUpYet_WaitsThenPolls()
    {
        EnqueueRefusals(2);
        var delay = new RecordingDelay(stopAfter: 3);
        var client = CreateClient(delay);

        var act = () => client.RunAsync(TestContext.Current.CancellationToken);

        await act.Should().ThrowAsync<OperationCanceledException>("cancelling is how the client is stopped");
        session.ConnectCalls.Should().HaveCount(3, "two refusals and the attempt that succeeds");
        session.TimeRequests.Should().HaveCount(1, "one poll before the stop");
        delay.Delays[0].TotalSeconds.Should().BeInRange(0.75, 1.0, "first back-off pause");
        delay.Delays[1].TotalSeconds.Should().BeInRange(1.5, 2.0, "second back-off pause");
        delay.Delays[2].Should().Be(PollInterval, "then the client pauses for the poll interval");
    }

    /// <summary>The gateway closes the socket, refuses once while it restarts, then is back.</summary>
    /// <returns>A task that completes with the test.</returns>
    [Fact]
    public async Task RunAsync_DailyRestart_ReconnectsAndResubscribes()
    {
        session.ConnectScript.Enqueue(null);
        EnqueueRefusals(1);
        var delay = new RecordingDelay(stopAfter: 3);
        delay.Events[0] = session.Drop;
        var client = CreateClient(delay);

        var act = () => client.RunAsync(TestContext.Current.CancellationToken);

        await act.Should().ThrowAsync<OperationCanceledException>("cancelling is how the client is stopped");
        session.ConnectCalls.Should().HaveCount(3, "the first connection, one refusal during the restart, the reconnection");
        session.TimeRequests.Should().HaveCount(2, "one poll on each connection");
        resubscribed.Should().HaveCount(2, "subscriptions are set up again on the new connection");
        delay.Delays[0].Should().Be(PollInterval, "the restart happens during the first poll pause");
        delay.Delays[1].TotalSeconds.Should().BeInRange(0.75, 1.0, "the reconnect starts with the base back-off");
        delay.Delays[2].Should().Be(PollInterval, "polling continues after the reconnection");
    }

    /// <summary>1100 during the first pause, 1102 during the second: one poll is skipped.</summary>
    /// <returns>A task that completes with the test.</returns>
    [Fact]
    public async Task RunAsync_OutageBetweenPolls_SkipsThePollAndResumes()
    {
        var delay = new RecordingDelay(stopAfter: 3);
        delay.Events[0] = () => session.EmitError(1100, "lost");
        delay.Events[1] = () => session.EmitError(1102, "restored");
        var client = CreateClient(delay);

        var act = () => client.RunAsync(TestContext.Current.CancellationToken);

        await act.Should().ThrowAsync<OperationCanceledException>("cancelling is how the client is stopped");
        session.TimeRequests.Should().HaveCount(2, "the poll during the outage is skipped");
        session.ConnectCalls.Should().HaveCount(1, "the connection is kept throughout");
    }

    /// <summary>Stopping the client disconnects, which frees the client id at once.</summary>
    /// <returns>A task that completes with the test.</returns>
    [Fact]
    public async Task RunAsync_Stopped_ClosesTheConnection()
    {
        var client = CreateClient(new RecordingDelay(stopAfter: 1));

        var act = () => client.RunAsync(TestContext.Current.CancellationToken);

        await act.Should().ThrowAsync<OperationCanceledException>("cancelling is how the client is stopped");
        session.DisconnectCalls.Should().Be(1, "the connection is closed on the way out");
        session.IsConnected.Should().BeFalse("nothing is left connected");
    }

    /// <summary>An operator who stops the client must not read "will reconnect" in its last line.</summary>
    /// <returns>A task that completes with the test.</returns>
    [Fact]
    public async Task RunAsync_Stopped_IsNotLoggedAsALostConnection()
    {
        var client = CreateClient(new RecordingDelay(stopAfter: 1));

        var act = () => client.RunAsync(TestContext.Current.CancellationToken);

        await act.Should().ThrowAsync<OperationCanceledException>("cancelling is how the client is stopped");
        logger.Entries.Should().NotContain(
            entry => entry.Message.Contains("will reconnect", StringComparison.Ordinal),
            "a requested stop is not a lost connection");
        logger.Entries.Should().Contain(
            entry => entry.Message.Contains("client stopped", StringComparison.Ordinal),
            "the last line says why the connection was closed");
    }

    /// <summary>A configuration that could never work fails when it is built, not at 3 a.m.</summary>
    [Fact]
    public void ClientOptions_ImpossibleValues_AreRefusedWhenSet()
    {
        var port = () => new ClientOptions { Port = 0 };
        var highPort = () => new ClientOptions { Port = 70000 };
        var clientId = () => new ClientOptions { ClientId = -1 };
        var pollInterval = () => new ClientOptions { PollInterval = TimeSpan.Zero };
        var connectTimeout = () => new ClientOptions { ConnectTimeout = TimeSpan.Zero };
        var requestTimeout = () => new ClientOptions { RequestTimeout = TimeSpan.FromSeconds(-1) };
        var missedPolls = () => new ClientOptions { MaxMissedPolls = 0 };
        var host = () => new ClientOptions { Host = " " };

        port.Should().Throw<ArgumentOutOfRangeException>("a port is 1 to 65535");
        highPort.Should().Throw<ArgumentOutOfRangeException>("a port is 1 to 65535");
        clientId.Should().Throw<ArgumentOutOfRangeException>("a client id is 0 or more");
        pollInterval.Should().Throw<ArgumentOutOfRangeException>("the poll interval must be positive");
        connectTimeout.Should().Throw<ArgumentOutOfRangeException>("the connect timeout must be positive");
        requestTimeout.Should().Throw<ArgumentOutOfRangeException>("the request timeout must be positive");
        missedPolls.Should().Throw<ArgumentOutOfRangeException>("at least one missed poll must be tolerated");
        host.Should().Throw<ArgumentException>("a host name is required");
    }

    /// <summary>The defaults point at a paper gateway on this host with a client id of its own.</summary>
    [Fact]
    public void ClientOptions_Defaults_PointAtAPaperGatewayOnThisHost()
    {
        var options = new ClientOptions();

        (options.Host, options.Port, options.ClientId, options.PollInterval).Should().Be(
            ("127.0.0.1", 4002, 101, TimeSpan.FromSeconds(30)),
            "these are the documented defaults");
    }

    /// <summary>Builds a client on the fake session with a seeded generator and a recording delay.</summary>
    /// <param name="delay">The delay to inject; a fresh recorder when omitted.</param>
    /// <returns>The client under test.</returns>
    private ResilientClient CreateClient(RecordingDelay? delay = null)
    {
        var options = new ClientOptions
        {
            Host = "gateway.test",
            Port = 4004,
            ClientId = 7,
            PollInterval = PollInterval,
            ConnectTimeout = TimeSpan.FromSeconds(10),
            RequestTimeout = TimeSpan.FromSeconds(5),
            MaxMissedPolls = 3,
            Backoff = new BackoffPolicy(TimeSpan.FromSeconds(1), TimeSpan.FromSeconds(30), jitter: 0.25),
        };
        return new ResilientClient(
            session,
            options,
            logger,
            (delay ?? new RecordingDelay()).DelayAsync,
            new Random(42),
            () => resubscribed.Add("resubscribe"));
    }

    /// <summary>Builds a client and connects it once.</summary>
    /// <returns>A connected client.</returns>
    private async Task<ResilientClient> CreateConnectedClientAsync()
    {
        var client = CreateClient();
        (await client.ConnectOnceAsync(TestContext.Current.CancellationToken)).Should().BeTrue("the fake session accepts the connection");
        return client;
    }

    /// <summary>Scripts <paramref name="count"/> refused connection attempts.</summary>
    /// <param name="count">Number of refusals to enqueue.</param>
    private void EnqueueRefusals(int count)
    {
        for (var index = 0; index < count; index++)
        {
            session.ConnectScript.Enqueue(new GatewayNotReadyException("connection refused"));
        }
    }
}
