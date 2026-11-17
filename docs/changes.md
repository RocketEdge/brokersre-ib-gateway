# Change Log — brokersre-ib-gateway

Append-only; newest first. Fields: Date, What changed, Result, What did NOT work / root cause,
Next step.

## Change History

### 2026-11-17 — First publish to the non-public package

- **What changed:** documentation only: the ADR 0018 note of 2026-11-17 and the owner checklist
  in `tasks/todo.md` record the first publish to the re-created package. The owner kept the
  package internal (L40 accepted) and granted this repository Write under *Manage Actions
  access*; `publish.yml`, `detect-releases.yml` and `rebuild.yml` were enabled again.
- **Result:** run 44166458142 (dispatched 20:10 UTC, both channels) succeeded through both "not
  public" checks and the signature verification. Checked from outside at 20:20 UTC:
  - an anonymous token request answers 401;
  - with a token that can read packages, `stable` is `sha256:8ff97ed6…` (10.50.1g,
    `qualified=yes`) and `latest` is `sha256:fd4ecd55…`;
  - the pull of the stable digest and `cosign verify` against `publish.yml`'s identity passed;
  - the release `v10.50.1g-stable` names the new digest and says the image is not public.
- **What did NOT work / root cause:** nothing new in this step. The package is still linked to
  no repository; the Actions access grant alone lets the workflows in (ADR 0018, amendment).
- **Next step:** read the first scan of `rebuild.yml` and the first hourly run of
  `detect-releases.yml` against the package; one `qualify-paper.yml` run against a digest of
  it; confirm the BrokerSRE repository's Read grant with its next `image-pin.yml` run.

### 2026-11-17 — Re-review of #43: malformed proxy values refused, every proxy value masked

- **What changed:** both wrappers check every set proxy variable before anything runs (no
  docker call). `HTTPS_PROXY`, `HTTP_PROXY` and their lower-case forms must be
  `scheme://[user[:password]@]host[:port][/]`: scheme http, https, socks4, socks4a, socks5 or
  socks5h; a host name, an IPv4 address or an IPv6 address in brackets; port 1 to 65535; in
  the user information only RFC 3986's unreserved and sub-delims characters, the rest
  percent-encoded; no whitespace. `NO_PROXY` and `no_proxy` must hold no control character. A
  failure exits 2 and names the variable, never its value. The helper's `hide_proxy_values`
  replaces each proxy value (as written and percent-decoded), its `user:password` and its
  password with `***` in curl's errors, then applies the old URL pattern. README: the accepted
  form, the percent-encoding rule, a troubleshooting row; both contract files.
- **Result:** red first. bats: the reviewer's four values (no scheme; a `/`, a space, a second
  `@` in the password) and six more (scheme, ports 0 and 65536, no host, a broken escape, a
  final line break), each as `HTTPS_PROXY` and `http_proxy`, exited 0 instead of 2; a tab in
  `NO_PROXY` likewise; the helper showed `Unsupported proxy syntax in '...'` with the
  password; a stand-in curl quoting the decoded value, `user:password` and the password leaked
  all three. Pester: 11 failing. Then green: `build-image.bats` 72/72 on Linux, Pester 62/62
  in PowerShell 7 and 5.1; the bash and PowerShell checks agree on 23 further edge cases. End
  to end: the real wrapper with a space in the password exited 2 with the name only; through
  Squid (fresh docker-container builder, helper image removed, percent-encoded password in all
  four variables) the build passed its smoke test in 211 s, Squid logged 262 requests
  (Alpine, IBKR, Ubuntu's archives, GitHub), the password was in neither the output nor
  `docker history`/`inspect`, and the two named build records held it four times each until
  removed.
- **What did NOT work / root cause:** the previous round masked `://user:password@` with a
  pattern and tested it with a value of exactly that shape. The values curl cannot parse are
  the ones whose shape differs, and curl quotes them in full. A pattern cannot know which part
  is the password; the values themselves can. Masking only covered the helper: the
  Dockerfile's apt-get and curl received the same values, which only the check up front keeps
  out.
- **Next step:** proxies from Docker's `config.json` reach the build without passing the
  wrappers, so they are not checked; `ALL_PROXY` is not forwarded. A proxy that requires
  authentication, and a real corporate proxy, remain untested.

### 2026-11-17 — An unchanged rebuild keeps its image id: deterministic `created`, no provenance

- **What changed:** both wrappers label `org.opencontainers.image.created` with the checkout's
  commit time in UTC (asked inside the checkout, like `revision`), or outside a git work tree
  with IBKR's build time of the installer (the stamp's date and time as ISO 8601, written as
  UTC; IBKR names no zone), never the clock, and build the image with `--provenance=false`.
  README ("Pinning and reproducing a build", "Upgrading and rolling back"),
  `docs/evidence.md`, the container suite's comment and both contract files say so.
- **Result:** bats and Pester red first (two builds of the same inputs, one `created`; a new
  commit, a new one; `--provenance=false` on the image build), then green. End to end on
  Docker Desktop 29.9.3 (containerd image store), a fresh clone of `ba2b979`, cache hit: two
  consecutive `build-image.sh` runs (77 s, 75 s) both gave `sha256:3d508f042063…`, and
  `build-image.ps1` on the same clone gave the same id; `docker compose ... up -d`
  (`IBC_LAUNCH=no`, dummy secret files) after the second build printed `Container
  det-e2e-ib-gateway-1 Running`, the container started by the first `up`. A new commit gave a
  new manifest, and compose recreated the container. A build through Squid with a canary
  password in `HTTPS_PROXY` gave the same id and named its two build records.
- **What did NOT work / root cause:** the deterministic label alone did not keep the id: two
  warm builds of `890bd39` gave `a2171de11e94`, then `f4a0fdcc0004`, with one manifest,
  `503040d3eba0`. buildx attaches a min-mode SLSA provenance attestation by default, the
  containerd image store keeps it, and the image id is then the index over the image manifest
  and that attestation, whose `startedOn` and `finishedOn` change with every build; with
  `BUILDX_NO_DEFAULT_ATTESTATIONS=1` both builds were `503040d3eba0`. Compose was not misled:
  it records the platform manifest (label `com.docker.compose.image`) and left the gateway
  running in both cases, so the recreation came from the clock in `created`. The attestation
  held no build arguments (no canary in it): not a leak. It did record the clone's source path.
- **Next step:** a build without the cached layers (another builder, a pruned cache) still
  gives a new image, by design (the Ubuntu packages are upgraded again). RocketEdge's bake path
  still writes the build time (each published digest is signed and attested; it is never
  rebuilt in place). arm64 and the Windows kit's WSL path were not re-measured.

### 2026-11-17 — Review of #43: build records, the helper's own build, 5.1 quoting

- **What changed:** when a proxy variable's value holds `@`, both wrappers give the helper
  build and the image build a `--metadata-file`, read each build record's ref from it, delete
  it at once, and end the run (built or failed) with `docker buildx history rm <ref> <ref>`.
  The helper image's own build gets the proxy names as build arguments. `build-image.ps1`
  trims trailing separators from the cache directory. The helper's curl errors are shown with
  `://user:password@` replaced by `://***@`. README: where a proxy's password ends up (build
  records, also for `config.json` proxies; prefer a URL without credentials), Windows'
  case-insensitive variable names, a proxy reachable from the host and the containers, and why
  a rebuild has a new image id.
- **Result:** red first for each (bats and Pester; the 5.1 failure also reproduced for real:
  "Unable to find image 'cache:latest'" with `-CacheDir '...\ps cache dir\'`). Checked:
  `docker buildx history inspect <ref>` lists `HTTPS_PROXY` with its value, `history export`
  carries it, `docker buildx history rm <ref>` deletes the record (inspect then fails) and the
  image never held it. End to end through Squid, credentials in the URL, a fresh builder and
  the helper image removed first: Squid logged `CONNECT dl-cdn.alpinelinux.org:443` for the
  helper's `apk add` and every other request (262 in all), the build passed its smoke test in
  3 min 43 s, and the run ended naming two records, each holding the password four times,
  which the printed `docker buildx history rm` deleted. Windows PowerShell 5.1 with
  `-CacheDir '...\ps cache dir\'`: exit 0 in 73 s, smoke test passed.
- **What did NOT work / root cause:** "the values are not printed" was true of the scripts'
  output and the image, and the previous run checked only those; the build record, where
  BuildKit keeps every build argument, was not looked at. The helper image was built before
  the proxy names were collected, so a proxy-only network failed its first run. A new argument
  built from a user's path (`BROKERSRE_HOST_CACHE=...`) inherited 5.1's quoting of a final
  backslash, which the older `-v <path>:/cache` form had hidden behind its suffix.
- **Next step:** a proxy that requires authentication and a real corporate proxy remain
  untested; with `org.opencontainers.image.created` set per build, a rebuild now always has a
  new image id, so `docker compose up -d` after it starts a new login (README says so; a
  deterministic time, such as the commit's, would keep the id of an unchanged rebuild).

### 2026-11-17 — Build polish: stopped Docker, shell proxies, OCI labels, host paths

- **What changed:** both build wrappers ask the daemon for its version before anything else
  and, when it does not answer, say "the Docker daemon is not reachable" with the Docker
  context (exit 1). They pass `HTTPS_PROXY`, `HTTP_PROXY`, `NO_PROXY` and their lower-case
  forms, when set, to the helper container (`-e NAME`) and to the build (`--build-arg NAME`),
  names only. A helper build is labelled `org.opencontainers.image.created` (UTC, to the
  second) and `.revision` (the commit, `unknown` outside a git work tree), and the
  Dockerfile's `org.opencontainers.image.url` points at the README's "Build the image". The
  helper's messages name the cache and the `--installer` file by the host's paths
  (`BROKERSRE_HOST_CACHE`, `BROKERSRE_HOST_INSTALLER`), not by its mounts.
- **Result:** red first for each, in bats and Pester (daemon down with and without
  `--platform`; proxy values in the helper's environment and names in the build arguments, no
  value in any call or output; created and revision labels; host paths in three messages). End
  to end on Windows 11, Docker 29.9.3: through a local Squid proxy with a user name and
  password in the shell's proxy URL and a fresh BuildKit builder, `build-image.sh` built
  10.50.1h in 6 min 15 s; Squid logged 263 requests (IBKR, Ubuntu's archives, GitHub), and the
  password was in neither the output nor `docker history --no-trunc` nor `docker image
  inspect` (it was, though, in BuildKit's build records, which this run did not look at: see
  the entry above); the full container suite passed on that image (89 checks, incl. the new OCI label
  check, which failed on the image built before). From a fresh clone, cache hits: the `.sh`
  build in 1 min 13 s and the `.ps1` build (PowerShell 7) in 1 min 6 s, both labelled with
  the commit, both smoke tests passed. With `DOCKER_HOST=tcp://127.0.0.1:1` both wrappers say
  the daemon is not reachable, exit 1; offline `--strict` with an empty cache names the cache
  as `/c/Users/.../empty cache` (Git Bash) and `C:\Users\...\empty cache` (PowerShell), exit 3.
- **What did NOT work / root cause:** the first real Git Bash build labelled a clone with
  revision `unknown`: the script exports `MSYS_NO_PATHCONV=1` for docker's container paths, so
  `git -C /c/...` got a POSIX path Windows git cannot open; it now runs `git rev-parse HEAD`
  inside the checkout (a stand-in git in bats guards it; Linux never showed it). A Bash
  heredoc on this host halved the backslashes of a new test line, which then compared against
  `\${NEWER_X64}` unexpanded; the line was rewritten with the Edit tool and `bs='\'`.
- **Next step:** a proxy that requires authentication (Squid here accepted the credentials
  without checking them) and a real corporate proxy remain untested.

### 2026-11-17 — Review of #42: "not public" in generated text, the audit log's times

- **What changed:** `publish.yml`'s release notes and `detect-releases.yml`'s update pull
  request body say RocketEdge's image "is not public" instead of "private" (true for internal
  and private; owner step 1 is optional). The same wording goes into the comments of six
  workflows, the gate job and step names ("the package is not public", "still not public"),
  the placeholder's text, the gate's error message (change the visibility, never delete the
  package: a workflow would re-create it public), the header of
  `scripts/check-package-private.sh` (it proves "not anonymously readable", L40), the two bats
  files and the Windows kit's doc comment; ids, conditions and the script's output are
  unchanged. ADR 0018, this log and `tasks/todo.md` use the audit log's times (the refusal
  after the deletion held until the push at 08:10, public from 08:10:35 to 08:46:22, created
  again at 08:46:43) and name the token generically (a classic token with `write:packages`).
  Owner step 1 says to update L39 and the ADR's decision bullet when it is taken; the recovery
  block says to run it in bash.
- **Result:** the release-notes test now requires "is not public" and refuses "private"; bats
  `private-package`, `check-package-private`, `workflows` and `detect-scope` 58/58 on Linux;
  shellcheck, shfmt, actionlint 1.7.12 and PSScriptAnalyzer clean; markdownlint clean. zsh
  refused `read -p` ("no coprocess") and dash refused `read -s` ("Illegal option") in a
  container.
- **What did NOT work / root cause:** the first version of this pull request corrected the
  documents but left the generated text alone (release notes, update pull request bodies)
  because it lives in workflow files, which were out of scope then, although it is what a
  reader of a release or an update pull request sees; and it gave the hand re-creation an
  approximate time ("about 08:45") and a refusal "from then on" that the push at 08:10 had
  already ended.
- **Next step:** the owner's steps (1) to (5) in `tasks/todo.md`; a decision on L40.

### 2026-11-17 — The README and the upgrade policy say detection runs hourly

- **What changed:** README ("Upgrade policy", "Automatic updates and repository secrets") and
  `docs/upgrade-policy.md` step 1 describe what `detect-releases.yml` does since #40: it reads
  IBKR's `version.json` every hour at minute 23; the full check (both installers downloaded and
  hashed, `scripts/release-decision.sh`) runs in the daily run at 06:00 UTC, on a dispatch and
  in an hourly run at the first sight of a version (`scripts/detect-scope.sh`). The README says
  the run that creates an update pull request (hourly or daily) is the one that enables
  auto-merge, and that the workflow is disabled since 2026-11-17 until the package's access
  settings are done.
- **Result:** read against the workflow on `main` (`7841934`): `cron: "0 6 * * *"` and
  `cron: "23 * * * *"`, the scope step's condition and `detect-scope.sh`'s contract; markdownlint
  clean.
