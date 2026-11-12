#!/usr/bin/env bash
# shellcheck disable=SC2034  # the DES tables and work arrays are read through namerefs
# A minimal VNC client (RFB 3.8, VNC authentication) in bash, for tests only.
#
# Why it exists: the gateway image ships x11vnc but no VNC client, and the container suite must
# prove with the real x11vnc that a person who connects to the break-glass console becomes an
# event, that view-only really discards input, and that a wrong password gets nobody in. x11vnc
# runs its -afteraccept hook only after the client authenticated and sent ClientInit, so the
# test has to speak the protocol that far, including the DES step of VNC authentication. The
# script needs bash, dd, od and tr only, which the image has; nothing is added to the image.
#
# Usage: vnc-client.sh --password-file FILE [--host H] [--port P] [--hold SECONDS] [--move X Y]
#   --password-file  file whose first line is the VNC password (never an argument: `ps`)
#   --host, --port   default 127.0.0.1 and 5900
#   --hold           keep the session open this long before leaving (default 1)
#   --move X Y       send one pointer event that moves the pointer to X,Y (no button)
# Run it inside the gateway container, for example:
#   docker exec -i <container> bash -s -- --password-file /run/secrets/vnc-password <vnc-client.sh
# Output and exit status (the password is never printed):
#   0  "ok: session established (desktop WxH)"
#   1  "fail: ..." (cannot connect, not an RFB 3.8 server, no VNC authentication offered, ...)
#   2  usage error
#   3  "rejected: the server refused the password"
# With VNC_CLIENT_LIB=1 in the environment the file only defines its functions (unit tests).
#
# The protocol, as far as it is spoken here (RFC 6143):
#   server "RFB 003.008\n" -> client the same -> server: count and list of security types ->
#   client: 2 (VNC authentication) -> server: 16 random bytes -> client: those bytes encrypted
#   with DES, the key being the password's first eight bytes with the bits of every byte
#   mirrored -> server: 4-byte result (0 = accepted) -> client: ClientInit (shared) ->
#   server: ServerInit (width, height, pixel format, name).
set -u

# DES tables (FIPS 46-3), flat and 0-based in bash; the permutation entries are bit positions
# counted from 1, as in the standard. des_permute reads its input from index 1.
DES_IP=(58 50 42 34 26 18 10 2 60 52 44 36 28 20 12 4 62 54 46 38 30 22 14 6 64 56 48 40 32 24 16 8
  57 49 41 33 25 17 9 1 59 51 43 35 27 19 11 3 61 53 45 37 29 21 13 5 63 55 47 39 31 23 15 7)
DES_FP=(40 8 48 16 56 24 64 32 39 7 47 15 55 23 63 31 38 6 46 14 54 22 62 30 37 5 45 13 53 21 61 29
  36 4 44 12 52 20 60 28 35 3 43 11 51 19 59 27 34 2 42 10 50 18 58 26 33 1 41 9 49 17 57 25)
DES_E=(32 1 2 3 4 5 4 5 6 7 8 9 8 9 10 11 12 13 12 13 14 15 16 17
  16 17 18 19 20 21 20 21 22 23 24 25 24 25 26 27 28 29 28 29 30 31 32 1)
DES_P=(16 7 20 21 29 12 28 17 1 15 23 26 5 18 31 10 2 8 24 14 32 27 3 9 19 13 30 6 22 11 4 25)
DES_PC1=(57 49 41 33 25 17 9 1 58 50 42 34 26 18 10 2 59 51 43 35 27 19 11 3 60 52 44 36
  63 55 47 39 31 23 15 7 62 54 46 38 30 22 14 6 61 53 45 37 29 21 13 5 28 20 12 4)
DES_PC2=(14 17 11 24 1 5 3 28 15 6 21 10 23 19 12 4 26 8 16 7 27 20 13 2
  41 52 31 37 47 55 30 40 51 45 33 48 44 49 39 56 34 53 46 42 50 36 29 32)
