# Fake IB Gateway installers for the bats suites (loaded with `load fake-installer`). No IBKR
# code: a shell script laid out like IBKR's install4j installer, so that
#   - the build helper can read its stamp the way it reads a real one: a line starting with
#     `tail -c <N> "$prg_dir/${progname}"` in the header, and a gzip tar of N bytes at the end of
#     the file holding `i4jparams.conf` (the real 10.50.1h installer: N = 105389836);
#   - the Dockerfile's setup stage can "install" it: `<installer> -q -dir <dir>` writes
#     <dir>/.install4j/i4jparams.conf, <dir>/ibgateway.vmoptions (with -Xmx768m, which the
#     Dockerfile rewrites) and an executable <dir>/ibgateway.

# make_fake_installer OUT APPLICATION_NAME APPLICATION_VERSION MEDIA_NAME [FILLER]: write a fake
# installer to OUT. FILLER (optional) is extra text in the archive, so two installers with the
# same stamp can still have different bytes (a re-upload under the same version).
make_fake_installer() {
  local out="$1" name="$2" app_version="$3" media="$4" filler="${5:-}" payload_dir size
  payload_dir="$(mktemp -d)"
  cat >"${payload_dir}/i4jparams.conf" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<config install4jVersion="12.0.5" install4jBuild="12102" type="unix" archive="false" bitness="undefined">
  <general applicationName="${name}" applicationVersion="${app_version}" mediaSetId="1335" status="LCOK" mediaName="${media}" jreVersion="25.0.5.0.3-zulu" />
</config>
EOF
  printf '%s\n' "${filler}" >"${payload_dir}/filler.txt"
  tar -czf "${payload_dir}/payload.tar.gz" -C "${payload_dir}" i4jparams.conf filler.txt
  size="$(wc -c <"${payload_dir}/payload.tar.gz" | tr -d ' ')"
  # The header is written with printf so that ${size} is the only expansion in it.
  {
    printf '%s\n' '#!/bin/sh' \
      '# Fake IB Gateway installer for tests (install4j layout, no IBKR code).' \
      'prg_dir=$(dirname "$0")' \
      'progname=$(basename "$0")' \
      'dir=""' \
      'while [ $# -gt 0 ]; do case "$1" in -dir) dir="$2"; shift 2 ;; *) shift ;; esac; done' \
      '[ -n "$dir" ] || { echo "fake installer: -dir required" >&2; exit 1; }' \
      'tmp=$(mktemp -d)' \
      'cd "$tmp" || exit 1'
    printf 'tail -c %s "$prg_dir/${progname}" > sfx_archive.tar.gz 2> /dev/null\n' "${size}"
    printf '%s\n' 'tar -xzf sfx_archive.tar.gz i4jparams.conf || exit 1' \
      'mkdir -p "$dir/.install4j"' \
      'cp i4jparams.conf "$dir/.install4j/i4jparams.conf"' \
      'printf -- "-Xmx768m\n" > "$dir/ibgateway.vmoptions"' \
      'printf "#!/bin/sh\nexit 0\n" > "$dir/ibgateway"' \
      'chmod +x "$dir/ibgateway"' \
      'cd / && rm -rf "$tmp"' \
      'exit 0'
    cat "${payload_dir}/payload.tar.gz"
  } >"${out}"
  chmod +x "${out}"
  rm -rf "${payload_dir}"
}

# sha256_of FILE: print the SHA-256 of FILE (lower-case hex).
sha256_of() {
  sha256sum "$1" | cut -d' ' -f1
}
