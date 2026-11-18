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
# shellcheck disable=SC2016  # the single-quoted lines are the installer's own script: their $ expand when it runs, not here
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

# make_fake_installer_cut OUT APPLICATION_NAME APPLICATION_VERSION MEDIA_NAME: like
# make_fake_installer, but the archive holds 1 MiB of random bytes after i4jparams.conf and is
# cut off in their middle: only a reader that stops once it has i4jparams.conf can read the
# stamp (the build helper does, so it never decompresses IBKR's whole 105 MB archive).
make_fake_installer_cut() {
  local out="$1" full payload_dir size
  make_fake_installer "${out}.full" "$2" "$3" "$4"
  payload_dir="$(mktemp -d)"
  size="$(sed -n -E 's/^tail -c ([0-9]+) .*/\1/p' "${out}.full")"
  tail -c "${size}" "${out}.full" | tar -xzf - -C "${payload_dir}" i4jparams.conf
  head -c 1048576 /dev/urandom >"${payload_dir}/filler.bin"
  tar -czf "${payload_dir}/payload.tar.gz" -C "${payload_dir}" i4jparams.conf filler.bin
  full="$(wc -c <"${payload_dir}/payload.tar.gz" | tr -d ' ')"
  size=$((full / 2))
  {
    head -c "$(($(wc -c <"${out}.full") - $(sed -n -E 's/^tail -c ([0-9]+) .*/\1/p' "${out}.full")))" "${out}.full" \
      | sed -E "s/^tail -c [0-9]+ /tail -c ${size} /"
    head -c "${size}" "${payload_dir}/payload.tar.gz"
  } >"${out}"
  chmod +x "${out}"
  rm -rf "${payload_dir}" "${out}.full"
}