DES_SHIFTS=(1 1 2 2 2 2 2 2 1 2 2 2 2 2 2 1)
# The eight S-boxes, 64 entries each: row (outer bits) times 16 plus column (inner bits).
DES_S=(
  14 4 13 1 2 15 11 8 3 10 6 12 5 9 0 7 0 15 7 4 14 2 13 1 10 6 12 11 9 5 3 8
  4 1 14 8 13 6 2 11 15 12 9 7 3 10 5 0 15 12 8 2 4 9 1 7 5 11 3 14 10 0 6 13
  15 1 8 14 6 11 3 4 9 7 2 13 12 0 5 10 3 13 4 7 15 2 8 14 12 0 1 10 6 9 11 5
  0 14 7 11 10 4 13 1 5 8 12 6 9 3 2 15 13 8 10 1 3 15 4 2 11 6 7 12 0 5 14 9
  10 0 9 14 6 3 15 5 1 13 12 7 11 4 2 8 13 7 0 9 3 4 6 10 2 8 5 14 12 11 15 1
  13 6 4 9 8 15 3 0 11 1 2 12 5 10 14 7 1 10 13 0 6 9 8 7 4 15 14 3 11 5 2 12
  7 13 14 3 0 6 9 10 1 2 8 5 11 12 4 15 13 8 11 5 6 15 0 3 4 7 2 12 1 10 14 9
  10 6 9 0 12 11 7 13 15 1 3 14 5 2 8 4 3 15 0 6 10 1 13 8 9 4 5 11 12 7 2 14
  2 12 4 1 7 10 11 6 8 5 3 15 13 0 14 9 14 11 2 12 4 7 13 1 5 0 15 10 3 9 8 6
  4 2 1 11 10 13 7 8 15 9 12 5 6 3 0 14 11 8 12 7 1 14 2 13 6 15 0 9 10 4 5 3
  12 1 10 15 9 2 6 8 0 13 3 4 14 7 5 11 10 15 4 2 7 12 9 5 6 1 13 14 0 11 3 8
  9 14 15 5 2 8 12 3 7 0 4 10 1 13 11 6 4 3 2 12 9 5 15 10 11 14 1 7 6 0 8 13
  4 11 2 14 15 0 8 13 3 12 9 7 5 10 6 1 13 0 11 7 4 9 1 10 14 3 5 12 2 15 8 6
  1 4 11 13 12 3 7 14 10 15 6 8 0 5 9 2 6 11 13 8 1 4 10 7 9 5 0 15 14 2 3 12
  13 2 8 4 6 15 11 1 10 9 3 14 5 0 12 7 1 15 13 8 10 3 7 4 12 5 6 11 0 14 9 2
  7 11 4 1 9 12 14 2 0 6 10 13 15 3 5 8 2 1 14 7 4 10 8 13 15 12 9 0 3 5 6 11
)

