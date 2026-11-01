# Notices

## Derivation

This repository is a derivative work of [gnzsnz/ib-gateway-docker](https://github.com/gnzsnz/ib-gateway-docker)
(MIT License, Copyright (c) 2022 Emanuel Fernandes, 2023 gnzsnz), forked conceptually at upstream
commit `master` as of 2026-10-30. The following ideas and fragments originate there and were
restructured: the two-stage Dockerfile layout, the IBC `config.ini` and `jts.ini` templates
rendered with `envsubst`, the `_FILE` secret convention, the socat relay of the loopback API
port, the Xvfb/x11vnc startup and the daily release-detection workflow against IBKR's
`version.json`. Everything else (checksum pinning of every input, read-only filesystem, no sudo,
HEALTHCHECK, phase file, JSON log contract, command-server enablement, tini, bats and container
tests, SBOM, signing, provenance) is new. The original copyright notice is retained in `LICENSE`.

## Third-party components inside the image

| Component | Licence | How it is obtained |
|---|---|---|
| Ubuntu 26.04 base image | various (Ubuntu) | `ubuntu:26.04` pinned by digest in `versions.json` |
| IB Gateway | Interactive Brokers' end-user terms | Downloaded from `download2.interactivebrokers.com` at build time and verified by SHA-256; **not redistributed** from this repository |
| IBC | GPL-3.0 | Downloaded from the [RocketEdge/ibc](https://github.com/RocketEdge/ibc) release named in `versions.json`, verified by SHA-256. IBC runs as a separate program (aggregation, not linking); its licence text ships at `/usr/share/doc/ibc/LICENSE.txt` and its complete corresponding source is the tagged commit in that repository |
| tini, Xvfb, x11vnc, socat, gettext, jq, OpenJDK (arm64 only) | their respective Ubuntu package licences | Ubuntu archive |

## Trademarks

Interactive Brokers, IBKR, Trader Workstation, TWS and IB Gateway are trademarks of Interactive
Brokers LLC. RocketEdge is an independent engineering firm and is not affiliated with, sponsored
by or endorsed by Interactive Brokers. This image is not an Interactive Brokers product.