- **What did NOT work / root cause:** #40 changed the schedule and ADR 0018 but not the two
  user-facing pages, which kept "daily" (recorded as a follow-up in #40's entry).
- **Next step:** none for this text; `tasks/todo.md` keeps the follow-up on downloading less
  (`Last-Modified`, `Content-Length`).

### 2026-11-17 — Phase 4: the public package withdrawn, the package created again by hand

- **What changed:** documentation only, no workflow or script. ADR 0018 gets a dated
  amendment: what happened on 2026-11-17 (UTC) with the run ids, what GitHub did, the decision
  (the package is created by hand, once, never by a workflow of this repository; it is not
  public, private or internal; workflows reach it through "Manage Actions access"), the owner
  steps and the recovery path as commands; the spec gets a correction, L39 the outcome, L40 is
  new, `tasks/todo.md` records steps (0) to (c) as done and lists the remaining ones. The
  documents say that the former public package was withdrawn on 2026-11-17, that no RocketEdge
  image is published at the moment and that the next publish goes to a package ghcr.io does
  not serve anonymously, after two checks (README, SECURITY, NOTICE, evidence, upgrade policy,
  architecture, the Azure pack's and the Windows kit's READMEs, the contract files); the
  upgrade policy's rollback says the digests published until then are gone; the README's
  advice for a user's own GHCR package says a new package is not always private.
- **Result:** what happened: the public package was deleted at 08:09 (anonymous token request
  403 and API "Package not found" until the push at 08:10); `publish.yml` run 44044468594
  (08:10) re-created it PUBLIC with its placeholder push (08:10:35) and its job
  `private-package` failed at the anonymous-read check, `publish` skipped; at 08:46:22 the
  public placeholder package was deleted, and at 08:46:43 the package was created by hand with
  a personal token (internal, `check-package-private.sh` exit 0, no repository linked); run 44049788033 (08:47) failed at the placeholder push with
  `permission_denied: write_package`, `publish` skipped. The visibility gate worked as designed
  both times and no IBKR software was pushed. The state was read again before this entry was
  written: anonymous token request 401; the package API answers `visibility: internal`, no
  `repository`, three versions (the placeholder's index tagged `visibility-probe`, its
  linux/amd64 image and Docker's attestation manifest); the workflows "Publish", "Rebuild" and
  "Detect IB Gateway releases" `disabled_manually`. The recovery procedure's build and its push
  from a throwaway `DOCKER_CONFIG` ran against a local `registry:2`.
- **What did NOT work / root cause:** the plan assumed that a package created again after the
  deletion would be private and linked to this repository (spec, ADR 0018 Context item 4 and
  Phase 3, owner step (c)). GitHub gives a package that a workflow creates "the visibility and
  permissions model of the repository where the workflow is run", public here; the review of
  #40 had found that sentence and added the gate, which is why nothing leaked, but the owner
  steps still expected the workflow to create the package. The hand-made package has two
  properties nobody planned: a personal-token push into an organisation of a GitHub enterprise
  made it internal, which the gate cannot tell from private because it checks anonymous reads
  only (L40); and the `org.opencontainers.image.source` label, which GitHub documents as the
  way to link an image before publishing, did not link it (cause not established), so the
  workflow's token was refused until the package's Actions access grants the repository.
- **Next step:** the owner's steps (1) to (5) in `tasks/todo.md`; a decision on L40 (a gate
  that reads the visibility setting); the comments in the workflows, a bats file and the
  Windows kit that still call the package private or "being withdrawn", with the next change
  to those files.

### 2026-11-17 — Re-review of #41: no credentials in the WSL copy or the build context

- **What changed:** the Windows kit's WSL build packs a named list of what
  `scripts/build-image.sh` reads (Dockerfile, `.dockerignore`, `versions.json`, `rootfs/`, the
  build, resolve and fetch scripts, `scripts/build-helper/`, `tests/container/run.sh`) instead
  of the whole checkout, removes the archive right after unpacking and gives each copy step an
  explicit 120 s deadline. `.dockerignore` also excludes `**/secrets`, `**/.env` and
  `**/*.env` after its re-includes. The leftover advice quotes the host path for its shell
  (bash `'\''`; PowerShell doubles `'` and the typographic quotes it treats as `'`). The README
  says the paper-qualified digests came from the former public package (not "before the image
  became private") and lists the kit's WSL installer cache. Merged `origin/main` after #40.
- **Result:** red first, then green: four Pester tests of the copy failed on the old code (it
  packed `.` and kept the archive; 11 of 11 in the context pass under PowerShell 7 and 5.1); a
  copy holding only the list (348,160 bytes, 32 files; planted credentials, `.env` files,
  `.venv` and `downloads/` absent from the archive) built with `scripts/build-image.sh` (exit 0,
  IBC smoke test passed); `build-context.bats` exported what BuildKit received: a top-level
  `compose/secrets` and `.env` never left the checkout (held before), but `rootfs/secrets/`,
  `rootfs/.env` and `rootfs/etc/*.env` did until the new rules; the two quoting tests failed
  on the old advice (the printed `rm` did not parse) and pass, and the PowerShell command
  removed the file in a folder named with all five quote characters (PowerShell 7).
- **What did NOT work / root cause:** the first WSL copy excluded what it knew to be large
  (`.git`, `downloads/`, the bats checkout) instead of naming what the build needs, so every
  untracked file of a used checkout went along, credentials included, and a killed setup left
  them in the distribution's `/tmp`. Excluding is open-ended; naming the inputs is closed. A
  `docker run -v <missing file>:...` for gitleaks created an empty directory `.gitleaks.toml`
  in the worktree, which then failed the gitleaks pre-commit hook ("Config File .gitleaks Not
  Found"); removed. The merge was pushed before the local PSScriptAnalyzer run had finished;
  CI's analyzer failed on a line of the new WSL test longer than 200 characters
  (PSAvoidLongLines), fixed in the next commit: wait for the analyzer before a push.
- **Next step:** CI on the merge; a real WSL distribution for the kit's copy-and-build path
  (still mocked).

### 2026-11-17 — Review of #41: image modes, the kit's WSL build, wording that stays true

- **What changed:** the Dockerfile sets owner (root) and mode of everything `rootfs/` brings in
  and of the directories COPY passes through (directories and scripts 0755, other files 0644);
  the container suite checks them. The Windows kit builds with Docker Engine in WSL from a copy
  of the tree in the distribution's own file system, never from `/mnt/c`. The helper's refusal
  of a leftover in `downloads/` names the caller's removal command, the host path and the
  caller's option (`--installer` or `-Installer`), told by the wrappers. The docs say that
  RocketEdge no longer distributes a public image and that the former package is being
  withdrawn (true before and after the deletion; a follow-up switches to the past tense),
  define `qualified_by_project: yes` as "the version and installer equal the pin, which passed
  the project's offline CI" (a paper login is separate; the Going-live checklist now asks for
  one), give the migration steps for users of the former public default (compose and the
  kit), Compose 2.22.0 for `pull --policy` with `docker pull` as the alternative, the arm64
  installer size, the current cache line, `MSYS_NO_PATHCONV=1` for the syft command, and a CI
  example with job-level `packages: write` and `persist-credentials: false`.
- **Result:** red first, then green: the rootfs check failed on the image built from Windows
  (templates 0755) and passed after the change on a helper build and on a build from a 0777
  context (both full container suites, 88 checks); five Pester tests of the WSL path failed on
  the old code and pass (650 under PowerShell 7 and 5.1); three bats tests and one Pester test
  of the advice failed on the old message and pass (bats 61, Pester 31 under both editions).
- **What did NOT work / root cause:** a build context with mode 0777 (what drvfs shows for a
  WSL checkout under `/mnt/c`) did not only make the templates writable: COPY into `/` gave
  `/etc`, `/usr`, `/usr/local` and `/usr/local/lib` mode 0777 and the host's uid, because COPY
  updates the metadata of existing directories on its path. The first wording of phase 2 said
  the image "is private" and "RocketEdge publishes no image", which is not true while the
  public package can still be pulled; and it called `qualified_by_project: yes` a build "the
  project has logged in with", which a stable pin that merged itself after CI is not.
- **Next step:** merge after CI; delete the public package (Phase 4); then the past-tense
  follow-up with the proof; a real WSL distribution for the kit's build path.

### 2026-11-17 — The build recipe and local defaults (ADR 0018, phase 2)

- **What changed:** the README starts with "Build the image", a recipe for every host (what
  you need, measured time and disk, one command per shell and what it prints, the seven
  result lines and `qualified_by_project: no`, the latest channel, arm64, proxies, the
  installer cache and `--installer`, pinning, private registries, a GitHub Actions example,
  upgrade and rollback, troubleshooting); the quick start starts with the build, and the
  verifying, notification and upgrade-check sections describe a self-built image. The
  reference compose, the multi-gateway file and the client example default to
  `brokersre-ib-gateway:stable` with a literal `pull_policy: never`; the Azure VM overlay pulls
  the digest its userData names (`pull_policy: missing`). The Windows kit's `setup.ps1`
  defaults to the same tag and builds a missing `stable` or `latest` image with
  `scripts/build-image.ps1` (Docker Engine in WSL: `bash scripts/build-image.sh`) before it
  starts anything. `docs/evidence.md`, `docs/upgrade-check.md`, `docs/upgrade-policy.md`,
  `SECURITY.md`, `NOTICE.md`, the gnzsnz table, `azure/README.md` and the `gatewayImage`
  descriptions no longer send a reader to a public image. L37, L38. After #39 was merged
  with the review's cache layout (`installers/<version>/<arch>/<sha256>/`, `source`), the
  README shows where the installer cache lives per host and script, how to list it and how to
  delete entries safely (nothing prunes it), and `resolve-installer.sh`'s refusal of other
  bytes at the installer's place in `downloads/` names the likely leftover of an interrupted
  or parallel build and its removal in bash and PowerShell (test first).
- **Result:** every documented command ran on Windows 11 with Docker Desktop 29.9.3 (Git Bash,
  PowerShell 7.6, Windows PowerShell 5.1), from a clone of the pushed branch where it says so
  in the pull request. A first build with nothing cached (a new buildx builder, an empty
  installer cache) took 9 min 1 s, about 3 min of it downloading IBKR's 360,312,436-byte
  installer; a rebuild with both caches warm 1 min 14 s; the image is 1,622,526,158 bytes,
  the build cache 3.55 GB, an installer 344 MiB. IBKR's `stable` served 10.50.1h against the
  pin 10.50.1g (`qualified_by_project: no`), `latest` served the pinned 10.52.1d (`yes`).
  arm64 under emulation built and passed the IBC test in 8 min 53 s. A local Squid proxy
  showed that the Docker CLI's `config.json` proxies reach the helper's download and the
  build's `RUN` steps, and that `HTTPS_PROXY` in the shell reaches neither. Tests: the compose
  suite 76 checks (8 new: defaults, `--no-interpolate`, a missing image fails without a
  pull), the Azure pack's bicep, lint, compose and secrets groups 120 (2 new), Pester 646
  under both editions (33 new cases), PSScriptAnalyzer 0 findings, sidecar `test_docs.py`
  238, markdownlint clean, actionlint 1.7.12 on the CI example, a local registry (`registry:2`)
  for the push, `pull --policy missing` and `up --pull missing`.
- **What did NOT work / root cause:** `pull_policy: ${IBGW_PULL_POLICY:-never}` (a variable,
  so RocketEdge's digest deployments could pull) fails `docker compose config
  --no-interpolate`, which `sidecar/tests/test_docs.py` runs on every shipped file: compose
  validates the key's pattern before interpolation. The policy is a literal, and a pull is an
  explicit `pull --policy missing` / `up --pull missing`, which override it (compose 5.7.0).
  The Windows template's first form, a `__PULL_POLICY__` placeholder, failed the same test
  for the same reason; the template keeps the literal line and the renderer replaces it.
  Before the change `up` with a missing local name tried to pull it (`Pulling`, then a Docker
  Hub error), which the new compose test caught red. In Windows PowerShell 5.1,
  `--format '{{index .Config.Labels "x"}}'` reaches docker without its inner quotes
  (`function "com" not defined`); the PowerShell commands read the labels as JSON. The first
  registry recipe read the digest to pin as `{{index .RepoDigests 0}}`, which printed the
  local name's digest on Docker Desktop (its containerd image store lists one repo digest per
  repository name); it is taken from the push output now. Removing a digest reference of the
  local repository in the test (`docker rmi brokersre-ib-gateway@sha256:...`) took the
  `stable` tag with it on that store; the test removes only registry names now. The cache
  written before the review's layout change (files directly in `installers/<v>/<arch>/`) is
  not read by the merged helper: the first build after the merge downloaded again, and the
  README says to delete such files. Found
  while documenting, not fixed here (scope of #39): the PowerShell wrapper reports "the Docker
  host's architecture '' is not supported; pass -Platform" when Docker is not running; neither
  wrapper forwards `HTTPS_PROXY`; a helper build carries the Ubuntu base image's
  `org.opencontainers.image.created` and no revision label; messages name the helper's
  `/cache` path. The optional Azure VM cannot log in to a private registry (L37), and a
  TLS-inspecting proxy cannot be given a CA certificate (L38).
- **Next step:** phase 3 (private publishing, hourly detection, CI without anonymous pulls,
  workflows re-enabled), phase 4 (delete the public package); L37 before anyone deploys the VM
  with a private image; a paper login with a self-built 10.50.1h image (L35).

### 2026-11-17 — Workflows ready for a private gateway package (ADR 0018, phase 3)

- **What changed:** CI's `build-test` and the sidecar's end-to-end job test the image they
  build with `scripts/build-image.sh` under the local name `brokersre-ib-gateway:stable` (was
  `ghcr.io/rocketedge/brokersre-ib-gateway:stable`); CI's three Trivy steps read the local
  daemon only (`TRIVY_IMAGE_SRC=docker`); the end-to-end job lost its archive pre-fetch, its
  bake build and its fork condition, and its trigger paths name the build helper's inputs.
  `rebuild.yml`'s daily scan and `qualify-paper.yml` log in to `ghcr.io` before their first
  read (the qualification once, before the pull, instead of only for the attestation).
  `publish.yml`'s release notes no longer say "Pin this exact build": they tell readers to
  build from the tag and name the digest as RocketEdge's private image. `detect-releases.yml`
  runs hourly (`23 * * * *`) besides 06:00 UTC; `scripts/detect-scope.sh` decides whether a
  run downloads and hashes (daily, dispatch, first sight of a version) or stops after
  `version.json`. ADR 0018 records these and that stable bumps keep merging themselves; L39.
  Review of the pull request (same day): `publish.yml` gets a first job, `private-package`,
  that pushes a placeholder without IBKR content and requires ghcr.io to refuse an anonymous
  token request for it (`scripts/check-package-private.sh`) before `publish` may start, and
  `publish` repeats the check right before its push. Re-review: the first version also read a
  manifest 401/403/404 after a granted token as private, but ghcr.io answers token 200 and
  manifest 404 for a public package's missing tag (observed 2026-11-17); a granted token now
  counts as inconclusive unless the manifest is 200 (public). Tests now catch the gate step
  passing on exit 3 and `continue-on-error` on the gate; the qualification
  logs in and pulls before the credential files exist (login pinned by commit);
  `qualified_by_project: yes` is defined as "equals the pin, which passed the offline CI, not
  a paper login" in both build scripts' help, the spec, ADR 0018 and L35; detection runs in
  one concurrency group per kind of check (full, hourly), retries `version.json` briefly, and
  counts only this repository's update pull requests; three surviving mutations got tests.
- **Result:** `tests/bats/ci/private-package.bats` (9 tests) and `detect-scope.bats` (11)
  were red on `main` for the reasons above (two are guards of properties `main` already had)
  and are green; `workflows.bats` stays green; actionlint 1.7.12 clean. CI and Sidecar runs
  of the pull request: see its description. After the review: 13, 15 and 7 tests
  (`check-package-private.bats` new), each new one red first (the guards against the review's
  mutations M3, M7 and M9 red with the mutation applied to the real workflow); the `--help`
  tests in bats and Pester (Windows PowerShell 5.1 and PowerShell 7) red first.
- **What did NOT work / root cause:** `rebuild.yml`'s daily scan read the channel tag
  (`docker buildx imagetools inspect`) and scanned with `TRIVY_IMAGE_SRC=remote` without a
  login: against a private package it would have failed every day. `qualify-paper.yml` logged
  in only to attach the attestation, after `docker pull`. CI tagged its own build with the
  public package's name, so a Trivy fallback to its remote source (Trivy's default order ends
  with `remote`) could have scanned the published image instead of the build. A first draft
  of the visibility test grepped whole workflow files and failed on the comment that says no
  workflow sets one; it now reads step scripts and inputs only. Hourly detection with the full
  check every hour would have downloaded about 27 GB a day from IBKR (565 MB per channel per
  run) and reopened a closed pull request within the hour instead of the next day (ADR 0009).
  The first version assumed that a package created again would be private; GitHub documents
  that a package created with a workflow's token inherits the visibility model of the
  repository (public here), and only one earlier run saw the opposite, so the visibility is
  now proven before any IBKR byte is pushed. A single concurrency group would have let an
  hourly run replace a daily run that GitHub started hours late.
- **Next step:** the owner's steps in `tasks/todo.md` (delete the public package, re-enable
  the three workflows, publish both channels, check the package is private and grant read
  access); the first publish after the deletion is what proves the private path (L39). After
  the build-recipe pull request merges, the README and `docs/upgrade-policy.md` still say the
  detection is daily.

### 2026-11-17 — Review of #39: cache provenance and key, the user's files, the trust tests

- **What changed:** the helper's cache is keyed by version and SHA-256
  (`installers/<v>/<arch>/<sha256>/`) and records each entry's source (`ibkr`, `installer`,
  `override` for the tests' server); a non-pinned version is reused, online or offline, only
  from the origin of the current run, and bytes given with `--installer` serve only as the pin
  when their SHA-256 is the pin's. The image gets `com.rocketedge.brokersre.installer.source`
  (bake: `ibkr`). A file already at the build context's installer path is the user's: the same
  bytes are used and kept, other bytes stop the build (exit 1); the wrappers remove only what
  they put there. Redirects must lead to HTTPS also under the test override. A docker failure
  of the helper run (125-127) is exit 1 in both wrappers. The stamp reader stops at
  `i4jparams.conf`. CI prints a notice for an unqualified build. Spec, ADR 0018, README and
  both contract files: exit 3 is "IBKR unreachable and no usable cached installer", and the
  fall-forward takes any version other than the pin (IBKR may roll a channel back).
- **Result:** the review's probes, each now a test that was red first: a user's third-party
  copy stamped like IBKR's 10.50.1h was built instead of IBKR's download (no request to IBKR)
  and is now ignored by a build IBKR answers; an `--installer` copy of the pinned version with
  other bytes replaced the cached pin (offline `--strict` then exit 3) and now sits beside it;
  `--installer downloads/<name>` lost the user's file after a successful and after a failed
  build and now keeps it; `docker run` exit 125 was passed on and is now 1. Mutations of the
  helper (the review's ten, rewritten for the new code, and three for the new checks), each
  run against `build-image.bats` and `fetch-installer.bats`:

  | # | Mutation | Before the review | Now |
  |---|---|---|---|
  | m1 | no second read of `version.json` | caught | caught (4 tests) |
  | m2 | cache reuse without re-hashing | missed | caught |
  | m3 | helper stamp compared by suffix only | caught | caught |
  | m4 | before/after compared by version only | missed | caught |
  | m5 | `--proto-redir` dropped | missed | caught (2) |
  | m6 | cache hit without the stamp | missed | caught |
  | m7 | offline pin found without the pin's SHA-256 | missed | caught |
  | m8 | `qualified` from the version alone | missed | caught (2) |
  | m9 | `fetch-installer.sh` stamp compared by suffix only | caught | caught |
  | m10 | no format check of `version.json` fields | missed | caught |
  | m11 | cached newer version reused from any origin | (new) | caught (3) |
  | m12 | offline fallback from any origin | (new) | caught |
  | m13 | wrapper removes the user's `downloads/` file | (new) | caught (2) |

  `--installer <real 10.50.1h> --print-plan` through the Windows bind mount (stamp and
  SHA-256) takes 12.8 s; the stamp read alone took 3.5 min in the review.
- **What did NOT work / root cause:** the first suite tested that each check accepts good
  input and refuses the one bad input the author thought of; the review's mutations show that
  a check can be weakened in ways no test exercised (a field compared in part, a criterion
  dropped from a lookup). The provenance gap came from treating "the same stamp" as "the same
  bytes from the same place". The redirect check could not be tested because the override
  relaxed redirects together with the first request.
- **Next step:** mutate any trust check that changes and watch a test fail (both contract
  files say so); phase 2 builds on this branch.

### 2026-11-17 — A build that survives IBKR replacing its installers (ADR 0018, phase 1)

- **What changed:** `scripts/build-image.sh` and `scripts/build-image.ps1` build the image on
  any host with Docker; `scripts/resolve-installer.sh` decides, downloads, verifies and caches
  the installer inside a helper container (`scripts/build-helper/Dockerfile`, Docker CLI
  pinned by digest). When IBKR serves another version than the pin the build falls forward:
  IBKR's `version.json` must be the same before and after the download (one retry), the
  installer's stamp and the installed stamp must equal it, and the image is labelled
  `com.rocketedge.brokersre.qualified=no` (`--strict`: exit 4). `fetch-installer.sh
  --check-stamp` fails a Dockerfile build whose installed `applicationVersion` or version
  differs from `IB_GATEWAY_BUILD_STAMP`; the bake path passes the pinned stamp from
  `build_datetime`. New labels `ibkr.version`, `ibkr.build_stamp`, `installer.sha256` (per
  platform, through one label stage per architecture) and `qualified`.
  `tests/container/run.sh --only ibc-smoke` runs the IBC smoke test alone (secrets from a
  volume). CI's `build-test` builds with the helper, without the private archive. Spec,
  ADR 0018 (amends 0007 and 0009), L35, L36.
- **Result:** the first red: a clean build of `main` (bake arguments of `versions.json`)
  failed at 02:05 UTC with `fetch-installer: SHA-256 MISMATCH for
  ibgateway-10.50.1g-standalone-linux-x64.sh`, actual `eb578b23…`, which is IBKR's 10.50.1h.
  With the helper on live IBKR: Git Bash built 10.50.1h in 4 min 40 s (download, build, smoke
  test), `qualified_by_project: no`, warning printed; the image's configuration equals the
  published 10.50.1g image's apart from the version, and the full container suite passed on
  it (86 checks, including the new label check, which fails on the published image). Tests:
  29 bats tests of the helper against a fake IBKR server (five mutations the author chose, of
  the before/after check, `--strict`, the stamp comparison, the pin check and the cache
  fallback, each failed them; an independent review's ten mutations then found seven that
  passed the suite: see the entry above),
  3 Dockerfile-level stamp tests with fake installers, 10 unit tests of the stamp reader,
  3 bake tests, 25 Pester tests under Windows PowerShell 5.1 and PowerShell 7.
- **What did NOT work / root cause:** PowerShell's binder ends a script with exit 1, before
  it runs, when a parameter is given without its value, so typed parameters could not keep
  exit 2 for usage errors: `build-image.ps1` parses `$args` itself. Pester: `$script:` inside
  a function defined in `BeforeAll` did not reach the variables the mocks wrote (eight tests
  passed or failed on nothing), and `return @(...)` unrolled an array of calls so that `[0]`
  was the first argument. `docker build` of the helper with a `docker-container` default
  builder would have kept the image in the build cache only: the helper is built with
  `buildx build --load`. `git -c core.autocrlf=false clone` of bats-core still checked out
  CRLF on Windows (bats-core's `* text=auto` follows `core.eol`); the documented command now
  sets both. `BATS_TEST_TIMEOUT` exported from `setup_file` left all three Docker tests
  waiting on bats' `sleep` watchdog after their builds had finished (not isolated; not used).
  A failed resolve first left its 360 MB download in the cache for a day; it now removes it.
  In CI the process-level Pester test failed under both editions: with `$ErrorActionPreference
  = 'Stop'` a Windows PowerShell 5.1 host makes `& exe 2>$null` throw on the first stderr
  line; it uses `Start-Process` with file redirection now. CodeQL flagged the fake IBKR
  server (`py/path-injection`); it now serves only resolved paths inside its root.
- **Next step:** phase 2 (README recipe, compose defaults to the local tag, Windows kit builds
  a missing image), phase 3 (private publishing, hourly detection), phase 4 (delete the public
  package). A paper login with a self-built 10.50.1h image would qualify it (L35).

### 2026-11-17 — The published sidecar 0.2.2 against a paper login (L20)

- **What changed:** documentation only: L20 records what the published sidecar 0.2.2
  (`sha256:a7372f1f…`) did against a logged-in paper Gateway on 2026-11-16 21:01 to 21:34 UTC,
  and that all three sidecar workflows have now run.
- **Result:** with Teams unreachable next to a working webhook, a stop and start of the
  gateway sent `firing` and then `resolved` to the webhook; after a hard kill of the sidecar
  right after the webhook got `firing`, the restarted sidecar sent the `resolved` it owed (the
  defect 0.2.2 fixed). A self-hosted ntfy server received `notify test`, whose runbook link is
  now the index, and `gateway_stopped` with its `resolved` 4 s apart. No username or
  account-shaped word in any container log or message. The README's `//var` phase command
  (#37) returned `logged-in`, exit 0, in Git Bash and PowerShell 7.6 against a logged-in
  Gateway (23:27 UTC); the single-slash form failed in Git Bash, as #37 states.
- **What did NOT work / root cause:** nothing new; L20 had still said the weekly rescan never
  ran, but it ran on schedule on 2026-11-16 17:01 UTC (success, on 0.2.1).
- **Next step:** one test message per channel to the real services (Teams, Slack, Telegram,
  PagerDuty, e-mail, ntfy.sh) when the owner provides targets; a rescan of 0.2.2.

### 2026-11-17 — Re-review of #37: zsh's "without bracketed paste" tests ran with it on

- **What changed:** `pty-answers.py` loads zle (`zmodload zsh/zle`) before `unset
  zle_bracketed_paste` in the test's `.zshrc`. Before pasting it now checks, for every shell,
  that the bracketed-paste mode the shell switched on (`ESC[?2004h` on the screen) is the one
  `--bracketed-paste` asks for, and otherwise pastes nothing and fails; the Ctrl-C tests ask
  for `off` in sh. New test: the driver against stand-in shells that show the other mode.
- **Result:** with the fixed driver the four zsh "without bracketed paste" tests fail on the
  blocks of the first review round (`254f448`, no subshell) and pass on the subshell blocks;
  with the driver of `761517a` they had passed on both, and the new guard test fails there.
- **What did NOT work / root cause:** `zle_bracketed_paste` belongs to the zle module; the
  `unset` in `.zshrc` ran before zle was loaded and zle set it again at the first prompt.
  Ubuntu's `/etc/zsh/zshrc` had loaded zle earlier, so the tests were right until `f57f6e2`
  skipped that file (`GLOBAL_RCS` unset), and nothing checked the mode the shell was in.
  The comment of `f57f6e2` also said that no host start-up file runs: zsh still reads
  `/etc/zsh/zshenv` and bash `/etc/bash.bashrc`; the comments now say so.
- **Next step:** none planned; a start-up file that changes the mode now fails the test
  instead of weakening it.

### 2026-11-17 — Review of #37: pasted secret blocks, Ctrl-C, the C# wording

- **What changed:** the independent review of pull request #37 pasted each secret block in
  one write into an interactive shell and then typed the answers. Each of the four blocks
  (README quick start, `compose/README.md`, `docs/console.md`, `docs/recipes/README.md`) is
  now one subshell `( ... )` whose first line is `trap 'stty echo; exit 130' INT`; `unset`
  is gone (the variables live in the subshell). `pty-answers.py` gained a paste mode (an
  interactive shell with its own start-up file, the block in one write, the bracketed-paste
  markers only while the shell has that mode on, Enter when nothing runs), an `interrupt`
  answer (Ctrl-C), a history check and a `stty -a` check at the shell's prompt;
  `doc-commands.bats` pastes each block into bash and zsh with bracketed paste off and on
  and into sh, and presses Ctrl-C at the first password prompt. The README and
  `examples/csharp` now both say the `CSharpAPI.dll` was built locally from IBKR's TWS API
  10.48.01 source. `origin/main` (#32) was merged in.
- **Result:** on the blocks of the first review round the new cases failed as the review
  found: pasted without bracketed paste (bash and zsh with it off, dash) 12 of 12 failed
  (the first `read` took the next pasted line; the typed password was shown and saved in
  the history), Ctrl-C at the password prompt left echo off (4 of 4 failed), and the 4
  cases with bracketed paste on passed. With the subshells all 39 tests of
  `doc-commands.bats` pass (Ubuntu 24.04: bash 5, zsh 5.9, dash), and the whole
  `tests/bats/ci` 310 of 310 after the merge. By hand, outside CI: in the `bash:3.2` image
  (macOS's bash version; busybox sh) every block pasted and answered gave the exact bytes,
  and Ctrl-C wrote no password file and left echo on (16 of 16).
- **What did NOT work / root cause:** without bracketed paste (dash, busybox sh, bash 3.2,
  or bash and zsh with it switched off) a shell reads and runs a pasted block line by line,
  so the lines not yet run wait in the terminal's input and the first `read` takes one;
  a compound command is read whole before it runs. The first round tested each block as a
  script only, where that cannot happen. Rejected: braces with a note to run `stty echo`
  after Ctrl-C (bash and dash left echo off), and braces with `trap 'stty echo' INT` (after
  the trap the shell went on and wrote the password file: 7 bytes of the next typed line in
  bash and zsh, an empty file in dash). A subshell confines the trap and its `exit`. The
  first push of the new tests failed on the GitHub runner only: Ubuntu's `/etc/zsh/zshrc`
  runs `compinit`, which found an insecure directory there and waited at "Ignore insecure
  directories and continue [y] or abort compinit [n]?", so the test's zsh never showed its
  prompt (12 zsh cases). Reproduced locally with a world-writable
  `/usr/local/share/zsh/site-functions`; the test's zsh now unsets `GLOBAL_RCS` in its own
  `.zshenv`, so no host start-up file runs.
- **Next step:** a Mac with Terminal.app or iTerm2 was not used; their paste settings are
  not modelled beyond bracketed paste on and off.

### 2026-11-17 — The README's examples, run as written: the secret blocks, Git Bash paths and the C# record

- **What changed:** on 2026-11-16 UTC the README's examples were run as written, on a Windows
  11 host with Docker Desktop, against a logged-in paper Gateway (the published stable image
  `7773ff7`, IB Gateway 10.50.1g). Five defects were found (D1 to D5); four are fixed here
  on 2026-11-17, and D4, `docker compose run` without `-f` in `sidecar/README.md`, is handled
  in pull request #32. D1, D2: the blocks in which a person types a secret into a POSIX
  shell (the quick start, `compose/README.md`, the console's VNC password, the Loki recipe)
  now print the prompt with `printf`, wrap `IFS= read -r` in `stty -echo` / `stty echo` and
  write with `printf '%s'`. D3: every documented `docker exec` / `docker compose ... exec`
  command writes the container path as `//var/...`, with a note in the README,
  `compose/README.md` and the runbooks' command table; `docs/evidence.md` keeps its recorded
  commands and tells Git Bash users to `export MSYS_NO_PATHCONV=1`. D5: the README and
  `examples/csharp` record that the C# client (`connected to 127.0.0.1:4002, client id 101`, IBKR's server time every
  30 s, 08:18:58 to 08:20:09 UTC) and `examples/compose-with-client.yml` (gateway healthy
  after 12 s, then the strategy's handshake answered, server version 178) ran against that
  Gateway. The README and `docs/passkeys.md` cite IBKR's "Auto Restart Considerations" for
  the weekly login ("each Sunday at 1:00 am ET"), keeping the "every Monday" page and IBC's
  guide as the disagreeing sources. New test `tests/bats/ci/doc-commands.bats` (with
  `pty-answers.py`, `doc-block.awk`, `doc-exec-paths.awk`), run by the lint job, which now
  installs zsh.
- **Result:** before the fixes, 12 of the 12 secret-block cases failed in Ubuntu 24.04 (bash:
  the blanks at both ends of the typed value were dropped; zsh 5.9: `read: -p: no coprocess`,
  no file; dash: `read: Illegal option -s`) and the exec-path check reported 13 paths in the
  README, `compose/README.md` and the runbooks; after them all 19 tests pass, under gawk and
  under mawk. `//` was checked on 2026-11-17 with throwaway containers: from Git Bash
  (`docker exec` and `docker compose exec` with cat, tail, grep and df; the single-slash form
  failed there), PowerShell 7, and busybox sh running the docker CLI in `docker:29-cli`; GNU
  coreutils of ubuntu 26.04, the gateway's base, read the paths. `export MSYS_NO_PATHCONV=1`
  was checked for `docker exec` and for `docker run -v "$PWD/...:/run/secrets:ro" -e
  NAME=/run/...` in Git Bash.
- **What did NOT work / root cause:** D1: `read` without `IFS=` strips IFS whitespace at both
  ends of the line, and no check had typed a value with blanks at either end. D2: `read -p`
  means "read from the coprocess" in zsh, and dash has no `-s`; the block was bash-only and
  had only been run in bash, although the README offers it for macOS, whose default shell is
  zsh. D3: Git Bash's MSYS layer converts an argument that starts with one `/` (and
  `NAME=/...`) to a Windows path before `docker` sees it; the commands had been run on Linux
  and in PowerShell only. Rejected for D3: a `MSYS_NO_PATHCONV=1` prefix in the command
  (PowerShell cannot run it), a note alone (Git Bash readers still copy the failing line),
  `sh -c '...'` around the command (works, but longer and needs quoting in every shell). D5:
  the "stand-ins only" sentence was true when written and was not updated when the run
  happened: a statement about what was verified needs revisiting after each real session.
- **Next step:** the test runs each block as a script through a pty, not as an interactive
  paste: a terminal without bracketed paste would feed the following lines of a pasted block
  to `read`, and no Mac (bash 3.2, zsh) was used. The exec-path check reads one line at a
  time and does not look at `docker run`; `docs/evidence.md` relies on its note.

### 2026-11-16 — A "resolved" is no longer lost when an alert clears while it is being sent (sidecar 0.2.2)

- **What changed:** in the first session of the published sidecar 0.2.1 next to a logged-in
  paper gateway (two channels: a webhook to a local receiver, Teams with an unreachable
  URL) the gateway container was stopped and started. `gateway_stopped` was queued for both
  at 01:56:51.842 UTC and the webhook received it at once; the phase was `starting` at
  01:56:54; Teams gave up after 4 attempts at 01:57:00.123; `logged-in` at 01:57:04. No
  "resolved" was ever queued, although a person had been told. Now the dispatcher reports
  a message as delivered at the first channel that accepts it; the ladder keeps an episode
  that clears while one of its messages is out and decides its resolution when the result
  arrives (sent if any message of it was accepted, also when a new episode of the class
  began meanwhile); while such a result is outstanding nothing new is sent for that class;
  an escalation still out when the condition clears now gets its resolution on the
  escalation channels too. Notifier state `brokersre.sidecar.notifier-state.v3` (in-flight
  marks, closing episodes); a v2 file is read. Released as sidecar 0.2.2. The `clock_skew`
  false alert reported the same day was checked and does not exist (point 5); the rule is
  unchanged, its detection band is now pinned by tests and documented. Two rounds of
  independent review added, each test-first: a late "resolved" carries the phase, API
  status and time of its clearing (it was rendered with the next episode's facts), says
  whether a result came back or a restart lost it, and says "active again since" when the
  class is back; if it was the announcement that was accepted late, the new episode is
  announced right after it instead of 15 minutes later, at most once per window and class
  (a late escalation result moves no window); the state is saved once more after the
  flush at a stop, that final save waits for a write still running, logs
  `notifier_state_unsaved` when it cannot, and collects the error of an interrupted write;
  the log shows a resolution that waits for a result (`notify_resolution_waiting`, then
  `notify_resolution_decided` before the "resolved" is queued). A rule of the first round
  was reverted in the second, see (7). A third round added: the state of an evaluation is
  written before its messages are queued (bounded by the save timeout; queued anyway, and
  logged as `notify_queued_unsaved`, when the write fails or the stop interrupts it); a
  message a v2 file of 0.2.1 shows not delivered counts as possibly received; both
  sidecar compose files give the sidecar `stop_grace_period: 20s`. A fourth round: a stop
  that interrupts that write logs `notify_queued_at_stop` (information) instead of the
  warning, and a test pins that memory mode logs neither; the README's channel check
  commands name their compose files (copied as written they stopped with "no
  configuration file provided", seen 2026-11-16) and the README says what
  `docker compose ...` stands for, kept so by a test over the README and the runbooks. A
  fifth round: a test message links the runbook index (its link `<base>/test` led to a
  page that does not exist, seen 2026-11-17 through a local ntfy server), and a final
  save at the stop that fails like the write before it logs `notifier_state_unsaved`
  (it logged nothing). Also an end-to-end
  check that raced (it read the phase once right after `docker stop`) now waits for
  `stopped`.
- **Result:** the tests added for defect 1, as first committed, measured against the 0.2.1
  source: 15 fail (13 new tests, and 2 existing ones whose state schema string changed),
  56 pass. End to end, 0.2.1 gave the webhook `firing` only and PagerDuty `trigger` only,
  now `firing` + `resolved` and `trigger` + `resolve` under one `dedup_key`. A property
  test (400 examples) feeds results late, out of order and across restarts, each restart
  resuming from the state saved after the last evaluation (results that came back after
  it are lost, as with a hard kill): every episode someone heard of is resolved once, none
  other is, the messages of a class never go out of episode order, and inside the
  de-duplication window only an episode a late resolution found active is announced, at
  most one per window. Of the first review's 34 mutants, 33 are killed by the suite (M13,
  M14, L3, M22 and the older M21 by new tests; M10 and M11 by tests made sharper after a
  first run left them alive; M7 once a redundant second guard was removed), and M12
  mutated that guard, which no longer exists. Of the second review's 21, all 15 that still
  apply are killed (R3, R5 and R11 by new tests); the other 6 mutated the reverted
  "begun" machinery. Of the third review's 15, 14 are killed by the suite; the 15th
  dropped a log call that writing the state before queueing had made redundant, and that
  call is gone. The 6 mutants of the third round's own changes are each killed. Of the
  fourth review's 9, the 7 that still apply are killed; the one that swallows the stop's
  cancellation hangs the whole suite (an earlier test waits for a stop that never ends)
  and fails `test_notifier_service.py` run on its own. Sidecar
  suite 879 to 986 passed (2 skipped). Against a real paper login (2026-11-16, 06:32 to
  06:34 UTC, a local build of this branch at `773d21f`, the stable gateway `7773ff7`,
  fresh volumes, Teams unreachable, a local webhook): a graceful stop and start of the
  gateway queued `firing` at 06:32:51.083 and `resolved` at 06:32:53.100 while Teams
  still retried (it gave up at 06:32:58.120), and the webhook got both; with the sidecar
  killed (SIGKILL) 0.5 s after the webhook got `firing` and the gateway restarted, the
  restarted sidecar queued `resolved` at 06:33:55.550 to the webhook and Teams, and the
  webhook got it. Neither run put a username or an account-shaped value in any output.
  Clock skew: the reported case (host 0.3 s ahead of a correct IBKR clock, truncated
  readings in (−1.3, −0.3]) and the session's readings (−0.92, −1.77, 0.124 s) never
  alert; with the comparison the report assumed (`|reading| > 1 s + RTT/2`) eight of the
  new tests fail.
- **What did NOT work / root cause:** (1) *A message's outcome was its slowest channel's.*
  `_Delivery.settle` called back once every channel had finished, so the webhook's
  acceptance reached the ladder when Teams gave up, about 6 s after the condition had
  cleared. With 0.2.0 and an outage of about 25 s the result came first, which is why the
  resolution arrived then. (2) *The ladder dropped the late result.* `record_result`
  ignored a result for an ended episode, and `_on_inactive` cleared an episode without a
  known delivery silently, the rule meant for "nobody heard". Either fix alone covers the
  observed run; only the ladder fix covers a condition that clears before even the fastest
  channel answers. (3) *A late resolution can be worse than none.* PagerDuty keys an
  incident by instance and class, not by episode: a resolve of the first episode queued
  after the trigger of the second would close the second incident. Hence the per-class
  hold. (4) The property test first failed on its own model: the state file keeps episode
  starts to the millisecond, so a restarted ladder names the same episode a few
  microseconds earlier; the test now names episodes as the file does. (5) *Clock skew:* the
  report read `_clock_skew` as comparing the reading with 1 s + RTT/2. It never did:
  `skew_exceeds` (there since the rules were first written, `93bbc25`) counts a reading
  only when it is beyond the limit whether IBKR truncates or rounds, which IBKR does not
  document: above +1.5 s or below −2 s, plus RTT/2. A true offset within ±1 s never alerts,
  one of 2.5 s plus the RTT or more in either direction always does (at the second probe),
  in between it depends on the probes' place in the second (truncation: never from −1 to
  +1.5 s; rounding: never from −1.5 to +1 s). Committing to truncation, as suggested, would
  gain 0.5 s on one side and could alert below 1 s if IBKR rounds; not done. What misled
  was the reading (`clock_skew_s` is uncorrected: a correct clock reads about −1 to +0.5 s)
  and the runbook's "more than one second" without "provably"; both are documented now.
  (6) *From the review:* the late result's facts were not kept, so the resolution showed
  the gateway of the moment it was sent; the late acceptance restarted the de-duplication
  window for an episode that was already active; the stop flushed the outboxes and never
  saved again. The first fix of the last point was itself flaky (4 of 6 runs): the stop
  cancels the evaluation that awaits a save, the write goes on, and the final save found
  the state thread busy and skipped; it now waits for that write. The hold stays: while an
  ended episode waits (at most 48.4 s per message and channel with the defaults, times its
  place in that channel's queue), the class sends nothing, escalations included. (7) *A
  fix that made it worse, reverted.* The first round found that "in flight" is saved when
  the ladder emits, before any channel has the message, so a sidecar killed then resolves
  an alert nobody received; round 2 therefore counted only a message a channel had begun
  to send. But that mark reached the file only with the next evaluation's save, so a
  message a receiver accepted in the second before a hard kill (OOM, SIGKILL) read as
  never begun: its resolution was lost (the second review's B1), and an escalation's left
  PagerDuty open (B2). The file is saved once per evaluation and cannot tell the two
  cases apart; a "resolved" nobody needed is the price of never leaving an incident open,
  so every message in flight at a restart counts as possibly received again. The property
  test had not seen it because it restarted from a live export of the state, which still
  held marks no save would have written; it restarts from the last saved snapshot now.
  (8) *Third review:* the evaluation queued its messages before it saved, so a fast
  channel could accept an announcement whose in-flight mark was not on disk yet, and a
  hard kill then lost its resolution; it saves first now. Moving the save first broke
  delivery at a stop (the stop cancels the evaluation while it waits for the write, and
  the due messages were never queued); they are queued in any case now. 0.2.1 saved
  nothing after its stop flush, so its v2 file can show a delivered announcement as not
  delivered; 0.2.2 read that as never sent. The property test's random search reached
  "announce, clear while out, accept after the save, kill" only at about 3000 examples;
  that case is an explicit example now. Stopping takes up to 13 s against Docker's
  default 10 s.
- **Next step:** publish 0.2.2 and watch `sidecar-publish.yml` through the signature check
  (a rollback to 0.2.1 does not read the v3 state file: it announces the active alerts
  again and forgets resolutions still owed; the file stays only until 0.2.1 writes its own
  state under the same name, and a 0.2.2 started before that reads it again, at worst
  repeating a "resolved"). A millisecond time request exists from TWS API 10.34.01
  (`reqCurrentTimeInMillis`, IBKR changelog) and would remove the whole-second band;
  whether the gateway and ib_async offer it is not checked. Open, older than this change
  and recorded as L34: a `resolved` is sent once and not tracked, so a stop or kill while
  it is queued, or every attempt failing, loses it (the alert stays open; nothing goes
  silent); and a class switched off before a restart leaves its announced alert
  unresolved and holds back the heartbeat. Tracking owed resolutions is planned for 0.2.3.

### 2026-11-16 — What the first completed paper sessions established

- **What changed:** documentation only, no code. The first completed real paper sessions on
  this image (2026-11-15/16 UTC; IB Gateway 10.50.1g, and 10.52.1d in one qualification) are
  recorded in `docs/limitations.md` (L02, L03, L04, L11, L12, L13, L15, L16, L20, L27), in the
  README's statements about the quick start's events, the Gateway log mirror, the samples, the
  sidecar, the qualification and the upgrade check, in `docs/log-contract.md` (the `jts/`
  mirror), `docs/evidence.md` (what is not covered), `docs/upgrade-check.md` (what was
  tested), the `resource_alert` runbook (memory) and `tasks/todo.md`. Where the README and the
  evidence page promised the event `twofa_dialog`, they now repeat the log contract's caveat
  that Gateway 10.16 and later may log only `twofa_initiated`.
- **Result:** with a real paper account the image works as designed for a fresh login and a
  stop. Ten logins completed (six qualifications and two in each of two compose sessions) and
  none asked for a second factor. From the events, `container_start` to `login_completed`
  took 8.2 to 11.4 s in the qualifications and 8.8 and 9.2 s in one compose session; the
  qualification's own `login_seconds`, counted from before `docker run` to a `docker exec`
  poll of the phase file, read 10 to 17 s. The Gateway was healthy; the API answered its
  handshake (server version 178), `examples/wait-for-gateway.sh` succeeded through
  127.0.0.1:4002 and the Python example client received IBKR's server time. The relay stayed
  closed until `login_completed`, opened within 0.7 s of it (`relay_opened`, 16 to 700 ms over
  the logins recorded), closed at a stop and opened again after a container restart
  (`boots_30m` 2, phase back to `logged-in`). A stop ended in `shutdown_complete` after 1 to 4 s.
  A logged-in Gateway used a working set of 459 to 494 MB and a JVM RSS of 544 to 608 MB, with
  151 to 156 JVM threads, 72 to 74 open file descriptors and no CLOSE_WAIT socket; of these
  only the working set, and the `pids` count of processes and threads, were compared with
  `docker stats`, and they agreed (L11). `docker diff` shows only Docker's mount point of the
  secrets (L02); the Gateway's own log is an encrypted `ibgateway.<yyyymmdd>.<hhmmss>.ibgzenc`
  per start, which the mirror does not copy (L03); `scripts/check-upgrade.sh --container`
  against this registry answered `up-to-date`, exit 0.
  The shipped files were started as shipped (`compose/docker-compose.example.yml` and
  `compose/docker-compose.sidecar.yml` at `e079462`, plus host ports, the sidecar 0.2.1 pinned
  by digest, a Teams URL that cannot be reached and a local stand-in webhook receiver) on fresh
  volumes with the published stable gateway `7773ff7`: the phase file read `logged-in` 12 s
  after `up -d`, all three containers ran with 0 restarts, the log volume was owned 1000:1000
  with mode 755, no `dirs_not_writable`; the sidecar was ready (`/readyz` 200; farms
  `apachmds`, `hfarm`, `secdefhk` ok; round trip 1.6 ms; `volume_present` true), with no alert
  and no notification while logged in (no false `unknown_window`). `docker compose stop
  ib-gateway` took 3 s, exit 0; `/readyz` then said 503 `not_measured`, and `gateway_stopped`
  (info) reached the webhook while the Teams channel failed to connect, as expected. After the
  start it logged in again, and no `resolved` message followed the stop (still none about
  three minutes later). The support bundle of sidecar 0.2.1 held no username and the account
  id only shortened (`***` and three digits, four times, in window titles). The qualification
  (`scripts/qualify-paper.sh`, run by hand outside CI; "login" is its `login_seconds`):

  | When (UTC) | Image | Result |
  |---|---|---|
  | 2026-11-15 20:01 | published stable `55f8894` (10.50.1g) | not qualified: one false `unknown_window`, every other check passed |
  | 2026-11-15 20:59, 23:08; 2026-11-16 00:53 | local builds: stable 10.50.1g with the scripts of #28 (three revisions) | qualified |
  | 2026-11-16 01:20 | published stable `7773ff7` (10.50.1g, after #28) | qualified: login 11 s, stop 3 s |
  | 2026-11-16 01:21 | published latest `cc3a6a9` (10.52.1d, after #28) | qualified: login 13 s, stop 1 s |

- **What did NOT work / root cause:** three defects, each found by these sessions and fixed
  in its own pull request (each has an entry below): (1) `unknown_window` was raised at every
  paper login, for the dialog `Warning` that IBC accepts within 0.3 s (and in one login for
  the start-up step `Authenticating...`), so the published stable image was "not qualified"
  (#28, `6fac77b`); (2) an account id of the shape `DU`, one more letter, six digits was not
  redacted, and the sidecar's support bundle carried it in full (#29, `7cb917e`); (3) the
  shipped gateway and sidecar compose pair looped on fresh volumes (`dirs_not_writable`):
  the sidecar image's root-owned `/var/log/ibgateway` was copied onto the empty log volume
  (#30, `e079462`, sidecar 0.2.1). Two things were misleading without being defects: the
  mirror's `ibgateway.*.log` name came from IB Gateway 10.x documentation, and it was not
  seen after a completed login (L03); the qualification's information check
  `root_filesystem_writes` reports two paths "changed outside the mounts", which are Docker's
  mount point of the secrets, not writes by the image (L02). One defect is still open: no
  `resolved` followed the stop of the shipped stack (sidecar 0.2.1). The sidecar records the
  result of the firing message only when every channel has finished; the message was queued
  at 01:56:51.842 UTC for the webhook and Teams, the condition cleared at 01:56:54 (phase
  `starting`), and the unreachable Teams channel gave up only at 01:57:00 after four
  attempts, so the episode closed as if nobody had been told and no `resolved` was sent. In an
  earlier session (sidecar 0.2.0, a stop of about 25 s) the `resolved` was delivered. The fix
  is being prepared for sidecar 0.2.2 on the branch `fix/sidecar-resolved-and-skew`.
- **Next step:** approve the waiting run 43789700905 of `qualify-paper.yml` for the published
  stable digest (it has not run); review the sidecar 0.2.2 pull request from the branch
  `fix/sidecar-resolved-and-skew` once it is opened; observe a daily restart, a second-factor
  prompt, a weekly re-authentication and a competing session (L01, L09, L12); decide what
  `tail-gateway-logs.sh` does about a name that was not seen (L03).

### 2026-11-16 — The sidecar no longer takes the gateway's log volume away from it

- **What changed:** started as shipped on fresh volumes, the reference compose file plus a
  sidecar override did not come up: the gateway failed its preflight with
  `dirs_not_writable` (`/var/log/ibgateway` owned 0:0) and its restart policy started it
  again and again; no login was attempted. Two changes, each sufficient alone on fresh
  volumes: the sidecar image no longer has `/var/log/ibgateway` at all (sidecar 0.2.1), and
  every shipped compose file that mounts the log volume into another container (both
  sidecar overrides, the Azure profile, the Vector recipe) mounts it read-only with
  `nocopy`. `sidecar/README.md` shows the same mount, how to get a looping stack out of the
  loop, and `--no-deps` for sidecar commands. New test `sidecar/tests/e2e/fresh-volumes.sh`
  (internal network, `IBC_LAUNCH=no` checked before anything starts), run by the sidecar
  workflow's end-to-end job, which now also runs on changes to the gateway image and to the
  other compose files; a policy test lists every reader of the log volume.
- **Result:** against the published images and the previous compose files the new test fails
  14 of 16 checks and shows the loop (`restarting`, 10 to 11 restarts within the test). With
  this change 16 of 16 pass, for both overrides. With the published sidecar 0.2.0 and the new
  compose files 15 pass (only the image's own check fails): `nocopy` protects an older image.
  Without the directory the sidecar also reports a missing mount as `volume_present: false`;
  with an empty directory in the image it could not (the runbook's case "not mounted" was
  never reported).
- **What did NOT work / root cause:** (1) *An empty named volume is not neutral.* Docker
  gives it the owner and mode of its mount point in the image of a container created on it,
  when the image has the directory and the mount does not say `nocopy`. This is engine
  behaviour (the copy-up of an empty volume), seen on Docker Engine 29; Docker's
  documentation describes the copying of content, not the owner. The sidecar image had
  `/var/log/ibgateway` root-owned, and compose creates the sidecar after the gateway
  (`depends_on`), so the gateway's volume became root-owned before the gateway wrote to
  it. (2) *No test created the two together.* `sidecar/tests/e2e/run.sh` starts the gateway
  with `docker run` and the sidecar after it, when the volume is no longer empty; the
  compose files were only rendered (`config -q`), never started together. The first real
  session did what the README tells a user to do and hit it at once. (3) *The first fix gave
  the directory the gateway's owner (1000:1000) instead of removing it.* The independent
  review found the better design: a path that is not in the image copies nothing, ties the
  sidecar to no owner of the gateway, and lets a missing mount be seen. (4) *`up -d` does
  not repair a stack that is already looping:* it re-creates the sidecar only, and with
  `nocopy` nothing touches the empty root-owned volume any more; the gateway container must
  be created again (`down` then `up -d`, or `up -d --force-recreate`), checked by the review.
  (5) The Vector image of the Azure pack has no such directory, so it never caused the
  fault (checked by experiment); its mount got `nocopy` so that a later Vector image cannot.
  (6) A failed preflight under `restart: unless-stopped` is started again without limit;
  that is how a mount error became a loop (L33). Nothing is sent to IBKR in that state (the
  preflight runs before IBC). (7) The README told users to check the sidecar's
  configuration with `docker compose run --rm sidecar check-config`, which starts the
  gateway (and its login) through `depends_on`; it says `--no-deps` now.
- **Next step:** the sidecar 0.2.1 publish, watched to its signature check; the stack as
  shipped with a real paper login.

### 2026-11-16 — An account id with a third letter is redacted

- **What changed:** the shape by which an IBKR account id is recognised is now an optional
  `D`, then `U`, `F` or `I`, then zero to two further capital letters, then 5 to 9 digits
  (`D?[UFI][A-Z]{0,2}\d{5,9}`; `[0-9]` for `\d` in `redact.vrl`). It replaces "`DU`, `DF`, `U` or `F` directly followed by 5 to
  9 digits" in the four places that carry it: `ACCOUNT_RE` of the sidecar (`redaction.py`;
  its label check refuses an `IBGW_INSTANCE` that this redaction would change), rules 1 to 3 of
  `azure/vector/redact.vrl`, `account_like` in `azure/vector/entrypoint.sh` and `good_label`
  in `azure/vm/apply-config.sh`. The support bundle's MANIFEST, `sidecar/README.md`,
  `azure/README.md` and L32 state the shape and that an id of any other shape is not
  shortened. `azure/tests/run.sh` fails when the two label patterns of the Azure pack differ
  in text, and when they and `redact.vrl` decide one of 43 boundary labels differently.
- **Result:** the line that leaked, written with a made-up id of the same shape
  (`IBC: detected dialog entitled: DUR123456 Trader Workstation Configuration (Simulated
  Trading); event=Opened`), leaves the sidecar's support bundle with `***456` and the Azure
  shipper with `[ACCT:…456]`; a label of that shape is refused by the sidecar, the shipper
  and `apply-config.sh`. A run of capital letters that begins with another letter stays as
  it was (`CPU12345`, `XYZ123456`), and so do ten digits and a third further letter. Each
  new test was seen to fail against the old pattern first (test counts in the pull request).
- **What did NOT work / root cause:** (1) *A real paper account id passed every pattern.*
  The paper account of the session of 2026-11-16 had the shape `DU`, one more letter, six
  digits. Every pattern expected the digits directly after `DU`, `DF`, `U` or `F`, so the
  sidecar's support bundle carried the full id in `ibc-redacted.txt`, inside the title of the
  configuration window that IBC logs, while the bundle's MANIFEST said that account ids are
  shortened. The patterns and their fixtures came from the same assumption about the shape,
  so every test agreed with the pattern (the lesson of the first real IBC log, again).
  (2) *The new shape is one observation plus headroom, not a specification.* IBKR names
  `F` for a fund manager's master account and `U` for a hedge fund's sub account
  ([IBKR Campus](https://www.interactivebrokers.com/campus/trading-lessons/hedge-fund-account-overview/)),
  `I` for a fully disclosed broker's master account and `U` for that broker's proprietary
  account ([application guide](https://www.interactivebrokers.ie/download/applicationguide.pdf),
  page 14), and says that a paper trading account number begins with `DU`
  ([Interactive Brokers Securities Japan](https://www.interactivebrokers.co.jp/en/support/customer-service.php)).
  None of them says what follows the letters, and none names `DF` or `DI`: both are
  assumptions. The first wording of this change said more than the sources ("`U` for
  individual and sub accounts", "`F` for advisor masters", "`DU` widely documented"); a
  review read the two IBKR documents and the wording now quotes them, with a source for
  `DU` that was read rather than assumed. The letter after `DU` is an observation, the
  second further letter an assumption. The trade is deliberate: a
  word of the shape that is no id is masked too (`ID12345`, `USD100000`; in the Azure pack
  in any case, `disk12345`), which costs readability, while a missed id breaks the promise.
  (3) *The label rule had to follow.* The Azure shipper refuses a label that the redaction
  would rewrite, so it now also refuses a label such as `uk100234`; a deployment that used
  one stops at the next start with exit code 78 and a message naming the variable. The
  sidecar refused only a label that was an id as a whole (`fullmatch`), so a label its own
  redaction rewrites was accepted, and the first review of this change found what that
  does: `gw-UAT10001` and `gw-UAT20001` both became `gw-***001`, one de-duplication and
  PagerDuty incident key for two gateways; `desk-DUR123456` left the container in full in
  the bundle's file name, its MANIFEST and `settings.json` while `status.json` showed
  `desk-***456`. The sidecar now refuses a label when `redact_accounts(label) != label`,
  the principle the Azure pack already used (a property test checks it for generated
  labels). **Behaviour change:** labels such as `ID12345`, `IB10001`, `UK100234`,
  `FIX12345`, `UAT20261116`, `gw-UAT10001` and `desk-DU1234567` stop the sidecar at start
  (the message names `IBGW_INSTANCE`, never the value); lower-case labels stay valid in the
  sidecar, whose redaction is upper case only.
  (4) *The sidecar's farm-name guard had the same hole, and the first attempt left half of
  it open.* A farm notice ending in an id of the observed shape in front of a farm stem
  would have been shown as a farm name in `/status` (found with a constructed input, not
  in a session). The first fix kept `ACCOUNT_RE` as the guard, on the upper-cased
  candidate; the review found that an id BEHIND the stem still passed
  (`secdefu1234567`), because after upper-casing the letter before the id is a capital
  and the pattern does not start behind one. The guard now refuses any candidate with five
  digits in a row: every account id has them, no farm name known to the tracker does
  (`usfarm`, `usfarm.nj`, `cashfarm`, `ushmds`, `secdefnj`, `usfuture`, `usopt`), and the
  rule does not depend on the account-id shape at all.
  (5) Not changed: the two redactions still differ in their boundaries. The sidecar matches
  upper case only, anywhere after a character that is not a capital letter; the Azure pack
  matches any case, but only a word of its own, an id in upper case glued to a lower-case
  word, or one after an escaped line break (L32).
  (6) *The tests did not pin what the comments claimed.* The review ran mutants: rules 2
  and 3 of `redact.vrl` had no test of their own (rule 3 was only reached by ids that rule
  2 catches first, because after `\n`, `\r` or `\t` the letter is a lower-case lead), and
  nothing tied `redact.vrl` to the two label patterns. With this repository's own mutant set
  (one change each, run against the real checks): `redact.vrl` 29 of 49 killed before, 51
  of 51 after (two mutants of the new escape added); label pattern, changed alike in both
  shell files, 16 of 28 killed before, 28 of 28 after (each earlier survivor by
  `label_verdicts`). Each rule now has a test at every bound of the shape, and
  `label_verdicts` decides 43 boundary labels with all three engines.
  (7) *Smaller holes the same review found, each fixed with a test that failed first:*
  `\d` in `redact.vrl` took any script's digits, and `slice!` cut such a match inside a
  character; a text that already held U+E000 skipped the underscore swap, so
  `acct_DUR123456` in it was shipped in full (now escaped and restored exactly); the
  end-to-end canaries were old-shape ids only (now `DUQ864209` beside each; red against the
  old redaction and the published sidecar 0.2.0). The VM's host label is `<namePrefix>-vm`
  and cannot change, and a `namePrefix` such as `ib10001` (accepted before this change) now
  makes `apply-config.sh` refuse the configuration; the refusals name the shape and the
  remedy, never the value.
- **Next step:** release the sidecar as 0.2.1 in a pull request of its own (this change
  leaves the version alone); compare the shape with a live, an advisor and a broker id when
  one is at hand (the shape only, never the id) and change the four places together.

### 2026-11-16 — `unknown_window` is raised for a window that stays open, not for one that opens

- **What changed:** the first completed logins on this image (a paper account, Gateway
  10.50.1g, 2026-11-15 UTC) raised `unknown_window` at every login although nothing was
  wrong. The classifier now waits `UNKNOWN_WINDOW_GRACE_S` seconds (default 10; `0` is the
  old behaviour) and raises the event only when the window is still open then. The wait
  ends without an event when IBC reports the window closed, when a new IBC starts (the
  Gateway process was replaced and its windows went with it), or when IBC's output ends.
  The list of known titles gains the start-up frame's steps as a family (a FRAME whose
  title ends with an ellipsis; a line of the list can now be limited to frames). The
  automatic screenshot is taken when the event is raised, so of a window that has been on
  the screen for the grace period. The qualification script takes its verdict on unknown
  windows the grace period plus 5 seconds after the login. The IBC lines of the two real
  logins are a fixture (`tests/fixtures/ibc-real-paper-login.log`, account id replaced).
- **Result:** the real log through a pipe that stays open past the grace period gives
  exactly `ibc_version`, `login_dialog`, `login_completed` per start and no
  `unknown_window` (three before the change); with IBC's "closed" lines for the warning
  removed, the warning of the running Gateway is reported. The real qualification with a
  paper account passed on a local build of the stable image with these scripts, once per
  revision, the last with the scripts as merged (login 10 s, stop 2 s; L16). The unit
  suite in the image passes in full (counts in the pull request). `login_completed` is
  now confirmed against real IBC output, and so is IBC's stop message that must not count
  as a login (L01). No key, event or phase of the log contract changed.
- **What did NOT work / root cause:** (1) *A title cannot tell a window nobody handles from
  one that IBC answers.* Every paper login opens a dialog titled `Warning` (this is not a
  brokerage account); IBC accepts it in the same millisecond and it is gone 0.3 s later.
  The event was raised the moment it opened, so the qualification ended "not qualified"
  for that alone and the sidecar sent an `unknown_window` alert at the next stop. Listing
  `Warning` would have hidden every warning that nobody answers, so the title stays off the
  list and the time a window stays open decides. (2) *The list came from IBC's source and
  one failed start.* The start-up frame is titled with its current step; `Authenticating...`
  was not listed and appeared in one of two starts. (3) *IBC names a window by its title
  only.* The start-up frame opens as `Authenticating...` and closes as `Starting
  application...`, so an opened window cannot always be matched to its closing; that is why
  the frame's titles are a family on the list, and it is a stated limit for other windows
  (L10). (4) A background timer per window was rejected: its event could appear after the
  classifier and the Gateway had ended. The wait is a time limit on the classifier's own
  read, used only while a window waits, and the unfinished line bash returns at the limit
  is kept. (5) *The independent review found what the first version got wrong.* The
  waiting list outlived a restart of the Gateway inside one classifier run (`ibcstart.sh`
  relaunches it, and the old process writes no "closed" line), so a window of the old
  process was reported after it was gone and every later answered `Warning` looked unknown;
  a new IBC now empties the list. The oldest of several windows with one title counted as
  the one that closed, so each answered window restarted the clock of a stuck one; the
  newest counts now. Time came from the wall clock (a step could report a closed window or
  delay a stuck one); it comes from the kernel's uptime now. After a pause of the process,
  a window was reported although its "closed" line was already in the pipe; a due window
  is reported only once no line is waiting (lines are read first for at most one second,
  counted from the first postponement: counted from the due time, a pause would defeat it,
  as a test showed). The family rule for
  titles with an ellipsis applied to dialogs too, which can wait for an answer; it is
  limited to frames. In a UTF-8 locale bash can drop bytes when a timed read ends inside a
  character; the classifier runs with `LC_ALL=C`. (6) *Tests that replay a file cannot see a
  waiting window:* the input ends within milliseconds and every wait ends with it, so the
  first real-log test passed whatever the classifier did with the warning. Every
  grace-period test now keeps the pipe open past the grace period, and the real-log test has
  a counterpart without the "closed" lines. (7) *Mutation runs found tests that could not
  fail* (a glob title compare, the cap's drop order, a default of 5 s, `LC_ALL=C`, a report
  a second early, the pause bound); each now has a test that fails without it (the
  `LC_ALL` test in 5 of 5 runs). What still survives changes timing by under a second
  (uptime hundredths ignored, whole-second time limits), cannot be seen without a clock
  step (the clock source), or is equivalent (a redundant `break`).
- **Next step:** a qualification of the published image; watch real sessions for windows
  that stay open and are harmless (L10); the automatic picture of a real blocking dialog
  (L25).

### 2026-11-13 — The release step of the publish survives a GitHub error

- **What changed:** `publish.yml` writes the GitHub release through the new
  `scripts/release-upsert.sh`. One attempt asks whether the release exists, creates it or
  replaces its assets and notes, and reads it back (every asset listed, the old-scheme asset
  gone, the new digest in the notes). A failure anywhere repeats the whole attempt, five
  times with pauses of 5, 15, 45 and 90 seconds.
- **Result:** 23 tests with a stand-in `gh` (counts of the whole suite in the pull request),
  among them the failure of 2026-11-13 replayed: the upload fails once with HTTP 502 and the
  release still ends up right.
- **What did NOT work / root cause:** (1) *The first publish of the final merged state
  failed in its last step.* GitHub answered HTTP 502 while one release asset was replaced.
  The tags had already moved, so for about 25 minutes `latest`, `10.51.1e` and `10.51`
  pointed at a new image while the release described the previous one; re-running the job
  repaired it. The step was a plain sequence of `gh` commands without a retry, placed after
  the one step that cannot be taken back. (2) Reordering does not help: whichever of "tags"
  and "release" comes second can fail, and a release that names a digest no tag points at is
  no better. (3) Exit codes are not enough: a creation can fail after the release exists, and
  `gh release view` fails the same way for "no such release" and for a server error. The
  script therefore decides create-or-update anew in every attempt, reads "not found" from the
  message, and judges the result by reading the release back. (4) *The first version of the
  script could report success on a draft.* `gh release create` with assets makes a draft,
  uploads and publishes, and deletes the draft on a failure; when that clean-up fails too,
  the next attempt found the draft, updated it and never published it. An independent
  review found this by running the script with the real `gh` against a local API; the
  update now publishes and the read-back requires "not a draft". (5) The same review
  found GitHub's message missing from the log for three calls (a variable set inside a
  command substitution is lost) and eight changes to the script that no test noticed;
  the reason is kept in a file now and nine tests were added.
- **Next step:** the first publish with this step; the same pattern for the archive upload
  in `detect-releases.yml`, which a daily schedule repeats anyway.

### 2026-11-13 — The sidecar moves to Python 3.15

- **What changed:** the sidecar image is built on `python:3.15-slim` (Python 3.15.2, the same
  Debian release, pinned by digest), and its package requires Python 3.15: `requires-python`,
  the black and ruff targets, mypy's version, `.python-version` and `uv.lock` change with the
  `FROM` line. The sidecar's version goes from 0.1.0 to 0.2.0, and the compose files and the
  README name the new tag.
- **Result:** unit suite, lint, format and type checks pass on 3.15.2; the image builds and
  its smoke and end-to-end suites pass (counts in the pull request). No dependency changed
  version: the lock file was re-resolved for the new interpreter.
- **What did NOT work / root cause:** *Dependabot's pull request for this could not build.*
  It changed only the `FROM` line, while the package said `>=3.14,<3.15` and the lock file
  was resolved for 3.14, so `uv sync --frozen` found no interpreter. The Python version lives
  in seven places; the automatic pull request is a notice, not the change. *The first
  version of this change kept the sidecar at 0.1.0.* An independent review pointed out that
  the publish workflow never moves an existing version tag: `0.1.0` would have stayed the
  3.14 image, the new build would have been reachable as `sha-<commit>` only, and the next
  security rebuild would have changed the interpreter under the same version.
- **Next step:** the first publish of 0.2.0 (it happens when this is merged). `examples/python`
  stays on `>=3.14` (it is a sample for users and already accepts 3.15).

### 2026-11-13 — First authenticated paper sessions: the account had no paper trading access

- **What changed:** documents only. `docs/limitations.md` (L02, L03, L10, L16, L25 updated;
  L31 new), a row in the README's troubleshooting table, a paragraph in the
  `unknown_window` runbook and a sentence in the qualification section record what two
  real sessions showed.
- **Result:** the qualification ran against IBKR for the first time, on the published
  stable image (10.50.1g). IBKR accepted the credentials; the login then stopped at a
  dialog `Paper Account Notice`. Result "not qualified", one attempt, graceful stop in 2
  seconds. A second session with `SCREENSHOTS=yes` and IBC's window-structure log gave the
  dialog's text: "This account does not have paper trading access enabled. Please log
  into Account Management to request access." Nothing outside the mounts was written; the
  raw IBC log did not contain the username.
- **What did NOT work / root cause:** (1) *The login did not complete, and the cause is
  not in this image.* The account has no paper trading access; credentials that work on
  IBKR's website do not prove that it has. (2) *The first diagnosis was wrong.* The title
  looked like IBC's paper-account warning with a new name, and IBC's handler looks for
  other words, so a patch of the IBC fork was the obvious next step. The screenshot showed
  a different dialog before anything was changed. A title is not a diagnosis; look at the
  window. (3) The events named no cause: `unknown_window`, and the phase stayed `login`.
  For a person at night that is too little (L31). (4) The automatic screenshot was deleted
  unviewed (it is taken 33 ms after the window opens and may show the login window with
  the username), so what proved the feature was a picture taken on request 12 seconds
  later; whether the automatic one shows a completely drawn dialog is open (L25).
- **Next step:** a paper trading account that IBKR has enabled, then the qualification
  again; a decision on classifying this dialog as `needs-human` with its own event.

### 2026-11-12 — Console made safe and logged, upgrade check, log-shipper recipes, passkey facts, three design notes

- **What changed:** the break-glass console is view-only unless `VNC_VIEW_ONLY=no`, runs
  without x11vnc's remote control, and reports every visit (`vnc_client_connected`,
  `vnc_client_disconnected`); `compose/docker-compose.console.yml` and `docs/console.md` give
  the route to it (ADR 0017). New: `scripts/check-upgrade.sh` (`brokersre.upgrade-check.v1`),
  `docs/recipes/` (Vector for Loki, OTLP, Datadog) with `tests/recipes/run.sh`,
  `docs/passkeys.md`, and three design notes under `docs/specs/`. Log contract v2 gains the
  two console events and `data.view_only` on `vnc_enabled`; nothing was renamed. The README's
  link to IBKR's reauthentication page was dead (404) and points at the page's new address.
- **Result:** unit, CI-script, container, compose and recipe suites green (counts in the pull
  request). With the image's real x11vnc 0.9.17: view-only discards a pointer event and
  `VNC_VIEW_ONLY=no` lets it through; a wrong password gets nobody in; the password is in no
  argument list, environment, file or event.
- **What did NOT work / root cause:**
  - *View-only could be switched off unseen.* x11vnc accepts remote-control commands from any
    process on the display (`x11vnc -R noviewonly`); the pointer then followed the client
    while the event still said view-only. Fixed with `-noremote`; the container suite tries
    the command before it measures.
  - *A hook's output had nowhere to go.* x11vnc prints `PORT=5900` on stdout even with
    `-quiet`, so its stdout stays discarded, and it closes every descriptor above 2 for a
    hook. The container's stdout is handed over as descriptor 0 and the hook writes there.
  - *No idle limit.* x11vnc has no option that disconnects an idle client (`-timeout` and
    `-readtimeout` mean something else); none was built.
  - *No web console.* No maintained noVNC image from a publisher that can be verified runs as
    a non-root user; the upstream projects publish none.
  - *No published port reaches the console.* x11vnc listens on the container's own loopback;
    the route is a bridge a person opens with `docker compose exec` behind a loopback port.
  - *The formatted registry lookup was throttled.* `docker buildx imagetools inspect --format`
    fetches every platform's manifest; two registries answered 429. The raw manifest is one
    request and its SHA-256 is the tag's digest.
  - *Vector 0.61 does not expand `${VAR}`* unless started with
    `--dangerously-allow-env-var-interpolation`: the recipes read no environment variable.
    A new volume takes owner and mode from the image directory it is mounted over, so a
    non-root Vector keeps its checkpoints in `/var/tmp`. A first draft of the shipper's
    compose file would have mounted the gateway's secrets folder into the shipper; its
    secrets now live in a folder of their own.
  - *The stack below this branch had a gap.* Two commits of the supply-chain branch (the
    suites' `quiet_grep` helper) were added after the branch above it had forked, so every
    later branch ran its container and compose suites without them. Found when this branch's
    new "is the password in the log?" checks needed the helper. The branches were brought up
    with merges, and the nine quiet greps and fifteen negated assertions of this branch that
    could not fail on Linux were converted.
  - *A session open at shutdown has no `vnc_client_disconnected`*: x11vnc is ended with the
    other helpers before it runs the hook.
  - Not established: the console during a real login, the SSH tunnel and a desktop viewer;
    the recipes against a real Loki, collector or Datadog; whether IB Gateway accepts a
    passkey (IBKR lists TWS 10.46.1d, not IB Gateway).
- **Next step:** try the console and one recipe on a logged-in paper session; decide whether
  input should be switchable without a restart, with an event of its own.

### 2026-11-12 — A runbook for every alert class of the sidecar

- **What changed:** `docs/runbooks/` holds an index and one page per alert class (16), each
  with the same five sections: what it means, check first, what to do, what not to do, when
  it clears. The compose override sets `NOTIFY_RUNBOOK_BASE` to that folder, so a
  notification links the page of its class. Tests of the sidecar keep the pages in step with
  the code: a class without a page, a page without a class, a page whose heading is not the
  catalogue title, and a relative link or anchor that leads nowhere all fail.
- **Result:** sidecar suite green (counts in the pull request). The link test was shown to
  fail on a wrong file name and on a wrong anchor before it was trusted.
- **What did NOT work / root cause:** (1) *The sidecar could link a runbook since its first
  version, and there was nothing to link.* The example value was a placeholder wiki address,
  so every installation that copied it sent dead links, at the moment a person needs the
  page. (2) The pages are written from the rules' code, not from incidents: no login has
  completed on this image yet, so nothing in them is experience. Each page says only what the
  code does, and the index says so. (3) Three alerts clear on a timer (`login_failed`,
  `unknown_window`, a restart without a requested shutdown: 15 minutes) although nothing was
  fixed; reading the rules for the pages made that visible, and the pages now say "check the
  phase before you trust the resolved message". Whether the `resolved` text itself should
  differ for a timed clearing is open.
- **Next step:** after the first real incidents, correct the pages from what actually
  happened; decide whether a clearing by timer should say so in the message.

### 2026-11-12 — `screenshot.sh` was not executable on Linux; the execute bit is now checked

- **What changed:** `screenshot.sh` and `login-latch.sh` are recorded as executable in git,
  like the other scripts of the image. `scripts/check-file-modes.sh` reads `git ls-files -s`
  and fails when a tracked `*.sh` file lacks the bit; the lint job runs it, and a test of the
  CI-script suite runs it against the checkout when git is there.
- **Result:** the two unit tests that run `screenshot.sh` as a command failed on the first
  Linux run of the screenshot branch ("Permission denied") and pass with the bit set. The
  check names 55 shell scripts, all executable.
- **What did NOT work / root cause:** *every local run was green and proved nothing about the
  mode.* The development host is Windows: git records a new file as `100644`, while Git Bash,
  the Docker Desktop share and a tree streamed with `tar` all present it as executable, and
  the fast local runner even ran `chmod -R a+rx`. The image is unaffected (the Dockerfile sets
  0755 on its scripts), which is why the container suite passed too; only scripts run from the
  tree were hit. `login-latch.sh` had the same mode for two pull requests without a failure,
  because it is only sourced. A check of the file system would repeat the mistake, so the
  check reads the index, which is the same on every host.
- **Next step:** none for the mode. The general rule stands: a green run on the Windows host
  says nothing about POSIX behaviour; look at the first Linux run before building on a branch.

### 2026-11-12 — Opt-in screenshot of the Gateway's screen when a window blocks the login

- **What changed:** with `SCREENSHOTS=yes` Xvfb keeps its framebuffer in a file on the run
  tmpfs, and `screenshot.sh` copies it to `screens/` on the log volume when a window that IBC
  does not handle opens (`unknown_window`), when the login stalls (`login_stalled`) and on
  request. At most one automatic picture per `SCREENSHOT_MIN_INTERVAL_S`, the newest
  `SCREENSHOT_KEEP` kept. Events `screenshot_saved`, `screenshot_failed`,
  `screenshots_unavailable`. Off by default; unset, Xvfb is started exactly as before.
- **Result:** unit and container suites green (counts in the pull request). The container
  suite takes a screenshot with the image's real Xvfb: an XWD image of the whole screen,
  about 1.5 MB, readable by its owner only.
- **What did NOT work / root cause:** (1) *"A screenshot needs a new package" was wrong.* The
  roadmap status first recorded this item as not buildable without a tool such as `xwd`,
  against the rule that every package needs a reason. Xvfb's own `-fbdir` option writes the
  framebuffer as an XWD file; checked in the image before believing either statement. (2) The
  image has no converter, so the file is XWD, not PNG; that is accepted rather than adding a
  package. (3) The classifier must never wait for the log volume (IBC's output pipe is behind
  it), so its screenshot is taken beside the loop, not in it. (4) Opt-in, not default: the
  screen shows the username in the login window (L25).
- **Next step:** open a screenshot of a real login window and of a real blocking dialog and
  check that it shows what an operator needs (L25).

### 2026-11-12 — Windows host kit (`windows/`), with two review rounds fixed before the pull request

- **What changed:** new `windows/` directory: `setup.ps1`, `doctor.ps1`, `harden.ps1`,
  `start.ps1`, `uninstall.ps1` over the module `BrokerSre.Gateway` (Windows PowerShell 5.1 and
  PowerShell 7), a compose template, Pester tests, `windows-kit.yml`, ADR 0011.
- **Result:** the Pester suite passes under both editions and PSScriptAnalyzer is clean
  (counts in the pull request). Read-only runs on one Windows 11 computer with Docker Desktop:
  `doctor` reports, `setup -NoStart` produces a compose file that `docker compose config`
  accepts, and a before/after fingerprint of power, Windows Update policy, `.wslconfig`,
  tasks, firewall and auto-logon is unchanged. No gateway was started with the kit.
- **What did NOT work / root cause:**
  - *A rejected login was noticed only while `setup.ps1` was watching*, so after a password
    change the restart policy or the start task sent the same credentials at every start.
    `start.ps1` and `setup.ps1` now look back to the container's start time, record the
    rejection and stop the stack; the image's own latch (ADR 0016) closes the window between
    two runs of the kit, which two scripts cannot close.
  - *`uninstall.ps1 -RemoveData` deleted its own state when Docker was down* and orphaned the
    container and volumes; files are now deleted last and only when every earlier step worked.
  - *`harden.ps1 -Undo` exited 0 with changes still in place.*
  - *The default gateway folder under `C:\` was writable by every local user*, and the
    elevated undo replayed whatever the journal said; the folder is closed before anything is
    written into it and undo accepts only entries the kit can write.
  - *A timed-out `docker compose up` left `docker-compose.exe` running*: `Process.Kill()` ends
    one process, not its children.
  - *`docker compose up -d` does not recreate a container when only a secret file's content
    changed* (measured), so `-ResetSecrets` reported "Logged in" without trying the new
    values; it now passes `--force-recreate`.
  - *`wsl --` runs its arguments through the Linux shell* (a `|` in a format string became a
    pipe); *`Set-Acl` needs SeSecurityPrivilege on an already protected folder*; the
    NetSecurity cmdlets needed minutes under 5.1 for what the firewall COM API answers in
    0.3 s.
  - *Five tests passed whatever the code did* (a mocked subject, an empty loop, `>= 0`, a
    regex nobody would trip); they were replaced and checked by breaking the code.
  - Not established: Docker Engine inside WSL end to end, the boot task without sign-in, any
    task registration, a real login and a real rejected login, the clock fix after a real
    resume, the workflow on a GitHub runner.
- **Next step:** validate on a second computer what could not be proven here; first run of
  `windows-kit.yml`.

### 2026-11-12 — Supply chain: both platforms gated on the pushed digest, fix-driven rebuilds, VEX for the vendor jars

- **What changed:** `publish.yml` builds both platforms once without a cache, pushes the index
  by digest only, scans linux/amd64 and linux/arm64 of that digest, makes one SBOM per
  platform attested to that platform's manifest, signs and attests the index (VEX,
  provenance) and only then moves tags (`scripts/promote-tags.sh`). `rebuild.yml` scans the
  published images daily and requests a rebuild of a channel with a fixable CRITICAL/HIGH OS
  finding, with one issue per channel, one comment per day and no request after three days.
  The channel list, the tag overlap of the two channels, the platform of every scan report,
  the platform manifests of the index and the rebuild request are decided by tested scripts;
  the two workflows serialise per channel, hold no expression inside a script and pin every
  action by commit and Trivy to v0.76.2. `security/vex/ibgateway-vendor-jars.openvex.json`
  states the project's position on the 25 CVEs of IBKR's bundled jars (all
  `under_investigation`); `scripts/check-vex.sh` reports drift. New: `docs/evidence.md`, ADR
  0015. **Breaking for consumers of release assets:** `sbom-<channel>.cdx.json` becomes
  `sbom-<channel>-linux-amd64.cdx.json` and `-arm64.cdx.json`, the SBOM attestation is on the
  platform manifest digest, `digests-<channel>.json` gains `platforms`, and the documented
  verification identity ends in `@refs/heads/main$`.
- **Result:** CI-script suite green inside the image (counts in the pull request; 134 of its
  tests are new) and, in the builder's run, under gawk on Ubuntu 24.04. A manual scan of both
  platforms of the digests published on 2026-11-11 found no fixable OS finding of any
  severity. **No workflow has run yet**: they run only from `main`.
- **What did NOT work / root cause:**
  - *The gate was never "CRITICAL/HIGH".* trivy-action drops the severity input when the
    format is SARIF, so with `exit-code: 1` the gate failed on a fixable finding of any
    severity. Fixed with `limit-severities-for-sarif: "true"` where SARIF is the gate format.
  - *Scanning a local amd64 build never scanned what was pushed*, and arm64 not at all.
    Scanning an OCI layout before any push was rejected: it needs a second tool to push the
    scanned layout. Pushing by digest costs an untagged, unsigned manifest in the registry
    when a gate fails (L23).
  - *One SBOM for a two-platform image described one platform.* syft reads the runner's
    platform from an index: 9,776 components for amd64, 9,946 with `openjdk-25-jre` for arm64.
  - *A workflow-wide concurrency group lost work*: a request for one channel replaced a
    pending run for both.
  - *`inputs.channels` was pasted into shell*; the allow-list ran after the paste.
  - *The documented identity regexp accepted any branch.*
  - *`not_affected` was not defensible for any jar CVE.* Loopback exposure does not show that
    the Gateway never parses hostile input; two CVE texts exclude 2.12.3 but the advisory
    data disagrees.
  - *A bare `! command` in a bats test asserts nothing unless it is the last line.* Twelve
    such lines existed across the suites, several of them guarding "no secret appears here";
    all now end in `|| false` and still pass. A four-test probe showed the difference.
  - *The container suite, the compose suite and the qualification script ended pipelines in
    `grep -q` under `pipefail`.* When the quiet grep exits at its first match the writer dies
    of SIGPIPE and the pipeline is false: for "a credential is in the events: fail, else
    pass" that is a false pass, and it shows only on a fast Linux host. Fourteen host-side
    pipelines now use a helper that reads all input; both suites pass with it.
  - *jq's `^` and `$` match per line*, so an anchored check let a line break through.
  - Deleting the untagged image of a failed gate was rejected: only the index can be deleted
    safely, and the platform manifests hold the bulk.
- **Next step:** merge this change on its own; run `rebuild.yml` by hand with mode `scan`,
  then watch the publish run of the merge, and record the first run ids here.

### 2026-11-12 — Optional sidecar: API probe, status endpoints, alerts (`sidecar/`)

- **What changed:** a second, optional image. It reads the gateway's log volume read-only,
  probes the API through the relay port (handshake, server time, connectivity notices, clock
  skew; no order, cancel or what-if call exists in it), serves `/livez`, `/readyz`, `/status`
  and `/metrics` on port 9810, and notifies people through seven channels with an escalation
  ladder. It runs in its own network namespace by default, announces a gateway that stopped,
  exited or fell silent, can ping a dead-man check, and names the cause when the gateway
  holds because of the rejected-login latch. ADR 0010; workflows `sidecar.yml`,
  `sidecar-publish.yml`, `sidecar-rescan.yml`.
- **Result:** Python gates clean and the tests green (counts in the pull request); container
  smoke suite and the end-to-end run with the real gateway image green, including a
  notification delivered after `docker stop` of the gateway. Nothing ran against a logged-in
  Gateway (L20).
- **What did NOT work / root cause:**
  - *A sidecar inside the gateway's network namespace is mute exactly when it is needed*: when
    the gateway container stops it keeps only loopback and cannot send anything. The first
    design shared the namespace to reach the loopback API; the default is now its own
    namespace and the relay port, and the shared mode is an option that says what it cannot do.
  - *"Second factor pending" derived from the phase resolved itself every three minutes*: the
    phase flips to `login` on each prompt timeout. It is derived from events, holds across the
    flip and escalates from the first prompt.
  - *An alert was recorded as sent although no channel had accepted it*, and was later followed
    by "resolved". The dispatcher now reports back; an undelivered alert is retried and
    persisted.
  - *Reset windows stored in fixed Hong Kong time covered the US close in winter.* The Asia
    windows are anchored to New York time, as IBKR's footnote implies.
  - *Image pins held in a Dockerfile `ARG` are invisible to Dependabot*: both images are named
    in `FROM` lines.
  - *One failed save of the state file switched to memory for good*; it now retries.
  - *The end-to-end job failed on its first run in GitHub Actions and never locally.* After a
    stop of the gateway the sidecar said "No action needed. The condition has cleared." about
    a stalled login: the gateway's sampler closes that pair itself while stopping, and on a
    fast machine the sidecar read the closing event before the new phase. The model now
    records which event ended the gateway's attempt before the pair closed (the feed order is
    deterministic) and the rule hands over on that.
  - *Both test scripts ended pipelines in `grep -q` under `pipefail`*, which is false when the
    writer dies of SIGPIPE; for "a credential is in the payloads: fail, else pass" that is a
    false pass. Found through the Azure pack's first Linux run; a helper that reads all
    input replaces them.
  - Not established: everything in L20 and L21.
- **Next step:** a paper login with the sidecar attached; one real message per channel; the
  first runs of the three workflows.

### 2026-11-12 — Azure Log Analytics pack (`azure/`)

- **What changed:** a pack that ships the gateway's events and resource samples (and, opt-in
  and redacted, its raw logs) to the user's own Log Analytics workspace. Bicep: three tables,
  a Direct data collection rule, the publisher role on that rule only, an action group, three
  alert rules (a person is needed; health; dead man), a workbook and a query pack. A pinned
  Vector container reads the log volume read-only (`compose/docker-compose.azure.yml`,
  managed identity or certificate). An optional second template runs the gateway on an Azure
  VM whose settings can change after creation. ADR 0012, workflow `azure-pack.yml`.
- **Result:** the pack's offline suite passes (counts in the pull request): the templates
  compile, the shipper maps and redacts lines of a real gateway run, its rows match the schema
  the templates declare, queries and scenarios type-check, the VM's host scripts run against
  fakes. Nothing has been deployed to Azure.
- **What did NOT work / root cause:**
  - *Alerting on "phase `2fa-pending` for N minutes" never fires.* With the gateway's defaults
    an unanswered prompt times out after about three minutes and the phase flips to `login`
    and back for hours. The rule is built on events: the earliest prompt without a completed
    login after it.
  - *Vector's disk buffers* sometimes held rows read at start-up until the next row of that
    stream arrived (1 start in 20), and kept already-mapped rows across a change of the
    redaction mode. The shipper buffers in memory with end-to-end acknowledgements and saves a
    file position only after delivery: at least once, never zero times while the line is
    still in the gateway's files.
  - *Vector logs the start of every over-long line it discards*, raw text included, whether
    raw logs are shipped or not. Its file source's log target is switched off and counters
    are printed instead; a canary test guards it at every Vector bump.
  - *A byte-order mark in the username file disabled the redaction of the username*: the file
    is normalised on its bytes, as the gateway does, and anything else is refused.
  - *Settings in the VM's customData cannot change after creation*, and `Requires=docker.service`
    stops the gateway when Docker restarts: settings travel in userData and are applied by a
    script; the unit uses `Wants=` and Docker keeps containers alive across its own restart
    (by reading systemd's and Docker's rules; not observed on a VM).
  - *The suite passed on the development host and failed on its first run in GitHub Actions.*
    Several checks compare a tool's output together with its standard error; on a machine
    that has not pulled a helper image yet, Docker's "Unable to find image ... Pulling" notice
    lands in the compared value. Reproduced locally by removing the cached image; the suite
    now pulls every helper image before any check runs, and the workflow runs every group
    even after one failed, so one run shows all that is wrong.
  - *The second run failed on a counter that was there.* The suite runs under `pipefail`, and
    `docker logs | grep -q` fails when the quiet grep exits at its first match and the writer
    dies of SIGPIPE: the check reported "no such counter" 58 seconds into a 90-second wait,
    the moment the counter appeared. Shown on Linux (`seq | grep -q` under pipefail exits
    141); no pipeline in the pack ends in a quiet grep any more, including the Docker key
    check of the VM's `install.sh`, where the same race would have rejected the right key.
  - Not established: everything that needs Azure (L19). The alert queries were type-checked,
    not executed: the only local engine is Microsoft's Kusto emulator, whose licence must be
    accepted by a person first (`KUSTO_EMULATOR_EULA=accept azure/tests/run.sh kql-run`).
- **Next step:** one deployment to a test subscription with a gateway shipping for a day; run
  each alert rule's condition once; run the `kql-run` group.

### 2026-11-12 — A rejected login is not repeated: the latch on the log volume

- **What changed:** when IBKR rejects the credentials the classifier records it in
  `state/login-rejected` (`login_latch_set`). At every later start the entrypoint compares the
  record with the current secret files before IBC is started: unchanged files mean no login,
  phase `needs-human`, the container held (`login_rejected_latched`). A rewritten secret file,
  `LOGIN_LATCH=clear` or a completed login removes the record (`login_latch_cleared`). The
  preflight has a check `login_latch`. New setting `LOGIN_LATCH` (`on`, `clear`, `off`). ADR
  0016.
- **Result:** unit and container suites green (counts in the pull request). In the container
  suite a recorded rejection stops the next start before any Java process exists, the
  container stays up and unhealthy, the resource samples go on, and rewriting the password
  file lets IBC start again.
- **What did NOT work / root cause:** (1) *the hold in phase `needs-human` ended with the
  container.* A restart policy, a reboot or a start task made a new attempt with the same
  rejected credentials at every start; a review of the Windows host kit found the path, and
  it existed on every host. (2) *A hash of the password was not an option*, keyed or not: the
  key would lie next to it on the volume. The latch therefore identifies the secret FILES by
  their modification times, which is why credentials in plain variables need an explicit
  `LOGIN_LATCH=clear`. (3) *The preflight must not fail for a held latch*: a failed preflight
  makes the container exit, and the restart policy would then loop for ever. It warns; the
  entrypoint holds. (4) *Two container checks could not fail*: `pgrep -f ibcalpha.ibc` inside
  `bash -c` matches the shell that runs it. The new "no Java process" check failed for that
  reason, which showed that the older "IBC/Gateway Java process running" check had always
  passed for it. Both now look at a process named `java` and its command line.
- **Next step:** observe one real cycle of rejection, correction and login; collect real logs
  of other rejections (expired password, locked account) and decide whether they set the
  latch too (L18).

### 2026-11-12 — Client kit: several gateways per host, readiness samples, gnzsnz converter

- **What changed:** new files, plus their entries in the README, the migration guide, the
  variable reference and CI. `compose/docker-compose.multi.yml` (live and paper side by side, a
  commented block for further usernames) with `compose/README.md`;
  `scripts/check-compose-usernames.sh`; `examples/` (`wait-for-gateway.sh`,
  `compose-with-client.yml`, a Python and a C# read-only client, the readiness rules in plain
  words); `scripts/migrate-from-gnzsnz.sh`; `tests/compose/run.sh` and bats tests for all of it.
- **Result:** compose suite 57/57; CI-script suite 83/83; unit suite 411/411 inside the image;
  Python sample 136 tests with ruff, black and mypy strict clean; C# logic 88 tests, 0
  warnings. Measured with the real ib_async against a stand-in gateway: a read-only connection
  sends start-API, a positions request and the server time, nothing else.
- **What did NOT work / root cause:**
  - *ib_async is not silent by itself.* `connectAsync(readonly=True, fetchFields=StartupFetchNONE)`
    still requests positions; its error handler opens a new, never-cancelled account-summary
    subscription on every 1102 (IBKR allows two); its `timeout` applies to each connect step
    separately; its loggers print IBKR's message text verbatim. The sample detaches the handler,
    puts one deadline around the connect and silences those loggers.
  - *IBKR's C# client cannot be shipped.* It is IBKR's licensed software and not an official
    NuGet package, so the adapter project takes the path of the user's own `CSharpAPI.dll` and
    sits outside the solution; the logic is tested behind `IBrokerSession` without it. IBKR's
    threads still call back after a disconnect, so each connection has its own wrapper object.
  - *An `internal: true` network alone cuts the gateway off from IBKR*: the example gives the
    gateway a second network for its way out.
  - *A converted `.env` did not apply through `env_file:` alone*: the reference compose
    interpolates four variables from the compose env file and passes nothing else on.
  - *`docker compose down` without `--profile` stops nothing* for the multi-gateway file.
  - *A bash-only watchdog for the handshake probe was dropped*: killing the subshell leaves a
    blocked `dd` behind; `timeout` ends the whole group.
  - *The converter's copy of the preflight's variable names went stale within a day*: three
    branches added variables after it was written, and only its own test noticed. The copy
    stays (the converter must run outside the image); the test is the guard.
  - Not established: any of this against a real IB Gateway; the C# adapter against a TWS API
    release other than 10.48.01.
- **Next step:** run `wait-for-gateway.sh` and both clients against a logged-in paper gateway.

### 2026-11-12 — Optional allowlist for the relay (`RELAY_ALLOW_CIDR`)

- **What changed:** `RELAY_ALLOW_CIDR` (one IPv4 network) makes the relay serve peers in that
  network only (socat `range=`). A peer outside it is closed without a byte of the API and
  reported as `relay_refused`: the first at once, later ones as one count per
  `RELAY_REFUSED_REPORT_S` (60 s), so a port scan cannot flood the events. An unusable value
  stops the start (`config_invalid`; the preflight reports it as a failure of
  `relay_exposure`). Unset, the relay is started exactly as before.
- **Result:** unit tests green (counts in the pull request), two of them with the image's real
  socat: a peer inside the network is relayed, a peer outside gets nothing and is reported.
- **What did NOT work / root cause:** (1) several networks are not possible with socat: a
  second `range=` is silently ignored (measured with socat 1.8.1.1), so the option takes
  exactly one and refuses a comma. (2) The allowlist cannot separate clients that arrive
  through a published port on Docker Desktop: the relay sees the bridge gateway
  (`172.17.0.1` in the measurement), not the client. It is a second line for clients on a
  shared Docker network, not a replacement for the port binding (L17). (3) socat does not
  start at all with a log file it cannot open, so the relay tests the file first and runs
  without reports rather than without a relay. (4) A test of mine hung instead of failing:
  a start that should have been refused left a supervisor that held the pipe of bats' `run`;
  the test now writes to a file and the teardown ends stray supervisors.
- **Next step:** measure the peer address on Docker Engine with a remote client (L17).

### 2026-11-12 — Qualification: one real paper login per image, and an API-level health check

- **What changed:** (1) `api-handshake.sh` sends the TWS API version handshake to the loopback
  API port and reads the server version; it sends nothing else (no `startApi`, no client id, no
  request). (2) `HEALTHCHECK_API=handshake` makes the container health check use it; the
  default stays `port`. (3) `scripts/qualify-paper.sh` starts one image with paper credentials
  from secret files, waits for phase `logged-in`, checks health, the handshake through the
  relay, the event file, the resource samples and a graceful stop, and writes
  `qualify-out/result.json` (`brokersre.qualification.v1`). It makes one login attempt and
  never answers a second factor. (4) Workflow `qualify-paper.yml`: dispatched by hand, from
  `main`, for an image digest, in the environment `paper-qualification` (required reviewer);
  it can attach the result to the image as an attestation. ADR 0014; invariant 9 now names
  this one sanctioned login.
- **Result:** unit and container suites green (counts in the pull request). The script's
  failure path is proven offline (`--network none`: result `fail`, reason recorded, container
  removed, exit 1). The handshake is proven against stand-in servers (answer, silence, garbage,
  closed port). The success path is **not** proven: no login has succeeded on this image yet.
- **What did NOT work / root cause:** (1) the first real paper login was rejected by IBKR
  ("Unrecognized Username or Password"); the image passed the credentials through unaltered
  (compared byte for byte with the rendered configuration), so the attempt was not repeated: a
  second wrong attempt only moves the account towards a lockout. (2) A health check on the
  open port alone reports healthy for a Gateway whose API thread hangs; the handshake closes
  that gap, but it stays opt-in until a real session shows it is free of side effects (L15).
  (3) `qualify-paper.sh` was first written before its test ran; the test was then run with the
  script's checks removed and failed for the right reason before the checks went back in.
- **Next step:** a first qualified run with credentials IBKR accepts (L16); after three
  recorded passes, move `stable` only when a `qualified-paper` attestation exists (L04).

### 2026-11-12 — Pattern table corrected from IBC's source; phase writes serialised and held while the gateway ends

- **What changed:** (1) three rows of `ibc-patterns.tsv`: `login_completed` is anchored at the
  end of the line, `daily_restart` matches the start script's real line
  (`autorestart file found at <path>: authentication will not be required`), and
  `relogin_required` matches the dialog only. (2) `phase_write` in `log.sh` is now the only
  writer of `state/phase`: writes are serialised by a lock, each uses a temporary file of its
  own, and the classifier's writes are held back while the phase is `stopping`, `stopped` or
  `exited`. (3) Two timing-sensitive tests wait longer or for their own processes only.
- **Result:** unit suite green (counts in the pull request). A stop of a logged-in Gateway can
  no longer flip the phase back to `logged-in`, so the gated relay stays closed while the
  Gateway exits.
- **What did NOT work / root cause:** the first v2 table was written from single lines of
  IBC's source without searching for every place that writes similar text. (a) `StopTask.java`
  logs `Login has completed: exiting via [File, Close] menu` when it stops a logged-in
  Gateway; the unanchored row read that as a login and set `logged-in` during shutdown, which
  would have reopened the relay. (b) The autorestart line is an `echo` of `ibcstart.sh` with
  no `IBC:` prefix, so the `daily_restart` row could never match. (c) IBC logs the Re-login
  dialog and its own `Re-login to session`, so one re-login was two events. All three were
  found by the paired change in the BrokerSRE agent, which re-read the source; none could show
  in the tests here, because the synthetic fixture had been written from the same wrong
  assumptions. Separately, the entrypoint and the classifier wrote the phase through the same
  temporary file name without a lock: a rename of one writer could publish the half-written
  file of the other. Also learned: a unit run through the Windows file share took an hour
  (listing 500 files: 42 s), and one relay test missed its 5 s budget under that load.
- **Next step:** real lines for these rows from a successful session (L01, L09); the agent's
  vendored copy of the table is refreshed after this merges.

### 2026-11-12 — Log contract v2: events on the volume, `needs-human`, gated relay, preflight, resource samples

- **What changed:** (1) every event is written to stdout and, as the identical line, to
  `events/events.jsonl`, with a per-start `boot_id` and a gap-free `seq`; `container_start` and
  `config_rendered` carry structured `data` (versions; a fingerprint of the non-secret
  configuration). (2) New phase `needs-human` for a rejected login and for the optional
  second-factor cap `TWOFA_MAX_PROMPTS`; the entrypoint holds the container up in that phase.
  (3) `unknown_window` for a window that neither the pattern table nor the list of titles IBC
  handles knows. (4) The relay listens only while the phase is `logged-in`
  (`RELAY_MODE=gated`). (5) `JAVA_HEAP_MB` sets the heap at run time (number or `auto`); the
  JVM exits on OutOfMemoryError. (6) `doctor`: a preflight as a command and at every start.
  (7) `sampler.sh`: `metrics/metrics.jsonl` from the container's own cgroup and `/proc`, with
  the events `oom_kill`, `memory_high`, `disk_low`, `login_stalled`. ADR 0013, schema
  `log-event.v2.schema.json`, `docs/log-contract.md` rewritten for v2.
- **Result:** unit suite and container suite green (counts in the pull request); in a real
  offline run the events are numbered 1..13 without a gap across the entrypoint, the preflight,
  the classifier and the relay, the Gateway itself reports the 1024 MB heap that
  `JAVA_HEAP_MB=1024` asked for, the relay refuses connections before a login, and the last
  resource sample is written at shutdown.
- **What did NOT work / root cause:**
  - *The first heap resolver printed its result and was called with a redirect*, so its error
    event would have gone into a temporary file instead of stdout; it now sets a variable.
  - *The time-format rule first given to the preflight was wrong.* IBC parses the restart time
    with the pattern `hh:mm a`: `1:05 AM` is rejected and `00:15 AM` accepted, the opposite of
    the lenient pattern in the brief. Found by running IBC's own parser from the image's
    `IBC.jar` instead of trusting the documentation.
  - *A preflight that can stop a working gateway is worse than none.* Three checks (an
    unverifiable time zone, a percentage-only disk rule, a crashed check) could have stopped a
    container that runs today; they are warnings now, and a failure is reserved for conditions
    under which the gateway cannot work or would send IBKR a wrong login.
  - *An out-of-memory kill of the Gateway would not have been reported*: IBC exits, the
    container ends and its cgroup is gone before the next 30 s sample. The sampler now takes a
    last sample when it is stopped, and the entrypoint waits for it (bounded, then SIGKILL).
  - *A suspected "zombie child" bug in the relay supervisor was not real.* The failing test had
    a race of its own (it read a counter once instead of polling); both liveness checks passed
    every time once the test was fixed, so the extra helper was removed again.
  - *A fingerprint of the configuration that included the credentials* would let a reader of the
    events test password guesses offline; the fingerprint leaves them out, and a test proves it.
  - Not established: everything that needs a successful login (see `docs/limitations.md` L09
    to L13).
- **Next step:** the qualification script and workflow (ADR 0014), then the sidecar, which reads
  exactly this contract.

### 2026-11-12 — First real login attempt: read-only login hang fixed, Windows-written secrets, real log patterns

- **What changed:** the image met IBKR's login servers for the first time (IB Gateway 10.50.1g,
  paper mode, operator-run on a workstation; CI still never logs in). Seven fixes, each with
  tests written first: (1) `java-env.sh` gives the Gateway JVM a writable `user.home` on the
  settings volume through `_JAVA_OPTIONS`; (2) `file_env` accepts secret files written on
  Windows (trailing CR/LF and a UTF-8 byte-order mark removed; UTF-16 and empty files refused
  with `secret_unreadable`); (3) the username and password are escaped for IBC's `.properties`
  parser; (4) `ibc-patterns.tsv` matches what IBC really logs; (5) the VNC password no longer
  appears in a process argument list; (6) `rotating-append.sh` caps `ibc.log` and the mirrored
  Gateway logs, and the mirror resumes after a restart instead of copying everything again;
  (7) the reference compose is hardened (`cap_drop: [ALL]`, `stop_grace_period: 90s`, open-file,
  process, memory and log-size limits, image and secrets directory overridable) and is now
  started as shipped by the container suite. The README quick start is rewritten (PowerShell
  5.1/7 and bash, secrets under `compose/secrets/`), and its version table is generated from
  `versions.json` by `scripts/readme-versions.sh` (checked in CI, regenerated by the detect
  workflows).
- **Result:** unit suite 73/73 inside the image, container suite 37/37, CI-script suite 31/31.
  A login with a made-up username under `read_only: true` and `cap_drop: ALL` reaches IBKR's
  "Unrecognized Username or Password" dialog (before the fix it never got that far); a graceful
  stop took 2 s. The credential escaping round-trips byte for byte through
  `java.util.Properties.load` in a JDK 25 container. The secret-writing commands of the quick
  start produce the exact UTF-8 bytes under Windows PowerShell 5.1 and PowerShell 7.6.
- **What did NOT work / root cause:**
  - *Login never completed under a read-only root filesystem, and nothing was logged.* The
    Gateway writes `.hwid` into the JVM's `user.home` during login; the image home is read-only,
    so the Gateway opened a modal "directory not accessible" warning that IBC does not handle
    and the login thread waited behind it forever (thread dump: `warnDirectoryNotAccessible`).
    The Dockerfile's two `-D` lines in `ibgateway.vmoptions` were meant to redirect Java's
    paths, but `ibcstart.sh` drops every `-D` line and clears `JAVA_TOOL_OPTIONS`, so they never
    reached the JVM (`/proc/<pid>/cmdline`). They are removed; `_JAVA_OPTIONS` is the mechanism
    that works. The offline smoke test could not have caught this: the write happens only after
    the Gateway has connected to IBKR.
  - *`login_dialog` never fired and one rejected login produced three events.* The login window
    is titled "IBKR Gateway", not "IB Gateway", and IBC logs each dialog as Opened, Activated
    and Focused. The synthetic fixture had encoded the same wrong assumptions as the patterns.
  - *The quick start could not work on any system:* it wrote the secrets to `./secrets/` while
    the compose file reads `compose/secrets/`; Docker then mounted empty directories as secrets
    and the container restarted in a loop with `config_missing`.
  - *A first rotation design (copy and truncate behind `tee`) was dropped* because lines written
    between the copy and the truncate are lost; the writer now owns the file and renames it
    between two lines.
  - Not established: a successful login. The paper credentials supplied for the test were
    rejected by IBKR (the image passed them unaltered, verified by hash), so the patterns for
    second factor, login completion, daily restart and competing session, and the paths written
    after login, are still unconfirmed (L01 to L03 are "partly resolved").
- **Release records superseded by this merge** (it changes `rootfs/**` and the Dockerfile, so
  `publish.yml` republishes both channels): `v10.50.1g-stable` image
  `sha256:693bd6306d94708a87e5b0c43180874f671010a5edf142796eb8f46f51e869ea`, assets
  `digests-stable.json` `68c4f964…0556` / `sbom-stable.cdx.json` `be3cbe4e…5111`;
  `v10.51.1e-latest` image
  `sha256:275717e7466f30e5615cc79f7b301171da3bdb740d39a72625dd5b0c567c8052`, assets
  `digests-latest.json` `eb4f0af6…f1de` / `sbom-latest.cdx.json` `a55c6104…5c43`.
- **Next step:** repeat the login with working paper credentials and record a successful
  session (closes L01 to L03); then contract v2 (events on the log volume, `needs-human`
  phase, preflight `doctor`), tracked in `tasks/todo.md`.

### 2026-11-11 — Stable updates merge themselves; archive pre-fetch in CI; re-uploads reported

- **What changed:** `detect-releases.yml` hashes both installers daily and hands the policy to
  `scripts/release-decision.sh` (bats-tested): a new `stable` version's pull request gets
  auto-merge (with `BOT_TOKEN`), a new `latest` version waits for a human, and different bytes
  under the pinned version open an `ibkr-reupload` issue. `ci.yml` and `publish.yml` pre-fetch
  archived installers through `scripts/prefetch-installers.sh`, which keeps only copies matching
  the pin. Auto-merge is allowed on the repository; the private archive got its first commit and
  the installers pinned today (`ibgateway-stable@10.50.1g`, `ibgateway-latest@10.51.1e`). README
  sections for following releases and for creating the tokens; ADR 0009 (owner decision).
- **Result:** 23 bats tests (release policy, archive pre-fetch) pass; actionlint, shellcheck and
  shfmt clean.
- **Independent review of PR #7, fixed before merge:** (1) the daily run re-enabled auto-merge a
  human had turned off (create-pull-request returns the number of an existing PR), so auto-merge
  is now requested only when the run creates the PR, with the kill switch `STABLE_AUTOMERGE=false`;
  (2) a lower version, or a new label over unchanged bytes, would have merged itself, so
  auto-merge now needs a higher version (`sort -V`) and both installers changed; (3) a closed
  re-upload issue would reopen daily and the new bytes were never archived, so issues are keyed
  by the bytes (any state) and the bytes are archived under `ibgateway-<channel>@<version>-<8 hex
  of x64><8 hex of arm>` (both hashes, so an arm-only re-upload cannot overwrite another), which
  the pre-fetch also reads, and an unchanged archive is not uploaded again each day; (4) a
  republished version kept stale release notes,
  so `publish.yml` now rewrites them. Also: refusals go to stderr only (stdout feeds
  `GITHUB_OUTPUT`), `add-paths: versions.json`, and a missing pre-fetch destination is refused.
- **Release records superseded by this merge** (it changes `publish.yml`, which republishes both
  channels): `v10.50.1g-stable` image
  `sha256:2479cc941831a5ba9f3b810a118b8677fd082fbe2b1b8172ce142a84297439a4` (created
  2026-11-11T06:57:14Z), assets `3dafe62f…eb721` / `c8dd6a37…a9c67`; `v10.51.1e-latest` image
  `sha256:5eecf3a8fefd09908437dd6879135eda55642d38fb6c8a39bf19d0ca6cead78e` (created
  2026-11-11T06:56:31Z), assets `78899cb6…21d8f` / `8e955347…c3e1`.
- **What did NOT work / root cause:** the archive could never have worked: the repository had no
  commit, so creating a release failed with "Repository is empty" (found while seeding it by
  hand). `fetch-installer.sh` aborts the build when a pre-fetched copy does not match the pin, so
  a stale archive copy would have failed builds instead of falling back to IBKR's URL; the
  pre-fetch now drops such copies. CI never pre-fetched at all, which is why PR #6 failed once
  IBKR moved `stable`.
- **Next step:** the owner creates `BOT_TOKEN`, `ARCHIVE_WRITE_TOKEN` and `ARCHIVE_READ_TOKEN`
  (README); until then pull requests are opened with `GITHUB_TOKEN`, run no CI and do not
  auto-merge, and nothing is archived automatically.

### 2026-11-11 — `stable` moves to IBKR 10.50.1g

- **What changed:** PR #5 (opened by `detect-releases.yml`, merged by owner decision) pins
  `stable` to 10.50.1g (build `20261109 16:10:13`; x64
  `13dc8bb05cbcec8d1b0bb0b25748447cf85863fb4b94361f57fcd350f35c7a9c`, arm
  `cbd1e3f9368dcc9d517e23dd72cf10db4d045e58b46882d01ab528a0d1f8e343`, both re-checked with
  `fetch-installer.sh` against IBKR on 2026-11-11).
- **Result:** publish run 42974878793 created release `v10.50.1g-stable`, image
  `sha256:2479cc941831a5ba9f3b810a118b8677fd082fbe2b1b8172ce142a84297439a4`, and republished
  `latest` 10.51.1e as `sha256:5eecf3a8fefd09908437dd6879135eda55642d38fb6c8a39bf19d0ca6cead78e`;
  both pass `cosign verify`, the CycloneDX attestation check and the Trivy OS gate. The
  `v10.50.1f-stable` release is kept.
- **What did NOT work / root cause:** once IBKR's unversioned `stable` URL served 10.50.1g, `main`
  could no longer build its pinned 10.50.1f (CI of PR #6: `SHA-256 MISMATCH`, actual = the
  10.50.1g hash), and the 10.50.1f installer was never archived. Moving `stable` was the only fix.
- **Release record superseded:** the push also republished `latest`, overwriting the assets of
  `v10.51.1e-latest`: image `sha256:2083e887f4d982ab302b26702104b3f38c69eea817c923e417671c77ece6d37a`
  (created 2026-11-09T20:22:13Z), asset SHA-256 `f4e511b0…9ecc` (`digests-latest.json`) /
  `2d0c0503…5fed` (`sbom-latest.cdx.json`).
- **Next step:** the archive tokens would have kept 10.50.1f buildable; BrokerSRE's `image-pin.yml`
  proposes the new `stable` digest, which waits for the operator-run paper regression (R10).

### 2026-11-11 — GitHub Actions may open pull requests in this repository

- **What changed:** the repository setting "Allow GitHub Actions to create and approve pull
  requests" is on (owner decision 2026-11-11; the default workflow token stays read-only).
- **Result:** "Detect IB Gateway releases" run 42969621084 went green on attempt 3 and updated
  pull request #5 (stable 10.50.1f to 10.50.1g, both SHA-256 values re-checked against IBKR).
- **What did NOT work / root cause:** IBKR shipped stable 10.50.1g; `detect-releases.yml` pushed
  `update-stable-to-10.50.1g` but failed on 2026-11-10 and 2026-11-11 with "GitHub Actions is not
  permitted to create or approve pull requests": `BOT_TOKEN` is not set, so it used
  `GITHUB_TOKEN`, which the setting forbade. Opening #5 by hand did not make the job green:
  peter-evans/create-pull-request tries to create before it updates, and that call was refused.
- **Next step:** a pull request opened with `GITHUB_TOKEN` starts no workflows, so a release PR
  the job opens needs a close and reopen before CI runs; `BOT_TOKEN` (fine-grained PAT) avoids
  that.

### 2026-11-10 — `latest` re-pinned to IBKR's re-upload of 10.51.1e

- **What changed:** `versions.json` `channels.latest.sha256` moves to the installers IBKR serves
  since 2026-11-05 (x64 `e57858252ae21da7395e5c08884639cc45dfc15eed24a7ccd6cf4383d2826ec0`, was
  `b4d57815…0703`; arm `6aa611348ec6709b59a4a966494aa54969c7848249579dccdca0d3a333e908f6`, was
  `f1c29317…fcc5`); version and build time are unchanged because IBKR's manifest still reports
  `10.51.1e`, `20261026 16:53:53`. Owner decision 2026-11-10.
- **Result:** `scripts/fetch-installer.sh` against IBKR's live `latest` URL passes the checksum for
  amd64 and arm64 (2026-11-10); the x64 file hashed the same on two downloads.
- **What did NOT work / root cause:** the publish of PR #3 (run 42686705729) built `stable` but
  failed `latest` with `SHA-256 MISMATCH`: IBKR replaced both `latest` installers on
  2026-11-05 (`Last-Modified` 04:22:15 and 04:23:23 GMT) without changing the version label.
  `detect-releases.yml` compares only `buildVersion`, so it saw no change; the original bytes
  cannot be rebuilt because the private archive is empty (`ARCHIVE_WRITE_TOKEN` was never set).
  Trust is unchanged: the original pin was also taken from IBKR over HTTPS, and IBKR publishes no
  checksums.
- **Release record superseded:** a push publishes both channels (`publish.yml` plan defaults to
  `stable latest`), so this merge also republishes `stable` and overwrites its release assets.
  The record it replaces: `v10.50.1f-stable`, image
  `sha256:aefa03c37b90e5d897854d82a403bc7374d63e4e8af8aa9e325a5a6574b1fb6b` (created
  2026-11-09T19:55:39Z by the publish of PR #3, nothing pins it yet), asset SHA-256
  `9c13c2bd…13d4` (`digests-stable.json`) / `3610bb0a…4d13` (`sbom-stable.cdx.json`).
- **Next step:** merging publishes `latest`; set the archive tokens so installers are kept, and
  make `detect-releases.yml` also compare the installers' SHA-256, so a same-version re-upload
  opens a pull request instead of breaking a publish. A push should publish only the channels
  whose `versions.json` entry changed.

### 2026-11-10 — Runtime stage runs `apt-get upgrade`, so rebuilds patch base packages

- **What changed:** the runtime stage runs `apt-get upgrade -y --no-install-recommends` before
  installing its packages; the Dockerfile header now states that the monthly rebuild patches
  base packages too.
- **Result:** on the pinned `ubuntu:26.04` digest the upgrade moves four packages (apt and
  libapt-pkg7.0 3.2.0 to 3.2.1ubuntu0.1, base-files, libpcre2-8-0), and Trivy 0.70.0 with the
  gate's flags (`--pkg-types os`, CRITICAL/HIGH, `--ignore-unfixed`) goes from 2 HIGH to 0.
- **What did NOT work / root cause:** the Trivy gate failed from 2026-11-09 (Dependabot PR #2,
  run 42595391755) on apt CVE-2026-109518 (HIGH), and the published `stable` digest
  `sha256:a35fcafe…` carries it. A base digest bump was not possible: Docker Hub had not rebuilt
  `ubuntu:26.04` since 2026-10-29, so the pinned digest was already current. The documented
  design ("the monthly rebuild picks them up") did not hold for packages that ship inside the
  base image: `apt-get install` of other packages never upgrades them.
- **Release records superseded by this publish:** a push-triggered publish adds no
  `-rYYYYMMDD` suffix, so it re-uploads the assets of the existing releases with `--clobber`
  (ADR 0008 expects a suffixed tag for a rebuild; follow-up in `tasks/todo.md`). The records it
  replaces, downloaded 2026-11-10 before merge (the images, their keyless signatures and the
  CycloneDX attestations stay in GHCR under these digests):

  | Release | Image digest | Created | Asset SHA-256 (`digests-*.json` / `sbom-*.cdx.json`) |
  |---|---|---|---|
  | `v10.50.1f-stable` | `sha256:a35fcafed0ee2c6857970aef230dfe5df0277cfafe24ef927503a54d0716b885` | 2026-11-01T07:59:03Z | `e55d58bd…6bd28` / `288d8f20…26914` |
  | `v10.51.1e-latest` | `sha256:8fb845fbc6298b8dc51d0a09b95bed837eedfc1bbaa19033c5488c79868c0774` | 2026-11-01T08:00:23Z | `6e7a7f95…91c84` / `5d31c182…2135` |

  Both were built with IBC `3.24.2-rocketedge.1` on `ubuntu:26.04@sha256:6a06111c3b0a8600feadb270aec771dc239bf407b25625f93f44ab00e11f4d3c`.
- **Next step:** after merge, `publish.yml` publishes both channels with the fix; the monorepo
  `image-pin.yml` then opens a pin PR that waits for the operator-run `regression-paper` check
  (C6). Independent review of PR #3 also found that the Buildx GitHub Actions cache is not in
  effect today (0 cached steps); if it is ever repaired, the unchanged apt layer would be reused
  and rebuilds would silently stop patching, so a rebuild must then bust that layer.

### 2026-11-01 — First successful publish of both channels

- **What changed:** `publish.yml` creates the release tag through the release API
  (`gh release create --target`) and verifies the keyless signature and the CycloneDX
  attestation inside the job right after signing; `ci.yml` grants `security-events: write` to
  the job that uploads Trivy SARIF.
- **Result:** CI green on `2f109b8`; Publish run 41285824630 green for
  both channels. Trivy gate: 0 fixable CRITICAL/HIGH in OS packages; vendor jars reported (L08).
  Signature and attestation verified in-job against identity
  `https://github.com/RocketEdge/brokersre-ib-gateway/.github/workflows/publish.yml@refs/heads/main`.
  Releases `v10.50.1f-stable` and `v10.51.1e-latest` carry `digests-<channel>.json` and the SBOM.

  | Channel | Gateway | Digest |
  |---|---|---|
  | stable | 10.50.1f | `sha256:a35fcafed0ee2c6857970aef230dfe5df0277cfafe24ef927503a54d0716b885` |
  | latest | 10.51.1e | `sha256:8fb845fbc6298b8dc51d0a09b95bed837eedfc1bbaa19033c5488c79868c0774` |

- **What did NOT work / root cause:** (1) `git push` of the release tag from the job was
  rejected ("refusing to allow a GitHub App to create or update workflow ... without `workflows`
  permission"): `GITHUB_TOKEN` cannot push a ref whose commit carries workflow files, so the
  tag is now created server-side by the release API. (2) Verification from a workstation fails
  with `DENIED` while the GHCR package is private; in-job verification uses the workflow token
  and records the evidence in the run log. (3) Signing identity is the branch ref
  (`@refs/heads/main`), not a tag ref, because publish runs on pushes to main; the monorepo's
  `image-pin.yml` was corrected to match.
- **Next step:** owner makes the GHCR package public (L07); then anonymous `docker pull` and a
  workstation `cosign verify`; BrokerSRE `image-pin.yml` pins the stable digest.

### 2026-11-01 — Second CI run: secrets directory permissions and the Trivy gate scope

- **What changed:** the container harness makes its temporary secrets directory traversable
  (`chmod 0755`); the Trivy gate in `ci.yml` and `publish.yml` covers OS packages
  (`vuln-type: os`) and a second, non-gating step prints the findings in IBKR's bundled jars;
  limitation L08 records them.
- **Result:** Trivy 0.70.0 locally on image 653f1201000a: 0 fixable OS findings; 12 fixable HIGH
  findings in vendor jars (jackson-core 2.12.3: CVE-2025-52999, CVE-2026-68494, CVE-2026-89425;
  jackson-databind 2.12.3: CVE-2020-36518, CVE-2021-46877, CVE-2022-42003, CVE-2022-42004,
  CVE-2026-54512, CVE-2026-54513, CVE-2026-91776, CVE-2026-91777; commons-io 2.11.0:
  CVE-2024-47554). The harness change is host-side and was not re-run locally; the CI run after
  this commit is its evidence.
- **What did NOT work / root cause:** (1) in CI every container test that needs credentials
  failed with `secret_unreadable`: `mktemp -d` creates a 0700 directory owned by the runner
  user (uid 1001) and Linux bind mounts keep host permissions, so uid 1000 inside the container
  could not traverse it; Docker Desktop on the Windows development host masks host permissions
  and hid the bug. (2) The publish Trivy gate failed on the vendor jars above, which this image
  cannot replace without modifying IBKR's application.
- **Next step:** watch the rerun, `cosign verify` the stable digest, record the run ids.

### 2026-11-01 — First CI and publish runs: four set-up failures fixed

- **What changed:** `ci.yml` names its test image `TEST_IMAGE`; `publish.yml` re-exports the bake
  variables into `GITHUB_ENV` unquoted; the advanced `codeql.yml` was removed because the
  organisation's default CodeQL setup already covers this repository; `trivy-action` is pinned
  to the existing `v0.36.0` tag.
- **Result:** no script changed, so the local evidence of the previous entry stands (bats 25/25,
  container suite 28/28); the CI and publish runs after this change are the next evidence.
- **What did NOT work / root cause:** (1) `aquasecurity/trivy-action@0.36.0` does not exist (the
  tag is `v0.36.0`), so every job referencing it failed at set-up. (2) `docker buildx bake` reads
  a variable named `IMAGE` from the environment; the CI job exported `IMAGE=...:stable` for the
  test harness and bake built tags such as `...:stable:10.50.1f`. (3) `GITHUB_ENV` takes
  `NAME=value` literally; piping the `export NAME='value'` lines of `scripts/bake-env.sh`
  through `sed 's/^export //'` kept the quotes and produced the tag `...:'10.51.1e'`. (4) GitHub's
  default CodeQL setup is enabled on this repository by the organisation security configuration
  and rejects SARIF from an advanced workflow.
- **Next step:** watch `ci.yml` and `publish.yml`, then `cosign verify` the stable digest and
  record the run ids.

### 2026-11-01 — Read-only hardening: tmpfs ownership, structured fail-fast, harness fixes

- **What changed:** The entrypoint verifies that `LOG_DIR`, `RUN_DIR` and `TWS_SETTINGS_PATH` are
  writable before anything else and exits with the structured stdout event `dirs_not_writable`;
  the reference compose and the container harness mount tmpfs with `uid=1000,gid=1000,mode=0750`;
  the harness validates the log contract with the image's own `jq` (the host may have none) and
  gained a negative test for a root-owned tmpfs; shellcheck/shfmt findings were cleared and a
  `.markdownlint.yaml` added.
- **Result (fresh, local, amd64 image 653f1201000a):** bats inside the image 25/25; container
  suite 28/28 (structure, render, read-only positive and negative, IBC smoke offline, command
  server off); shellcheck 0.9.0 and 0.11.0 clean; shfmt clean; hadolint clean.
- **What did NOT work / root cause:** (1) `--tmpfs /run/brokersre` is root-owned 0755, so the
  uid-1000 entrypoint died on `mkdir` with a bare stderr line and the read-only test only saw
  "relay never listened"; fixed by mount options plus a fail-fast check. (2) bats-core cloned on
  Windows carried CRLF (`core.autocrlf=true`), so `env` inside the image failed on
  `bash\r`; MSYS `grep` does not report carriage returns, `file(1)` does; the clone was redone
  with `core.autocrlf=false` and the repo's `.gitattributes` forces LF. (3) The harness used the
  host's `jq`, absent on Windows, so valid JSON was reported as a contract violation.
- **Next step:** first push, CI, `publish.yml`, cosign verification; owner makes the GHCR package
  public; BrokerSRE pins the digest.

### 2026-11-01 — Initial image: single Dockerfile, pinned inputs, offline test suites

- **What changed:** Created the repository from the gnzsnz/ib-gateway-docker design with a single
  parametrised Dockerfile driven by `versions.json` (ubuntu:26.04 by digest, Gateway 10.50.1f /
  10.51.1e with RocketEdge-computed SHA-256 per architecture, IBC 3.24.2 from
  RocketEdge/ibc `3.24.2-rocketedge.1`), no sudo, read-only root filesystem support,
  HEALTHCHECK, IBC command server on loopback, JSON stdout + raw logs on a shared volume with a
  phase file, tini, bats unit suite run inside the image, offline container tests, publish /
  rebuild / detect workflows with Trivy, SBOM, cosign and provenance.
- **Result:** see the test and build evidence in the first pull request / CI run.
- **What did NOT work / root cause:** recorded below as it happens.
- **Next step:** first `publish.yml` run; owner makes the GHCR package public; BrokerSRE pins
  the digest through `image-pin.yml`.
