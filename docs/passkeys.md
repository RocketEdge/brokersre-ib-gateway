# Passkeys and this image: what is established and what is not

State of **2026-11-12**. Every statement about IBKR on this page is a quotation from a page
that IBKR publishes, fetched on that day, or it carries the words "not established". Nothing
here was tested: no test of this repository logs in to IBKR, and no login of this image has
been made with a passkey.

This image never automates, answers, stores or bypasses a second factor, whichever kind it
is. That does not depend on anything below.

## Table of Contents

- [Established by IBKR's own pages](#established-by-ibkrs-own-pages)
- [Not established](#not-established)
- [What this image does](#what-this-image-does)
- [What an operator can do today](#what-an-operator-can-do-today)
- [What evidence would change this page](#what-evidence-would-change-this-page)
- [Sources](#sources)

## Established by IBKR's own pages

| # | Statement | IBKR's words | Source |
|---|---|---|---|
| 1 | IBKR offers passkeys, as a second factor | "IBKR allows users to authenticate their login using passkeys." They "Are a modern and highly secure form of two-factor authentication (2FA) based on the WebAuthn/FIDO2 industry standard." | [S1] |
| 2 | A passkey does not replace the password | "Enter your username and password as usual." "Select Passkey as your 2FA method (if you have multiple 2FA options)." | [S2] |
| 3 | The applications IBKR lists for passkey login are Client Portal, TWS, IBKR Desktop and IBKR Mobile | "The IBKR applications support passkey login, starting from the minimum versions outlined below." The table has five rows: Client Portal (browsers), "TWS" with "10.46.1d", "IBKR Desktop" with "v3.2a", "IBKR Mobile for Apple iOS" with "10.07", "IBKR Mobile for Android" with "8.4.912". | [S3], "Last updated on September 9, 2026" |
| 4 | IB Gateway is not in that table, and the page does not mention Linux | The words "Gateway" and "Linux" do not occur on the page. Its operating-system table has the rows Windows, macOS, Apple iOS and Android. | [S3] |
| 5 | A user can hold several second factors and picks one at login | "Multiple Two-Factor allows any client to maintain more than one active security device at the same time." A user can "activate up to 3 Passkeys for the same user." | [S4], [S5] |
| 6 | The second factors IBKR lists for logins "using our API systems" do not include passkeys, on either list | "Supported 2FA Methods": "IB Key", "Handy Key (Smart Phone applications)", "SMS / Text Messages", "Digital Security Card+ (DSC+)". "Unsupported 2FA Methods": "Security Code Card (Sometimes referred to as Bingo Card)", "Temporary Security Code Card", "Online Code Card". | [S6] |
| 7 | The login of TWS and IB Gateway is made by a person | "With either application (TWS or IBGW), the user must manually enter their username and password into a login window. For security reasons, a headless session of TWS or IBGW without a GUI is not supported." | [S7] |
| 8 | About once a week the login has to be made again | "The weekly authentication cycle starts on every Monday." | [S8] |

Rows 3 and 4 are the centre of this page: IBKR names TWS, with a minimum version, and does
not name IB Gateway.

## Not established

No page that IBKR publishes was found for any of the following. The pages in
[Sources](#sources) were read for them, and IBKR's TWS release notes 10.44 to 10.51 (there is
no page for 10.47), in which the word "passkey" does not occur:

- **Whether IB Gateway accepts a passkey.** IBKR's table names TWS, not IB Gateway, and no
  IBKR page says that IB Gateway supports passkeys, does not support them, or will.
- **How a passkey login works inside TWS.** IBKR describes the flow for Client Portal [S2] and
  for IBKR Desktop [S9]; for TWS there is only the version number of row 3.
- **What a passkey login in TWS or IB Gateway needs on Linux**: a browser component, a
  platform authenticator, USB or Bluetooth access, a desktop session. IBKR's requirements list
  no Linux at all (row 4).
- **Whether a passkey counts as a supported second factor for API logins.** It is on neither
  list of row 6; that is silence, not a statement.
- **Whether an account whose only second factor is a passkey can log in with this image.**
- **What IBKR's position is on automating a second factor.** The pages found say that the
  login is manual and that running without a GUI is not supported (row 7); none addresses the
  second factor by itself. IBKR's customer agreements were not read.

Reports by users exist that the passkey prompt of IB Gateway or TWS on Linux offers only a
USB security key, or stalls; one such thread is in the project this image derives from
([gnzsnz/ib-gateway-docker, discussion 407](https://github.com/gnzsnz/ib-gateway-docker/discussions/407)).
They are users' reports, not IBKR's statements, and nothing in them was verified here: not
established.

IBKR has written about a different product, the Client Portal Gateway of its Web API, that it
"does not support Passkey as a two-factor authentication method" (a reply in a comment thread
on IBKR Campus, dated November 10, 2026). The Client Portal Gateway is not IB Gateway; the
sentence says nothing about IB Gateway.

## What this image does

- It starts IB Gateway and lets IBC fill in the username and the password. When IBKR asks for
  a second factor it reports that (phase `2fa-pending`, events `twofa_initiated` and
  `twofa_dialog`), stays honestly unhealthy, and waits for a person
  ([log contract](log-contract.md)).
- It never answers, types, clicks, stores or bypasses a second factor, and it holds no
  passkey, no key material and no authenticator of any kind.
- `TWOFA_MAX_PROMPTS` bounds how often the Gateway asks before the container stops asking
  and waits in phase `needs-human` ([environment variables](env-vars.md)).
- What the Gateway shows when a passkey is the selected second factor, and whether IBC
  recognises that window, is not established. An unrecognised window is reported as
  `unknown_window`.

## What an operator can do today

- **Keep a second factor that IBKR lists for API logins** (row 6) on the username the gateway
  uses, for example IB Key in IBKR Mobile, where a person approves each prompt on a phone.
  IBKR allows several second factors on one user (row 5); `TWOFA_DEVICE` names the one IBC
  selects when the Gateway offers a choice. Whether your account may keep another second
  factor next to a passkey is a question for IBKR: not established here.
- **Plan the weekly login** (row 8): decide who approves the prompt, and make sure that person
  learns that it is waiting ([README](../README.md#the-weekly-login)).
- **Give the gateway a username of its own**, so that a person's logins elsewhere do not end
  its session.
- **If a second factor has to be typed into the Gateway's window**, a person can do that
  through the [break-glass console](console.md) with input switched on. The image does not.
- **Before you change the second factors of that username**, try the login with a paper
  account in an attended session and keep the events it produces.

## What evidence would change this page

- An IBKR page that lists IB Gateway among the applications with passkey login, or one that
  says it is not supported.
- An IBKR description of the passkey login of TWS or IB Gateway on Linux and what it needs.
- A change of IBKR's lists of supported second factors for API logins (row 6).
- An attended login of this image with a paper account that has a passkey: which window
  appears, what IBC logs for it, which phase and events follow, recorded as a scrubbed fixture
  like the ones behind the classifier patterns ([limitations](limitations.md), L01).

Until one of these exists, treat "IB Gateway with a passkey" as unknown, in both directions.

## Sources

All fetched on 2026-11-12.

- [S1] IBKR Guides, "Authentication Using Passkey":
  <https://www.ibkrguides.com/securelogin/sls/authentication-using-passkey.htm>
- [S2] IBKR Guides, "Using Passkey":
  <https://www.ibkrguides.com/securelogin/sls/using-passkey.htm>
- [S3] IBKR Guides, passkey "System Requirements":
  <https://www.ibkrguides.com/securelogin/sls/system-requirements.htm>
- [S4] IBKR Guides, "Multiple Two-Factor":
  <https://www.ibkrguides.com/securelogin/sls/multiple-two-factor.htm>
- [S5] IBKR Guides, "Activating Passkey":
  <https://www.ibkrguides.com/securelogin/sls/activating-passkey.htm>
- [S6] IBKR, TWS API documentation, "Supported Two Factor Authentication (2FA)":
  <https://www.interactivebrokers.com/docs/tws-api/doc/notes-limitations/supported-two-factor-authentication-2-fa>
- [S7] IBKR, TWS API documentation, "Download TWS or IB Gateway" (section "What is the IB
  Gateway?"): <https://www.interactivebrokers.com/docs/tws-api/doc/download-tws>
- [S8] IBKR, "Daily & Weekly Reauthentication":
  <https://www.interactivebrokers.com/docs/third-party-integrations/tws-settings/daily-weekly-reauthentication>
- [S9] IBKR Guides, IBKR Desktop release notes, version 3.4 ("Users can now authenticate with
  passkeys in IBKR Desktop."): <https://www.ibkrguides.com/releasenotes/ntws-v3.4.htm>
- TWS release notes: `https://www.ibkrguides.com/releasenotes/version-10.44.htm` and the same
  address for 10.45, 10.46, 10.48, 10.49, 10.50 and 10.51.
- The Client Portal Gateway reply: comment thread of the IBKR Campus lesson "Launching and
  Authenticating the Gateway":
  <https://ibkrcampus.com/campus/trading-lessons/launching-and-authenticating-the-gateway/>

Interactive Brokers, IBKR, Trader Workstation, TWS and IB Gateway are trademarks of Interactive
Brokers LLC. RocketEdge is an independent engineering firm and is not affiliated with, sponsored
by or endorsed by Interactive Brokers.