# des_bits HEX NAME: store the bits of the hex string HEX, most significant first, in the array
# NAME at index 1 and up (index 0 is a filler, so a table entry is an index).
des_bits() {
  local _hex="$1" _i _v
  local -n _bits="$2"
  _bits=(0)
  for ((_i = 0; _i < ${#_hex}; _i++)); do
    _v=$((16#${_hex:_i:1}))
    _bits+=($(((_v >> 3) & 1)) $(((_v >> 2) & 1)) $(((_v >> 1) & 1)) $((_v & 1)))
  done
}

# des_permute TABLE SOURCE TARGET: TARGET[1..n] = SOURCE[TABLE[0..n-1]] (arrays by name).
des_permute() {
  local -n _table="$1" _source="$2" _target="$3"
  local _position
  _target=(0)
  for _position in "${_table[@]}"; do _target+=("${_source[_position]}"); done
}

# des_encrypt_block KEY_HEX BLOCK_HEX: print the DES encryption of one 64-bit block as 16
# lower-case hex digits. Both arguments are 16 hex digits. Single DES in ECB, which is all VNC
# authentication uses; written for a test client, not for protecting anything.
des_encrypt_block() {
  local -a key_bits=() block_bits=() cd=() lr=() c=() d=() l=() r=() subkey=() r_in=() expanded=()
  local -a s_out=() f=() next_r=() pre=() cipher=()
  local -i round rot i j row col val
  local hex=""
  des_bits "$1" key_bits
  des_bits "$2" block_bits
  des_permute DES_PC1 key_bits cd
  des_permute DES_IP block_bits lr
  c=("${cd[@]:1:28}")
  d=("${cd[@]:29:28}")
  l=("${lr[@]:1:32}")
  r=("${lr[@]:33:32}")
  for ((round = 0; round < 16; round++)); do
    rot=${DES_SHIFTS[round]}
    c=("${c[@]:rot}" "${c[@]:0:rot}")
    d=("${d[@]:rot}" "${d[@]:0:rot}")
    cd=(0 "${c[@]}" "${d[@]}")
    des_permute DES_PC2 cd subkey
    r_in=(0 "${r[@]}")
    des_permute DES_E r_in expanded
    s_out=(0)
    for ((j = 0; j < 8; j++)); do
      i=$((j * 6))
      row=$((((expanded[i + 1] ^ subkey[i + 1]) << 1) | (expanded[i + 6] ^ subkey[i + 6])))
      col=$((((expanded[i + 2] ^ subkey[i + 2]) << 3) | ((expanded[i + 3] ^ subkey[i + 3]) << 2) | ((expanded[i + 4] ^ subkey[i + 4]) << 1) | (expanded[i + 5] ^ subkey[i + 5])))
      val=${DES_S[j * 64 + row * 16 + col]}
      s_out+=($(((val >> 3) & 1)) $(((val >> 2) & 1)) $(((val >> 1) & 1)) $((val & 1)))
    done
    des_permute DES_P s_out f
    next_r=()
    for ((i = 0; i < 32; i++)); do next_r+=($((l[i] ^ f[i + 1]))); done
    l=("${r[@]}")
    r=("${next_r[@]}")
  done
  pre=(0 "${r[@]}" "${l[@]}")
  des_permute DES_FP pre cipher
  for ((i = 1; i <= 64; i += 4)); do
    printf -v hex '%s%x' "${hex}" $(((cipher[i] << 3) | (cipher[i + 1] << 2) | (cipher[i + 2] << 1) | cipher[i + 3]))
  done
  printf '%s' "${hex}"
}

# vnc_des_key PASSWORD: print the DES key VNC authentication derives from PASSWORD as 16 hex
# digits: its first eight bytes, padded with zero bytes, each byte with its bits mirrored.
vnc_des_key() {
  local hex out="" LC_ALL=C
  local -i i b byte mirrored
  hex="$(printf '%s' "$1" | od -An -v -tx1 | tr -d ' \n')"
  hex="${hex:0:16}"
  while [ "${#hex}" -lt 16 ]; do hex+="00"; done
  for ((i = 0; i < 16; i += 2)); do
    byte=$((16#${hex:i:2}))
    mirrored=0
    for ((b = 0; b < 8; b++)); do mirrored=$(((mirrored << 1) | ((byte >> b) & 1))); done
    printf -v out '%s%02x' "${out}" "${mirrored}"
  done
  printf '%s' "${out}"
}

# vnc_response PASSWORD CHALLENGE_HEX: print the 16-byte answer (32 hex digits) to a 16-byte
# challenge (32 hex digits): each half encrypted with the key of vnc_des_key.
vnc_response() {
  local key
  key="$(vnc_des_key "$1")"
  des_encrypt_block "${key}" "${2:0:16}"
  des_encrypt_block "${key}" "${2:16:16}"
}

# vnc_read_hex N: print the next N bytes of the connection (descriptor 3) as hex, or less when
# the server sends less within 10 s. Reads byte by byte so nothing beyond N is consumed.
vnc_read_hex() {
  timeout 10 dd bs=1 count="$1" <&3 2>/dev/null | od -An -v -tx1 | tr -d ' \n'
}

# vnc_write_hex HEX: send the bytes given as hex digits to the connection (descriptor 3).
vnc_write_hex() {
  local hex="$1" format=""
  local -i i
  for ((i = 0; i < ${#hex}; i += 2)); do format+="\\x${hex:i:2}"; done
  # shellcheck disable=SC2059  # the format is built from hex digits only
  printf "${format}" >&3
}

# vnc_client_main ARGS...: one session as described at the top of the file. Returns the exit
# status documented there.
vnc_client_main() {
  local host="127.0.0.1" port="5900" hold="1" password_file="" password="" move_x="" move_y=""
  local banner count types challenge result init width height offers_vnc_auth="no"
  local -i i
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --password-file)
        password_file="${2:-}"
        shift 2 || return 2
        ;;
      --host)
        host="${2:-}"
        shift 2 || return 2
        ;;
      --port)
        port="${2:-}"
        shift 2 || return 2
        ;;
      --hold)
        hold="${2:-}"
        shift 2 || return 2
        ;;
      --move)
        move_x="${2:-}"
        move_y="${3:-}"
        shift 3 || return 2
        ;;
      *)
        echo "usage: vnc-client.sh --password-file FILE [--host H] [--port P] [--hold SECONDS] [--move X Y]" >&2
        return 2
        ;;
    esac
  done
  if [ -z "${password_file}" ] || [ ! -r "${password_file}" ]; then
    echo "usage: --password-file must name a readable file" >&2
    return 2
  fi
  if ! [[ "${port}" =~ ^[0-9]+$ ]] || ! [[ "${hold}" =~ ^[0-9]+$ ]] || ! [[ "${move_x}${move_y}" =~ ^[0-9]*$ ]]; then
    echo "usage: --port, --hold and --move take whole numbers" >&2
    return 2
  fi
  IFS= read -r password <"${password_file}" || true
  # The braces confine the 2>/dev/null to this command: bash's own "connection refused" text
  # is replaced by the line below, and descriptor 3 stays open after the group.
  if ! { exec 3<>"/dev/tcp/${host}/${port}"; } 2>/dev/null; then
    echo "fail: cannot connect to ${host}:${port}"
    return 1
  fi
  banner="$(vnc_read_hex 12)"
  # "RFB 003.008\n"
  if [ "${banner}" != "524642203030332e3030380a" ]; then
    echo "fail: the server did not offer RFB 3.8"
    return 1
  fi
  vnc_write_hex "${banner}"
  count="$(vnc_read_hex 1)"
  if [ -z "${count}" ] || [ "${count}" = "00" ]; then
    echo "fail: the server offered no security type"
    return 1
  fi
  types="$(vnc_read_hex "$((16#${count}))")"
  for ((i = 0; i < ${#types}; i += 2)); do
    if [ "${types:i:2}" = "02" ]; then offers_vnc_auth="yes"; fi
  done
  if [ "${offers_vnc_auth}" != "yes" ]; then
    echo "fail: the server does not offer VNC authentication (security types: ${types})"
    return 1
  fi
  vnc_write_hex "02"
  challenge="$(vnc_read_hex 16)"
  if [ "${#challenge}" -ne 32 ]; then
    echo "fail: no 16-byte challenge from the server"
    return 1
  fi
  vnc_write_hex "$(vnc_response "${password}" "${challenge}")"
  result="$(vnc_read_hex 4)"
  if [ "${result}" != "00000000" ]; then
    echo "rejected: the server refused the password"
    return 3
  fi
  # ClientInit: shared session.
  vnc_write_hex "01"
  init="$(vnc_read_hex 24)"
  if [ "${#init}" -ne 48 ]; then
    echo "fail: no ServerInit from the server"
    return 1
  fi
  width=$((16#${init:0:4}))
  height=$((16#${init:4:4}))
  if [ -n "${move_x}" ] && [ -n "${move_y}" ]; then
    # PointerEvent: message type 5, button mask 0, x and y as 16-bit big-endian numbers.
    vnc_write_hex "0500$(printf '%04x%04x' "${move_x}" "${move_y}")"
  fi
  sleep "${hold}"
  exec 3<&- 3>&-
  echo "ok: session established (desktop ${width}x${height})"
  return 0
}

if [ "${VNC_CLIENT_LIB:-}" != "1" ]; then
  vnc_client_main "$@"
  exit $?
fi
