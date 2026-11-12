# C# sample: a read-only client that survives the gateway's bad moments

The same client as the [Python sample](../python/README.md), for .NET 10 and C# 14: it
connects to an IB Gateway, prints the IBKR server time every N seconds and keeps doing so
across a gateway that is not ready yet, lost connectivity (IBKR codes 1100, 1101, 1102) and
the daily restart. The rules it implements are in [../README.md](../README.md).

It is read-only by construction: the only request it sends is the server-time request. It
contains no order, cancel or what-if call and no market-data subscription.

## Table of Contents

- [What is in here](#what-is-in-here)
- [Build and test the logic (no IBKR file needed)](#build-and-test-the-logic-no-ibkr-file-needed)
- [Get IBKR's C# client](#get-ibkrs-c-client)
- [Build and run the executable](#build-and-run-the-executable)
- [Try it without a gateway](#try-it-without-a-gateway)
- [What to copy into a strategy](#what-to-copy-into-a-strategy)
- [What was verified](#what-was-verified)

## What is in here

| Project | Needs IBKR's `CSharpAPI.dll` | Content |
|---|---|---|
| `src/GatewayClient` | no | The behaviour: `BackoffPolicy`, `GatewayState` (the 1100/1101/1102 and data-farm state machine), `ResilientClient` (the loop), `CommandLine`, and the small interface `IBrokerSession` they are written against |
| `tests/GatewayClient.Tests` | no | xUnit v3 tests of all of the above with a scriptable fake session |
| `src/GatewayClient.IbApi` | **yes** | `IbApiSession`, the adapter from `IBrokerSession` to IBKR's client, and `Program` |

`GatewayClient.slnx` holds the first two, so the logic builds and is tested on any machine.

## Build and test the logic (no IBKR file needed)

You need the .NET 10 SDK (`global.json` selects the newest installed 10.0 feature band).

```bash
cd examples/csharp
dotnet build -warnaserror
dotnet test
dotnet format GatewayClient.slnx --verify-no-changes
```

## Get IBKR's C# client

**This repository contains no IBKR code and no IBKR binary, and it must stay that way.**
IBKR's TWS API is IBKR's software under IBKR's licence (its source files say: "subject to the
terms and conditions of the IB API Non-Commercial License or the IB API Commercial License").
Interactive Brokers does not publish it as a NuGet package; packages on nuget.org that
contain it are published by third parties, and this sample does not use them. You download
the API from IBKR yourself and accept its licence yourself:

1. Open IBKR's API page, <https://interactivebrokers.github.io/>, follow it to the TWS API
   download page and take the **Windows** installer of the Stable or Latest release. On
   2026-11-12 IBKR's page described the Windows package as the one that includes the C#/.NET
   API; the Mac/Linux package was described as Java and C++ only.
2. Run the installer. By default it installs into `C:\TWS API`.
3. The C# client is the project `C:\TWS API\source\CSharpClient\client\CSharpAPI.csproj`. If
   there is no built `CSharpAPI.dll` under its `bin\Release\` folder, build it:

   ```powershell
   dotnet build "C:\TWS API\source\CSharpClient\client\CSharpAPI.csproj" -c Release
   ```

   The file this sample needs is then
   `C:\TWS API\source\CSharpClient\client\bin\Release\net8.0\CSharpAPI.dll` (the folder name
   follows the target frameworks of your API release).

On Linux or macOS, copy the `source/CSharpClient` folder from a Windows installation and
build it there with the .NET SDK. That path was not tried for this sample.

## Build and run the executable

Point the project at **your** copy of the file, either with a property or with the
environment variable `IBAPI_DLL`:

```powershell
cd examples\csharp
dotnet build src\GatewayClient.IbApi -warnaserror -p:IbApiDll="C:\TWS API\source\CSharpClient\client\bin\Release\net8.0\CSharpAPI.dll"
dotnet run --no-build --project src\GatewayClient.IbApi -- --host 127.0.0.1 --port 4002 --client-id 101 --interval 30
```

Without the property the build stops with a message that says so. The build copies
`CSharpAPI.dll` into `bin/`, which `.gitignore` excludes; never commit it.

| Option | Environment | Default | Meaning |
|---|---|---|---|
| `--host` | `IBGW_HOST` | `127.0.0.1` | Gateway host name or address |
| `--port` | `IBGW_PORT` | `4002` | API port: the host port of the relay (4001 live, 4002 paper), or 4003/4004 from another container |
| `--client-id` | `IB_CLIENT_ID` | `101` | TWS API client id; every client of one gateway needs its own (IBKR code 326 otherwise) |
| `--interval` | | `30` | Seconds between two server-time requests |

Stop it with Ctrl+C; it disconnects, which frees the client id at once.

`CSharpAPI.dll` of TWS API 10.38 and later needs the NuGet package `Google.Protobuf`; the
project references it. If your API release needs another version of it, pass
`-p:IbApiProtobufVersion=<version>` (see `Directory.Packages.props`).

## Try it without a gateway

The stand-in gateway of the Python sample speaks enough of the API protocol for IBKR's C#
client too, and never contacts IBKR:

```bash
cd examples/python && uv run python tests/fake_gateway.py --port 4002     # terminal 1
cd examples/csharp && dotnet run --no-build --project src/GatewayClient.IbApi -- --interval 2   # terminal 2
```

In terminal 1 type `1100` (the client stops asking), `1102` (it continues), `1101` (it
continues and re-subscribes), `2103` / `2104` (a data farm breaks and recovers), `drop` (the
socket closes, as in the daily restart; the client reconnects) or `quit`.

## What to copy into a strategy

- `BackoffPolicy`, `GatewayState` and `ResilientClient` have no dependency on IBKR's client.
  Put your subscriptions into the `onResubscribe` hook of `ResilientClient`: it runs after
  every connection and after every 1101.
- `IbApiSession` shows the three things that are easy to get wrong with IBKR's client:
  `eConnect` blocks and needs a timeout around it; the message pump is your own thread; and
  after a disconnect old threads still call back, so each connection gets its own wrapper
  object and late callbacks of an old connection are dropped.
- IBKR's callbacks arrive on the message thread, so `ResilientClient` guards its state with
  one lock. Keep that when you extend it.

## What was verified

- The library and its tests build with warnings as errors and pass on .NET SDK 10.0.404.
- `GatewayClient.IbApi` was compiled against `CSharpAPI.dll` of TWS API 10.48.01 and run
  against the stand-in gateway: connect, server time, 1100, 1101, 1102, farm codes, a closed
  socket followed by a reconnect, a refused port.
- It was **not** run against a real IB Gateway, and not compiled against any other API
  release. Releases before the error callback gained its `errorTime` parameter do not
  compile with `IbApiSession.cs` as it is.

Interactive Brokers, IBKR, IB Gateway and Trader Workstation are trademarks of Interactive
Brokers LLC. This project is not affiliated with, endorsed by or sponsored by Interactive
Brokers.
