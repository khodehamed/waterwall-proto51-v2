#!/usr/bin/env bash
# WaterWall Proto51 v2 — SECOND tunnel (runs alongside waterwall-proto51 v1)
#
#   curl -fsSL https://raw.githubusercontent.com/khodehamed/waterwall-proto51-v2/master/install.sh -o /tmp/ww51v2-install.sh
#   sudo bash /tmp/ww51v2-install.sh
#
# Isolated from v1: different dir, systemd unit, menu (ww51v2), tun (wtun2), subnet 10.10.1.0/24,
# default ports match v1 (443 2053 …); PORT_OFFSET=10000. Does NOT stop or modify waterwall-proto51 / wtun0.
#
set -euo pipefail

REPO_RAW="${WATERWALL_PROTO51_V2_RAW:-https://raw.githubusercontent.com/khodehamed/waterwall-proto51-v2/master}"
WW_RELEASE="${WATERWALL_RELEASE:-v1.46.3}"
WW_REPO="https://github.com/radkesvat/WaterWall/releases/download/${WW_RELEASE}"
INSTALL_DIR="/opt/waterwall-proto51-v2"
SERVICE_NAME="waterwall-proto51-v2"
CONF_ENV="${INSTALL_DIR}/tunnel.env"
BIN_LINK="/usr/local/bin/ww51v2"
# v1 uses wtun0 + 10.10.0.0/24 — v2 uses separate interface/subnet
TUN_DEVICE="wtun2"
TUN_LOCAL="10.10.1.1"
TUN_PEER="10.10.1.2"
TUN_CIDR="${TUN_LOCAL}/24"

RED='\033[0;31m'
GRN='\033[0;32m'
YLW='\033[1;33m'
CYN='\033[0;36m'
NC='\033[0m'

need_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo -e "${RED}Run as root:${NC} curl -fsSL ... | sudo bash"
    exit 1
  fi
}

msg()  { echo -e "${CYN}==>${NC} $*"; }
ok()   { echo -e "${GRN}OK${NC} $*"; }
warn() { echo -e "${YLW}WARN${NC} $*"; }
err()  { echo -e "${RED}ERR${NC} $*" >&2; exit 1; }

# Interactive prompts must use the controlling TTY so `curl | bash` works
# (stdin is the pipe, not the keyboard).
read_tty() {
  if [[ -r /dev/tty ]]; then
    read "$@" </dev/tty
  else
    # fallback for rare non-TTY environments
    read "$@"
  fi
}

detect_arch_asset() {
  local arch oldcpu="$1"
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64)
      if [[ "$oldcpu" == "1" ]]; then
        echo "Waterwall-linux-gcc-x64-old-cpu.zip"
      else
        echo "Waterwall-linux-gcc-x64.zip"
      fi
      ;;
    aarch64|arm64)
      if [[ "$oldcpu" == "1" ]]; then
        echo "Waterwall-linux-gcc-arm64-old-cpu.zip"
      else
        echo "Waterwall-linux-gcc-arm64.zip"
      fi
      ;;
    *)
      err "Unsupported arch: $arch"
      ;;
  esac
}

ensure_deps() {
  msg "Installing dependencies..."
  export DEBIAN_FRONTEND=noninteractive
  if ! apt-get update -y >/dev/null; then
    err "apt-get update failed"
  fi
  if ! apt-get install -y curl unzip ca-certificates jq iproute2 openssl >/dev/null; then
    err "apt-get install failed (need curl unzip jq iproute2 openssl)"
  fi
  command -v curl >/dev/null || err "curl missing after apt install"
  command -v unzip >/dev/null || err "unzip missing after apt install"
  ok "Dependencies ready"
}

download_waterwall() {
  local oldcpu="$1"
  local asset zip_path
  asset="$(detect_arch_asset "$oldcpu")"
  zip_path="/tmp/${asset}"

  msg "Downloading WaterWall ${WW_RELEASE} (${asset})..."
  if ! curl -fL --connect-timeout 30 --max-time 300 "${WW_REPO}/${asset}" -o "$zip_path"; then
    err "Download failed: ${WW_REPO}/${asset}"
  fi
  [[ -s "$zip_path" ]] || err "Downloaded zip is empty: $zip_path"

  msg "Extracting WaterWall binary..."
  mkdir -p "$INSTALL_DIR" "${INSTALL_DIR}/log" "${INSTALL_DIR}/libs"
  rm -f "${INSTALL_DIR}/Waterwall" 2>/dev/null || true
  # Official 1.46.x zips ship a single Waterwall binary (EncryptionClient/Server
  # are statically linked). libs/ is kept for core.json libs-path compatibility only.
  if ! unzip -o "$zip_path" -d "$INSTALL_DIR" >/dev/null; then
    err "unzip failed (is unzip installed?)"
  fi
  rm -f "$zip_path"

  # binary may be nested
  if [[ ! -f "${INSTALL_DIR}/Waterwall" ]]; then
    local found
    found="$(find "$INSTALL_DIR" -type f -name Waterwall | head -n1 || true)"
    [[ -n "$found" ]] || err "Waterwall binary not found after unzip"
    mv "$found" "${INSTALL_DIR}/Waterwall"
  fi
  chmod +x "${INSTALL_DIR}/Waterwall"
  ok "Waterwall binary ready"
}

gen_key() {
  # Shared EncryptionClient/Server password: exactly 32 alphanumeric chars.
  # IMPORTANT: with set -o pipefail, tr|head -c often exits 141 (SIGPIPE) when
  # head closes the pipe early. That aborts key="$(gen_key)" under set -e with
  # NO error message — looks like a hang right after the key prompt.
  local key=""
  local n=0
  if command -v openssl >/dev/null 2>&1; then
    key="$(openssl rand -hex 16 2>/dev/null || true)"
  fi
  while [[ ${#key} -lt 32 && $n -lt 8 ]]; do
    key+="$( { tr -dc 'A-Za-z0-9' </dev/urandom || true; } | head -c $((32 - ${#key})) || true )"
    n=$((n + 1))
  done
  key="${key:0:32}"
  [[ ${#key} -eq 32 ]] || { echo "ERR failed to generate 32-char AES key" >&2; return 1; }
  printf '%s' "$key"
}

validate_ip() {
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  local o IFS=.
  read -r -a o <<<"$1"
  for x in "${o[@]}"; do
    ((x >= 0 && x <= 255)) || return 1
  done
  return 0
}

normalize_ports() {
  # input: "443 8080,2096" -> "443 8080 2096"
  local raw="$1"
  echo "$raw" | tr ',;' '  ' | xargs
}

# When ENCRYPT=1, AEAD hops use INTERNAL_PORT = PUBLIC_PORT + PORT_OFFSET on the TUN.
# Public panel ports stay untouched on Kharej (panel may keep 0.0.0.0:PUBLIC_PORT).
PORT_OFFSET_DEFAULT=10000
PORT_OFFSET="${PORT_OFFSET:-$PORT_OFFSET_DEFAULT}"
# Same PUBLIC forward ports as v1 — OK when v2 Iran is a different host (warn if v1 on same Iran box).
DEFAULT_PORTS="443 2053 2083 2087 2096 8443"

detect_public_ip() {
  # Best-effort public IPv4 for Status + install/edit defaults (override always allowed).
  local ip="" url
  for url in \
    "https://ifconfig.me" \
    "https://api.ipify.org" \
    "https://ipv4.icanhazip.com"; do
    ip="$(curl -4 -fsS --connect-timeout 2 --max-time 3 "$url" 2>/dev/null | tr -d '[:space:]' || true)"
    if validate_ip "${ip:-}"; then
      printf '%s' "$ip"
      return 0
    fi
  done
  # Fallback: source IP used to reach the public Internet
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null \
    | awk '{ for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit } }' \
    || true)"
  if validate_ip "${ip:-}"; then
    printf '%s' "$ip"
    return 0
  fi
  return 1
}

validate_ports() {
  local p
  for p in $1; do
    [[ "$p" =~ ^[0-9]+$ ]] || return 1
    ((p >= 1 && p <= 65535)) || return 1
  done
  return 0
}

validate_port_offset() {
  local offset="${1:-$PORT_OFFSET}"
  [[ "$offset" =~ ^[0-9]+$ ]] || return 1
  ((offset >= 1 && offset <= 60000)) || return 1
  return 0
}

validate_ports_with_offset() {
  # Ensure PUBLIC+OFFSET fits in 1..65535 for every public port.
  local ports="$1" offset="${2:-$PORT_OFFSET}" p iport
  validate_port_offset "$offset" || return 1
  for p in $ports; do
    [[ "$p" =~ ^[0-9]+$ ]] || return 1
    ((p >= 1 && p <= 65535)) || return 1
    iport=$((p + offset))
    ((iport >= 1 && iport <= 65535)) || return 1
  done
  return 0
}

internal_port() {
  # PUBLIC_PORT -> INTERNAL_PORT for encrypted TUN hop
  local p="$1" offset="${2:-$PORT_OFFSET}"
  echo $((p + offset))
}

internal_ports_list() {
  # "443 2053" + offset -> "10443 12053"
  local ports="$1" offset="${2:-$PORT_OFFSET}" p out=""
  for p in $ports; do
    out+="$(internal_port "$p" "$offset") "
  done
  normalize_ports "$out"
}

warn_v1_port_overlap() {
  # v1 and v2 Iran listeners both bind 0.0.0.0:PUBLIC — ports must differ.
  local ports="$1" v1_env="/opt/waterwall-proto51/tunnel.env" v1_ports p v
  [[ -f "$v1_env" ]] || return 0
  # shellcheck disable=SC1090
  source "$v1_env" 2>/dev/null || return 0
  v1_ports="${PORTS:-}"
  [[ -n "$v1_ports" ]] || return 0
  for p in $ports; do
    for v in $v1_ports; do
      if [[ "$p" == "$v" ]]; then
        warn "Port ${p} is already used by waterwall-proto51 (v1) — pick different PUBLIC ports for v2"
      fi
    done
  done
}

ports_busy_report() {
  # Print busy listen lines for each port (any local address). Return 0 if any busy.
  # On Linux, a listener on *:PORT / 0.0.0.0:PORT also blocks bind to 10.10.0.1:PORT.
  local ports="$1" p busy="" line
  command -v ss >/dev/null 2>&1 || return 1
  for p in $ports; do
    line="$(ss -lntH "sport = :$p" 2>/dev/null | head -n1 || true)"
    if [[ -n "$line" ]]; then
      busy+="  port ${p}: ${line}"$'\n'
    fi
  done
  if [[ -n "$busy" ]]; then
    printf '%s' "$busy"
    return 0
  fi
  return 1
}

assert_ports_free() {
  # Iran TcpListeners need exclusive bind on 0.0.0.0:PUBLIC_PORT.
  local ports="$1" busy
  if busy="$(ports_busy_report "$ports")"; then
    echo -e "${RED}ERR${NC} These ports are already in use (WaterWall cannot bind):" >&2
    echo -e "$busy" >&2
    echo "Free them (stop x-ui/backhaul/nginx/etc. on Iran) or choose different ports." >&2
    echo "Hint: ss -lntup | grep -E ':PORT'" >&2
    exit 1
  fi
}

warn_kharej_internal_port_conflict() {
  # INTERNAL hop ports busy — do NOT ask user to free panel PUBLIC ports.
  local busy="$1" offset="${2:-$PORT_OFFSET}"
  warn "============================================================"
  warn "Kharej encryption binds INTERNAL ports on ${TUN_LOCAL}:"
  warn "  INTERNAL_PORT = PUBLIC_PORT + PORT_OFFSET (PORT_OFFSET=${offset})"
  warn "These INTERNAL ports are already in use:"
  echo -e "$busy" >&2
  warn "Panel PUBLIC ports are fine (panel may stay on 0.0.0.0)."
  warn "This installer will NOT touch x-ui/xray/nginx/panel."
  warn "Auto-fallback: ENCRYPT=0 so the packet tunnel stays UP."
  warn "EN: Free the INTERNAL ports, or change PORT_OFFSET in tunnel.env, then:"
  warn "    sudo ww51v2 edit (encrypt=y)."
  warn "FA: پورت‌های داخلی تانل اشغال‌اند؛ پنل را جابه‌جا نکنید."
  warn "============================================================"
}

resolve_kharej_encrypt_bind_or_fallback() {
  # Kharej encrypt=1 binds INTERNAL ports only (PUBLIC+OFFSET), not panel PUBLIC ports.
  # If INTERNAL ports are busy, force ENCRYPT_RESOLVED=0. Keep KEY_RESOLVED for retry.
  local encrypt="$1" key="$2" ports="$3" offset="${4:-$PORT_OFFSET}" busy iports
  ENCRYPT_RESOLVED="$encrypt"
  KEY_RESOLVED="$key"
  [[ "$encrypt" == "1" ]] || return 0
  [[ -n "$ports" ]] || return 0
  validate_ports_with_offset "$ports" "$offset" || {
    warn "Invalid PUBLIC ports / PORT_OFFSET=${offset} (PUBLIC+OFFSET must be <= 65535)"
    ENCRYPT_RESOLVED=0
    return 0
  }
  iports="$(internal_ports_list "$ports" "$offset")"
  if busy="$(ports_busy_report "$iports")"; then
    warn_kharej_internal_port_conflict "$busy" "$offset"
    ENCRYPT_RESOLVED=0
    return 0
  fi
  return 0
}

# Official docs:
#   https://radkesvat.github.io/WaterWall-Docs/docs/noderefs/EncryptionClient
#   https://radkesvat.github.io/WaterWall-Docs/docs/noderefs/EncryptionServer
# Encrypt hop (INTERNAL_PORT = PUBLIC_PORT + PORT_OFFSET, default +10000):
#   Iran:   TcpListener(0.0.0.0:PUBLIC) -> EncryptionClient -> TcpConnector(10.10.0.2:INTERNAL)
#   Kharej: TcpListener(10.10.0.1:INTERNAL) -> EncryptionServer -> TcpConnector(127.0.0.1:PUBLIC)
# Iran MAY listen on 0.0.0.0 with encryption — that is fine.
# Conflict was only Kharej EncryptionServer binding same PUBLIC port as panel on *:PORT.
# AesGcm is NOT in WaterWall 1.46.x (no tunnel, no libs plugin) — do not use it.
#
# Docs default algorithm is chacha20-poly1305. old-cpu WaterWall builds often
# lack AES-GCM in the active crypto backend and FATAL on:
#   "AES-GCM selected but it is unavailable in the active crypto backend"
ENC_SALT_DEFAULT="waterwall-proto51-v2"
ENC_ALGO_DEFAULT="chacha20-poly1305"
ENC_KDF_DEFAULT="12000"
# Active algorithm written into configs / tunnel.env (set by probe).
ENC_ALGO="$ENC_ALGO_DEFAULT"

binary_has_string() {
  local bin="$1" needle="$2"
  grep -a -F -q -- "$needle" "$bin" 2>/dev/null
}

cpu_has_aes_ni() {
  # x86: "aes" in flags; aarch64 sometimes exposes AES via Features.
  grep -qiE '(^flags|^Features).*[[:space:]]aes([[:space:]]|$)' /proc/cpuinfo 2>/dev/null
}

probe_encryption_algorithm() {
  # Echo a usable EncryptionClient/Server algorithm for the installed binary.
  # Prefer chacha20-poly1305 (docs default; works without AES-NI / old-cpu).
  # Never select aes-gcm for old-cpu binaries — backend typically cannot provide it.
  # Returns 0 + prints algo, or 1 if nothing usable.
  local oldcpu="${1:-0}"
  local bin="${INSTALL_DIR}/Waterwall"
  local has_chacha=0 has_aes=0

  [[ -x "$bin" ]] || return 1

  if binary_has_string "$bin" "chacha20-poly1305" \
    || binary_has_string "$bin" "chacha20poly1305" \
    || binary_has_string "$bin" "chacha20" \
    || binary_has_string "$bin" "chacha"; then
    has_chacha=1
  fi
  if binary_has_string "$bin" "aes-gcm" \
    || binary_has_string "$bin" "aes-256-gcm" \
    || binary_has_string "$bin" "aes256gcm" \
    || binary_has_string "$bin" "aes256-gcm"; then
    has_aes=1
  fi

  # old-cpu release builds: AES-GCM string may exist but crypto backend rejects it.
  if [[ "$oldcpu" == "1" ]]; then
    has_aes=0
  elif ! cpu_has_aes_ni; then
    # Soft AES without AES-NI is slow and some backends still refuse AES-GCM.
    has_aes=0
  fi

  # Must not print status on stdout — caller captures the algorithm name.
  echo -e "${CYN}==>${NC} Crypto probe: old-cpu=${oldcpu} chacha=${has_chacha} aes-gcm=${has_aes} aes-ni=$(cpu_has_aes_ni && echo 1 || echo 0)" >&2

  if [[ "$has_chacha" -eq 1 ]]; then
    printf '%s' "chacha20-poly1305"
    return 0
  fi
  if [[ "$has_aes" -eq 1 ]]; then
    printf '%s' "aes-gcm"
    return 0
  fi
  return 1
}

ensure_encryption_support() {
  # EncryptionClient/Server are statically linked in official WaterWall builds.
  # Probe AEAD algorithms and set ENC_ALGO. Return 0 if encryption can proceed,
  # 1 if caller should disable encryption (no usable AEAD) instead of crashing.
  # Arg: oldcpu (0|1). AesGcm plugin is never used.
  local oldcpu="${1:-0}"
  local bin="${INSTALL_DIR}/Waterwall"
  local algo=""

  [[ -x "$bin" ]] || err "Waterwall binary missing at $bin (download first)"
  if ! binary_has_string "$bin" "EncryptionClient"; then
    warn "This WaterWall binary lacks EncryptionClient (need v1.46+)."
    return 1
  fi
  if ! binary_has_string "$bin" "EncryptionServer"; then
    warn "This WaterWall binary lacks EncryptionServer (need v1.46+)."
    return 1
  fi
  ok "EncryptionClient/Server present in binary (no libs/ plugin required)"

  if ! algo="$(probe_encryption_algorithm "$oldcpu")"; then
    warn "No usable AEAD algorithm for this binary/CPU (old-cpu often lacks AES-GCM)."
    warn "Docs alternatives: chacha20-poly1305 (preferred), aes-gcm / aes-256-gcm."
    return 1
  fi
  ENC_ALGO="$algo"
  ok "Selected encryption algorithm: ${ENC_ALGO} (salt=${ENC_SALT_DEFAULT})"
  return 0
}

resolve_encryption_or_fallback() {
  # If encrypt=1, probe algorithms. On failure: warn and force encrypt=0.
  # Sets globals: ENC_ALGO, and echoes "encrypt key" via nameref-style globals
  # Caller passes encrypt/key by name through globals ENCRYPT_RESOLVED / KEY_RESOLVED
  # Actually: mutate caller's locals via eval-free pattern — return via globals.
  # Usage: resolve_encryption_or_fallback "$encrypt" "$key" "$oldcpu"
  #         then read ENCRYPT_RESOLVED KEY_RESOLVED
  local want="$1" key="$2" oldcpu="$3"
  ENCRYPT_RESOLVED="$want"
  KEY_RESOLVED="$key"
  ENC_ALGO="${ENC_ALGO:-$ENC_ALGO_DEFAULT}"

  if [[ "$want" != "1" ]]; then
    ENCRYPT_RESOLVED=0
    KEY_RESOLVED=""
    return 0
  fi

  if ensure_encryption_support "$oldcpu"; then
    ENCRYPT_RESOLVED=1
    KEY_RESOLVED="$key"
    return 0
  fi

  warn "============================================================"
  warn "Encryption requested but no AEAD works on this crypto backend."
  warn "Auto-fallback: installing WITHOUT encryption (service stays up)."
  warn "Both Iran and Kharej must use the same encrypt setting."
  warn "============================================================"
  ENCRYPT_RESOLVED=0
  KEY_RESOLVED=""
  ENC_ALGO="$ENC_ALGO_DEFAULT"
  return 0
}

build_iran_forward_nodes() {
  # WaterWall 1.46+ auto-inserts TcpConnector.domain-resolver and does NOT allow
  # multiple listeners to share one connector next. Emit one chain per port.
  # encrypt=0: TcpListener(0.0.0.0:PUBLIC) -> TcpConnector(10.10.0.2:PUBLIC)
  # encrypt=1: TcpListener(0.0.0.0:PUBLIC) -> EncryptionClient -> TcpConnector(10.10.0.2:INTERNAL)
  #   INTERNAL = PUBLIC + PORT_OFFSET. Iran listen on 0.0.0.0 WITH encrypt is OK.
  local ports="$1" encrypt="$2" key="$3" offset="${4:-$PORT_OFFSET}"
  local p iport first=1 next_name
  for p in $ports; do
    if [[ $first -eq 1 ]]; then
      first=0
    else
      printf ',\n'
    fi
    if [[ "$encrypt" == "1" ]]; then
      iport="$(internal_port "$p" "$offset")"
      next_name="enc${p}"
      cat <<EOF
        {
            "name": "p${p}",
            "type": "TcpListener",
            "settings": {
                "address": "0.0.0.0",
                "port": ${p},
                "nodelay": true
            },
            "next": "${next_name}"
        },
        {
            "name": "${next_name}",
            "type": "EncryptionClient",
            "settings": {
                "algorithm": "${ENC_ALGO}",
                "password": "${key}",
                "salt": "${ENC_SALT_DEFAULT}",
                "kdf-iterations": ${ENC_KDF_DEFAULT}
            },
            "next": "c${p}"
        },
        {
            "name": "c${p}",
            "type": "TcpConnector",
            "settings": {
                "nodelay": true,
                "address": "${TUN_PEER}",
                "port": ${iport}
            }
        }
EOF
    else
      cat <<EOF
        {
            "name": "p${p}",
            "type": "TcpListener",
            "settings": {
                "address": "0.0.0.0",
                "port": ${p},
                "nodelay": true
            },
            "next": "c${p}"
        },
        {
            "name": "c${p}",
            "type": "TcpConnector",
            "settings": {
                "nodelay": true,
                "address": "${TUN_PEER}",
                "port": ${p}
            }
        }
EOF
    fi
  done
}

build_kharej_decrypt_nodes() {
  # encrypt=1: bind INTERNAL on TUN, decrypt, connect to panel PUBLIC on loopback.
  # TcpListener(10.10.0.1:INTERNAL) -> EncryptionServer -> TcpConnector(127.0.0.1:PUBLIC)
  # Connecting to 127.0.0.1:PUBLIC is OK even if panel listens on 0.0.0.0:PUBLIC.
  # Do NOT move panel; do NOT bind PUBLIC on 10.10.0.1 (that conflicted with *:PUBLIC).
  local ports="$1" key="$2" offset="${3:-$PORT_OFFSET}"
  local p iport first=1
  [[ -n "$ports" ]] || return 0
  for p in $ports; do
    if [[ $first -eq 1 ]]; then
      first=0
    else
      printf ',\n'
    fi
    iport="$(internal_port "$p" "$offset")"
    cat <<EOF
        {
            "name": "p${p}",
            "type": "TcpListener",
            "settings": {
                "address": "${TUN_LOCAL}",
                "port": ${iport},
                "nodelay": true
            },
            "next": "enc${p}"
        },
        {
            "name": "enc${p}",
            "type": "EncryptionServer",
            "settings": {
                "algorithm": "${ENC_ALGO}",
                "password": "${key}",
                "salt": "${ENC_SALT_DEFAULT}",
                "kdf-iterations": ${ENC_KDF_DEFAULT}
            },
            "next": "c${p}"
        },
        {
            "name": "c${p}",
            "type": "TcpConnector",
            "settings": {
                "nodelay": true,
                "address": "127.0.0.1",
                "port": ${p}
            }
        }
EOF
  done
}

write_core_json() {
  local side="$1" mtu="$2"
  local cfg="config_${side}.json"
  [[ "$side" == "kharej" ]] && cfg="config_kharej.json"
  [[ "$side" == "ir" ]] && cfg="config_ir.json"

  cat > "${INSTALL_DIR}/core.json" <<EOF
{
    "log": {
        "path": "log/",
        "internal": {
            "loglevel": "INFO",
            "file": "internal.log",
            "console": true
        },
        "core": {
            "loglevel": "INFO",
            "file": "core.log",
            "console": true
        },
        "network": {
            "loglevel": "INFO",
            "file": "network.log",
            "console": true
        },
        "dns": {
            "loglevel": "SILENT",
            "file": "dns.log",
            "console": false
        }
    },
    "dns": {},
    "misc": {
        "workers": 1,
        "mtu": ${mtu},
        "ram-profile": "client",
        "libs-path": "libs/"
    },
    "configs": [
        "${cfg}"
    ]
}
EOF
}

write_iran_config() {
  # Packet path stays unencrypted (TunDevice...RawSocket + protoswap).
  # Optional AEAD sits on the TCP forward chains (EncryptionClient).
  local iran_ip="$1" kh_ip="$2" proto="$3" encrypt="$4" key="$5" ports="$6" offset="${7:-$PORT_OFFSET}"
  local forward_nodes

  forward_nodes="$(build_iran_forward_nodes "$ports" "$encrypt" "$key" "$offset")"

  cat > "${INSTALL_DIR}/config_ir.json" <<EOF
{
    "name": "iran",
    "nodes": [
        {
            "name": "my tun",
            "type": "TunDevice",
            "settings": {
                "device-name": "${TUN_DEVICE}",
                "device-ip": "${TUN_CIDR}"
            },
            "next": "ipovsrc"
        },
        {
            "name": "ipovsrc",
            "type": "IpOverrider",
            "settings": {
                "direction": "up",
                "mode": "source-ip",
                "ipv4": "${iran_ip}"
            },
            "next": "ipovdest"
        },
        {
            "name": "ipovdest",
            "type": "IpOverrider",
            "settings": {
                "direction": "up",
                "mode": "dest-ip",
                "ipv4": "${kh_ip}"
            },
            "next": "manip"
        },
        {
            "name": "manip",
            "type": "IpManipulator",
            "settings": {
                "protoswap": ${proto}
            },
            "next": "ipovsrc2"
        },
        {
            "name": "ipovsrc2",
            "type": "IpOverrider",
            "settings": {
                "direction": "down",
                "mode": "source-ip",
                "ipv4": "${TUN_PEER}"
            },
            "next": "ipovdest2"
        },
        {
            "name": "ipovdest2",
            "type": "IpOverrider",
            "settings": {
                "direction": "down",
                "mode": "dest-ip",
                "ipv4": "${TUN_LOCAL}"
            },
            "next": "rd"
        },
        {
            "name": "rd",
            "type": "RawSocket",
            "settings": {
                "capture-filter-mode": "source-ip",
                "capture-ip": "${kh_ip}"
            }
        },
${forward_nodes}
    ]
}
EOF
}

write_kharej_config() {
  # Packet path: TunDevice...RawSocket + protoswap (same PROTO as Iran).
  # encrypt=1: EncryptionServer on 10.10.0.1:INTERNAL -> panel 127.0.0.1:PUBLIC.
  local iran_ip="$1" kh_ip="$2" proto="$3" encrypt="$4" key="$5" ports="$6" offset="${7:-$PORT_OFFSET}"
  local decrypt_nodes="" decrypt_block=""

  if [[ "$encrypt" == "1" ]]; then
    decrypt_nodes="$(build_kharej_decrypt_nodes "$ports" "$key" "$offset")"
    [[ -n "$decrypt_nodes" ]] || err "Encryption enabled but no ports configured (needed on Kharej for EncryptionServer)"
    decrypt_block=",
${decrypt_nodes}"
  fi

  cat > "${INSTALL_DIR}/config_kharej.json" <<EOF
{
    "name": "kharej",
    "nodes": [
        {
            "name": "my tun",
            "type": "TunDevice",
            "settings": {
                "device-name": "${TUN_DEVICE}",
                "device-ip": "${TUN_CIDR}"
            },
            "next": "ipovsrc"
        },
        {
            "name": "ipovsrc",
            "type": "IpOverrider",
            "settings": {
                "direction": "up",
                "mode": "source-ip",
                "ipv4": "${kh_ip}"
            },
            "next": "ipovdest"
        },
        {
            "name": "ipovdest",
            "type": "IpOverrider",
            "settings": {
                "direction": "up",
                "mode": "dest-ip",
                "ipv4": "${iran_ip}"
            },
            "next": "manip"
        },
        {
            "name": "manip",
            "type": "IpManipulator",
            "settings": {
                "protoswap": ${proto}
            },
            "next": "ipovsrc2"
        },
        {
            "name": "ipovsrc2",
            "type": "IpOverrider",
            "settings": {
                "direction": "down",
                "mode": "source-ip",
                "ipv4": "${TUN_PEER}"
            },
            "next": "ipovdest2"
        },
        {
            "name": "ipovdest2",
            "type": "IpOverrider",
            "settings": {
                "direction": "down",
                "mode": "dest-ip",
                "ipv4": "${TUN_LOCAL}"
            },
            "next": "rd"
        },
        {
            "name": "rd",
            "type": "RawSocket",
            "settings": {
                "capture-filter-mode": "source-ip",
                "capture-ip": "${iran_ip}"
            }
        }${decrypt_block}
    ]
}
EOF
}

write_env() {
  # PROTO = IpManipulator protoswap (0-255). ENCRYPT=1 uses EncryptionClient/Server.
  # AES_KEY is the shared Encryption password (32 chars). Not the removed AesGcm node.
  # ENC_ALGO is the probed AEAD (usually chacha20-poly1305 on old-cpu).
  # PORT_OFFSET: INTERNAL_PORT = PUBLIC_PORT + PORT_OFFSET (encrypt hop on TUN).
  local offset="${9:-$PORT_OFFSET}"
  PORT_OFFSET="$offset"
  cat > "$CONF_ENV" <<EOF
SIDE=$1
IRAN_IP=$2
KHAREJ_IP=$3
PROTO=$4
ENCRYPT=$5
AES_KEY=$6
PORTS="$7"
OLDCPU=$8
PORT_OFFSET=${offset}
ENC_ALGO=${ENC_ALGO:-$ENC_ALGO_DEFAULT}
ENC_SALT=${ENC_SALT_DEFAULT}
EOF
  chmod 600 "$CONF_ENV"
}

write_service() {
  # WaterWall needs root for TunDevice (/dev/net/tun) + RawSocket.
  # Do not sandbox with NoNewPrivileges/CapabilityBoundingSet — those break TUN/raw.
  # StartLimitIntervalSec=0: never give up restarting after reboot or crash loops.
  cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=WaterWall Proto51 v2 Tunnel (second instance)
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/Waterwall
Restart=always
RestartSec=5
LimitNOFILE=1048576
# Root + no privilege sandbox: TunDevice and RawSocket need unrestricted net admin.
NoNewPrivileges=false

[Install]
WantedBy=multi-user.target
EOF
}

write_watchdog() {
  # Lightweight self-contained recovery: timer every 2m checks service + TUN_DEVICE.
  mkdir -p "$INSTALL_DIR"
  cat > "${INSTALL_DIR}/watchdog.sh" <<EOF
#!/usr/bin/env bash
# ${SERVICE_NAME} watchdog — restart if service inactive or ${TUN_DEVICE} missing
set -euo pipefail
SERVICE_NAME="${SERVICE_NAME}"
TUN_DEVICE="${TUN_DEVICE}"
LOG_TAG="${SERVICE_NAME}-watchdog"

need_restart=0
state="\$(systemctl is-active "\${SERVICE_NAME}.service" 2>/dev/null || true)"
if [[ "\$state" != "active" ]]; then
  need_restart=1
  logger -t "\$LOG_TAG" "service not active (state=\${state:-unknown}); restarting"
fi

if ! ip link show "\${TUN_DEVICE}" >/dev/null 2>&1; then
  need_restart=1
  logger -t "\$LOG_TAG" "\${TUN_DEVICE} missing; restarting \${SERVICE_NAME}"
fi

if [[ "\$need_restart" -eq 1 ]]; then
  systemctl restart "\${SERVICE_NAME}.service" || true
fi
exit 0
EOF
  chmod 755 "${INSTALL_DIR}/watchdog.sh"

  cat > "/etc/systemd/system/${SERVICE_NAME}-watchdog.service" <<EOF
[Unit]
Description=WaterWall Proto51 Watchdog (oneshot check)
After=network-online.target

[Service]
Type=oneshot
ExecStart=${INSTALL_DIR}/watchdog.sh
Nice=10
EOF

  cat > "/etc/systemd/system/${SERVICE_NAME}-watchdog.timer" <<EOF
[Unit]
Description=WaterWall Proto51 Watchdog Timer (every 2 minutes)
Requires=${SERVICE_NAME}-watchdog.service

[Timer]
OnBootSec=1min
OnUnitActiveSec=2min
AccuracySec=30s
Persistent=true
Unit=${SERVICE_NAME}-watchdog.service

[Install]
WantedBy=timers.target
EOF
}

enable_watchdog() {
  msg "Enabling ${SERVICE_NAME}-watchdog.timer..."
  write_watchdog
  systemctl daemon-reload || err "systemctl daemon-reload failed (watchdog)"
  systemctl enable --now "${SERVICE_NAME}-watchdog.timer" \
    || err "Failed to enable ${SERVICE_NAME}-watchdog.timer"
  ok "Watchdog timer enabled (checks every ~2 minutes)"
}

disable_watchdog() {
  systemctl disable --now "${SERVICE_NAME}-watchdog.timer" 2>/dev/null || true
  systemctl stop "${SERVICE_NAME}-watchdog.service" 2>/dev/null || true
  rm -f "/etc/systemd/system/${SERVICE_NAME}-watchdog.service"
  rm -f "/etc/systemd/system/${SERVICE_NAME}-watchdog.timer"
  rm -f "${INSTALL_DIR}/watchdog.sh"
}

write_menu_wrapper() {
  cat > "$BIN_LINK" <<EOF
#!/usr/bin/env bash
if [[ -f "${INSTALL_DIR}/install.sh" ]]; then
  exec bash "${INSTALL_DIR}/install.sh" "\$@"
fi
exec bash -c "curl -fsSL ${REPO_RAW}/install.sh | sudo bash"
EOF
  chmod +x "$BIN_LINK"
}

sysctl_tune() {
  mkdir -p /etc/sysctl.d
  cat > /etc/sysctl.d/99-waterwall-proto51-v2.conf <<EOF
net.ipv4.ip_forward=1
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
  sysctl --system >/dev/null 2>&1 || true
}

show_failure_logs() {
  echo
  warn "Service is NOT healthy. Recent journal:"
  journalctl -u "${SERVICE_NAME}" -n 50 --no-pager || true
  echo
  if compgen -G "${INSTALL_DIR}/log/*.log" >/dev/null 2>&1; then
    warn "WaterWall log files:"
    # shellcheck disable=SC2012
    ls -1t "${INSTALL_DIR}"/log/*.log 2>/dev/null | head -n 4 | while read -r f; do
      echo "---- ${f} (tail) ----"
      tail -n 30 "$f" 2>/dev/null || true
    done
  fi
}

start_service() {
  msg "Enabling and starting ${SERVICE_NAME}.service..."
  systemctl daemon-reload || err "systemctl daemon-reload failed"
  systemctl enable "${SERVICE_NAME}.service" || err "Failed to enable ${SERVICE_NAME}.service"
  systemctl restart "${SERVICE_NAME}.service" || true
  sleep 2

  local state result
  state="$(systemctl is-active "${SERVICE_NAME}.service" 2>/dev/null || true)"
  result="$(systemctl show -p Result --value "${SERVICE_NAME}.service" 2>/dev/null || true)"
  systemctl --no-pager --full status "${SERVICE_NAME}.service" || true

  if [[ "$state" == "active" ]]; then
    ok "Service is active (running)"
    return 0
  fi

  show_failure_logs
  err "Service failed to stay running (state=${state:-unknown} result=${result:-unknown}). See logs above."
}

stop_service() {
  systemctl disable --now "${SERVICE_NAME}.service" 2>/dev/null || true
}

uninstall_all() {
  msg "Uninstalling..."
  disable_watchdog
  stop_service
  rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
  systemctl daemon-reload || true
  rm -rf "$INSTALL_DIR"
  rm -f "$BIN_LINK"
  rm -f /etc/sysctl.d/99-waterwall-proto51-v2.conf
  ok "Removed ${SERVICE_NAME}"
}

show_status() {
  local this_ip=""
  this_ip="$(detect_public_ip || true)"

  echo
  echo -e "${CYN}This server:${NC}"
  if [[ -n "${this_ip:-}" ]]; then
    echo -e "  public IP : ${GRN}${this_ip}${NC}  (copy/paste for the other side)"
  else
    warn "public IP : could not auto-detect (check outbound HTTPS / interface)"
  fi
  echo

  if [[ -f "$CONF_ENV" ]]; then
    echo -e "${CYN}Config:${NC}"
    # shellcheck disable=SC1090
    source "$CONF_ENV"
    echo "  side      : ${SIDE:-?}"
    echo "  iran ip   : ${IRAN_IP:-?}"
    echo "  kharej ip : ${KHAREJ_IP:-?}"
    echo "  proto     : ${PROTO:-?}  (IpManipulator protoswap; editable via menu 4)"
    echo "  encrypt   : ${ENCRYPT:-0}  (0=off, 1=EncryptionClient/Server AEAD)"
    echo "  enc algo  : ${ENC_ALGO:-$ENC_ALGO_DEFAULT}"
    echo "  ports     : ${PORTS:-?}  (public / Iran listen + Kharej panel)"
    echo "  port+off  : ${PORT_OFFSET:-$PORT_OFFSET_DEFAULT}  (INTERNAL = PUBLIC + offset when encrypt=1)"
    if [[ "${ENCRYPT:-0}" == "1" && -n "${PORTS:-}" ]]; then
      echo "  internal  : $(internal_ports_list "$PORTS" "${PORT_OFFSET:-$PORT_OFFSET_DEFAULT}")  (TUN encrypt hop)"
    fi
    echo "  old-cpu   : ${OLDCPU:-0}"
  else
    warn "No saved config at $CONF_ENV"
  fi
  echo
  echo -e "${CYN}Service:${NC}"
  systemctl --no-pager --full status "${SERVICE_NAME}.service" || true
  echo
  echo -e "${CYN}Watchdog timer:${NC}"
  systemctl --no-pager --full status "${SERVICE_NAME}-watchdog.timer" 2>/dev/null || warn "watchdog timer not installed"
  systemctl list-timers "${SERVICE_NAME}-watchdog.timer" --no-pager 2>/dev/null || true
  echo
  echo -e "${CYN}Interface:${NC}"
  ip -br addr show "${TUN_DEVICE}" 2>/dev/null || warn "${TUN_DEVICE} not up"
  echo
  echo -e "${CYN}Enabled at boot:${NC}"
  systemctl is-enabled "${SERVICE_NAME}.service" 2>/dev/null || true
  systemctl is-enabled "${SERVICE_NAME}-watchdog.timer" 2>/dev/null || true
}

show_tunnel_logs() {
  local n=100
  echo
  echo -e "${CYN}Tunnel logs${NC} (journalctl -u ${SERVICE_NAME}, last ${n} lines)"
  echo "========================================"
  journalctl -u "${SERVICE_NAME}" -n "$n" --no-pager 2>/dev/null || warn "journalctl unavailable"
  echo
  if compgen -G "${INSTALL_DIR}/log/*.log" >/dev/null 2>&1; then
    echo -e "${CYN}WaterWall log files${NC} (tail last 80 lines each, newest first)"
    echo "========================================"
    # shellcheck disable=SC2012
    ls -1t "${INSTALL_DIR}"/log/*.log 2>/dev/null | head -n 4 | while read -r f; do
      echo
      echo "---- ${f} ----"
      tail -n 80 "$f" 2>/dev/null || true
    done
  else
    msg "No files under ${INSTALL_DIR}/log/ yet"
  fi
}

apply_tunnel_config() {
  # Regenerate JSON from args and restart (no full reinstall).
  # args: side iran_ip kh_ip proto encrypt key ports oldcpu [port_offset]
  local side="$1" iran_ip="$2" kh_ip="$3" proto="$4" encrypt="$5" key="$6" ports="$7" oldcpu="$8"
  local offset="${9:-${PORT_OFFSET:-$PORT_OFFSET_DEFAULT}}"
  local mtu

  PORT_OFFSET="$offset"
  if [[ "$side" == "ir" ]]; then mtu=1320; else mtu=1380; fi

  if [[ "$encrypt" == "1" ]]; then
    resolve_encryption_or_fallback "$encrypt" "$key" "$oldcpu"
    encrypt="$ENCRYPT_RESOLVED"
    key="$KEY_RESOLVED"
    if [[ "$encrypt" == "1" ]]; then
      [[ -n "$ports" ]] || err "Encryption requires PORTS on both sides (same list)"
      [[ ${#key} -eq 32 ]] || err "Encryption password must be exactly 32 characters"
      validate_ports_with_offset "$ports" "$offset" \
        || err "Invalid ports/PORT_OFFSET=${offset} (each PUBLIC+OFFSET must be 1..65535)"
    fi
  else
    ENC_ALGO="${ENC_ALGO:-$ENC_ALGO_DEFAULT}"
  fi

  # Stop first so port-free check does not see our own listeners.
  systemctl stop "${SERVICE_NAME}.service" 2>/dev/null || true
  sleep 1

  # Kharej encrypt: check INTERNAL ports only (not panel PUBLIC ports).
  if [[ "$side" == "kharej" && "$encrypt" == "1" ]]; then
    resolve_kharej_encrypt_bind_or_fallback "$encrypt" "$key" "$ports" "$offset"
    encrypt="$ENCRYPT_RESOLVED"
    key="$KEY_RESOLVED"
  fi

  write_core_json "$side" "$mtu"
  if [[ "$side" == "ir" ]]; then
    # Iran always needs exclusive PUBLIC listen ports (encrypt or not).
    assert_ports_free "$ports"
    write_iran_config "$iran_ip" "$kh_ip" "$proto" "$encrypt" "$key" "$ports" "$offset"
  else
    write_kharej_config "$iran_ip" "$kh_ip" "$proto" "$encrypt" "$key" "$ports" "$offset"
  fi
  write_env "$side" "$iran_ip" "$kh_ip" "$proto" "$encrypt" "$key" "$ports" "$oldcpu" "$offset"
  write_service
  systemctl daemon-reload || true
  systemctl enable "${SERVICE_NAME}.service" || warn "Could not enable ${SERVICE_NAME}.service"
  systemctl restart "${SERVICE_NAME}.service" || true
  sleep 2
  if [[ "$(systemctl is-active "${SERVICE_NAME}.service" 2>/dev/null || true)" == "active" ]]; then
    if [[ "$encrypt" == "1" ]]; then
      ok "Tunnel config applied; service active (PROTO=${proto} ENCRYPT=1 ALGO=${ENC_ALGO} OFFSET=${offset})"
      ok "Encrypt hop INTERNAL ports: $(internal_ports_list "$ports" "$offset")"
    else
      ok "Tunnel config applied; service active (PROTO=${proto} ENCRYPT=0)"
    fi
    return 0
  fi
  show_failure_logs
  err "Service failed after config update"
}

edit_tunnel() {
  [[ -f "$CONF_ENV" ]] || err "Not installed (missing $CONF_ENV). Run Install first."
  # shellcheck disable=SC1090
  source "$CONF_ENV"

  local side iran_ip kh_ip ports proto encrypt key oldcpu offset tmp
  side="${SIDE:-}"
  iran_ip="${IRAN_IP:-}"
  kh_ip="${KHAREJ_IP:-}"
  ports="${PORTS:-}"
  proto="${PROTO:-51}"
  encrypt="${ENCRYPT:-0}"
  key="${AES_KEY:-}"
  oldcpu="${OLDCPU:-0}"
  offset="${PORT_OFFSET:-$PORT_OFFSET_DEFAULT}"
  PORT_OFFSET="$offset"
  ENC_ALGO="${ENC_ALGO:-$ENC_ALGO_DEFAULT}"

  [[ -n "$side" && -n "$iran_ip" && -n "$kh_ip" ]] || err "tunnel.env incomplete; reinstall"

  local this_ip=""
  this_ip="$(detect_public_ip || true)"

  echo
  echo -e "${CYN}Edit tunnel${NC} (Enter keeps current value)"
  echo "  current side : ${side}"
  echo "  PROTO is saved to tunnel.env and written into IpManipulator.protoswap"
  if [[ -n "${this_ip:-}" ]]; then
    echo -e "  this server  : ${GRN}${this_ip}${NC}  (auto-detected; copy if needed)"
    if [[ "$side" == "ir" ]]; then
      iran_ip="${iran_ip:-$this_ip}"
    else
      kh_ip="${kh_ip:-$this_ip}"
    fi
  fi
  echo

  read_tty -r -p "Iran public IP [${iran_ip}]: " tmp || true
  [[ -n "${tmp:-}" ]] && iran_ip="$tmp"
  validate_ip "$iran_ip" || err "Invalid Iran IP"

  read_tty -r -p "Kharej public IP [${kh_ip}]: " tmp || true
  [[ -n "${tmp:-}" ]] && kh_ip="$tmp"
  validate_ip "$kh_ip" || err "Invalid Kharej IP"

  echo
  echo -e "${CYN}IP protocol number (protoswap)${NC} — must match on Iran and Kharej"
  read_tty -r -p "Protocol [${proto}]: " tmp || true
  [[ -n "${tmp:-}" ]] && proto="$tmp"
  [[ "$proto" =~ ^[0-9]+$ ]] && ((proto >= 0 && proto <= 255)) || err "Invalid protocol (0-255)"

  local enc_prompt="N"
  [[ "$encrypt" == "1" ]] && enc_prompt="Y"
  echo
  echo -e "${CYN}Encryption${NC} (official WaterWall AEAD nodes — NOT the removed AesGcm plugin)"
  echo "  Iran  : TcpListener(0.0.0.0:PUBLIC) -> EncryptionClient -> TcpConnector(${TUN_PEER}:INTERNAL)"
  echo "  Kharej: TcpListener(${TUN_LOCAL}:INTERNAL) -> EncryptionServer -> TcpConnector(127.0.0.1:PUBLIC)"
  echo "  INTERNAL = PUBLIC + PORT_OFFSET (default ${PORT_OFFSET_DEFAULT}; e.g. 443 -> $((443 + PORT_OFFSET_DEFAULT)))"
  echo "  Iran MAY use 0.0.0.0 WITH encryption — that is fine."
  echo "  Kharej panel may stay on 0.0.0.0:PUBLIC — installer never moves panel/x-ui."
  echo "  Docs  : https://radkesvat.github.io/WaterWall-Docs/docs/noderefs/EncryptionClient"
  echo "  Algo  : auto-probe (prefer chacha20-poly1305; current saved: ${ENC_ALGO:-$ENC_ALGO_DEFAULT})"
  echo "  Default OFF for safety. No libs/ plugin required (nodes are built into the binary)."
  read_tty -r -p "Enable EncryptionClient/Server? [y/N] (current: ${enc_prompt}): " tmp || true
  case "${tmp:-}" in
    y|Y|yes|YES) encrypt=1 ;;
    n|N|no|NO) encrypt=0 ;;
    "") ;; # keep current
    *) warn "Keeping current encrypt=${encrypt}" ;;
  esac

  # Ports: always prompted on Iran. On Kharej only when encryption is on
  # (same PUBLIC list; INTERNAL hop uses PUBLIC+PORT_OFFSET).
  if [[ "$side" == "ir" ]]; then
    read_tty -r -p "Listen / forward ports (PUBLIC) [${ports:-$DEFAULT_PORTS}]: " tmp || true
    [[ -n "${tmp:-}" ]] && ports="$(normalize_ports "$tmp")"
    ports="$(normalize_ports "${ports:-$DEFAULT_PORTS}")"
    [[ -n "$ports" ]] || err "Ports required"
    validate_ports "$ports" || err "Invalid ports"
  elif [[ "$encrypt" == "1" ]]; then
    echo
    echo -e "${CYN}Kharej PUBLIC ports (same list as Iran)${NC}"
    echo "  WaterWall binds INTERNAL=PUBLIC+${offset} on ${TUN_LOCAL} (not PUBLIC)."
    echo "  Panel keeps 0.0.0.0:PUBLIC — connecting to 127.0.0.1:PUBLIC is OK."
    if [[ -n "${ports:-}" ]]; then
      echo -e "  Auto-using saved PORTS from tunnel.env: ${GRN}${ports}${NC}"
      read_tty -r -p "Press Enter to keep, or type new ports: " tmp || true
      [[ -n "${tmp:-}" ]] && ports="$(normalize_ports "$tmp")"
    else
      read_tty -r -p "Same PUBLIC ports as Iran [${DEFAULT_PORTS}]: " tmp || true
      ports="$(normalize_ports "${tmp:-$DEFAULT_PORTS}")"
    fi
    ports="$(normalize_ports "${ports:-$DEFAULT_PORTS}")"
    [[ -n "$ports" ]] || err "Ports required for Kharej encryption"
    validate_ports "$ports" || err "Invalid ports"
  fi

  if [[ "$encrypt" == "1" ]]; then
    read_tty -r -p "PORT_OFFSET for INTERNAL hop [${offset}]: " tmp || true
    [[ -n "${tmp:-}" ]] && offset="$tmp"
    validate_port_offset "$offset" || err "Invalid PORT_OFFSET (1..60000)"
    validate_ports_with_offset "$ports" "$offset" \
      || err "PUBLIC+PORT_OFFSET must be <= 65535 for all ports"
    PORT_OFFSET="$offset"
    echo "  INTERNAL ports will be: $(internal_ports_list "$ports" "$offset")"

    read_tty -r -p "Shared password / AES key (32 chars) [${key:-empty=auto}]: " tmp || true
    if [[ -n "${tmp:-}" ]]; then
      key="$tmp"
    elif [[ -z "${key:-}" ]]; then
      msg "Generating 32-char key..."
      key="$(gen_key)" || err "Key auto-generation failed"
      echo -e "${YLW}Generated key (use SAME on other side):${NC} ${GRN}${key}${NC}"
    fi
    [[ ${#key} -eq 32 ]] || err "Key must be exactly 32 characters (got ${#key})"
  fi
  # When encrypt stays/falls to 0, keep existing AES_KEY in env if present (retry later).

  local old_prompt="N"
  [[ "$oldcpu" == "1" ]] && old_prompt="Y"
  local prev_oldcpu="$oldcpu"
  read_tty -r -p "Use old-cpu WaterWall binary? [y/N] (current: ${old_prompt}): " tmp || true
  case "${tmp:-}" in
    y|Y|yes|YES) oldcpu=1 ;;
    n|N|no|NO) oldcpu=0 ;;
    "") ;; # keep
    *) ;;
  esac

  msg "Rewriting configs from edited values..."
  if [[ "$oldcpu" != "$prev_oldcpu" ]] || [[ ! -x "${INSTALL_DIR}/Waterwall" ]]; then
    ensure_deps
    download_waterwall "$oldcpu"
  fi

  # refresh cached installer if possible
  if [[ -f "${BASH_SOURCE[0]:-}" && -r "${BASH_SOURCE[0]}" ]]; then
    cp -f "${BASH_SOURCE[0]}" "${INSTALL_DIR}/install.sh" 2>/dev/null || true
  fi

  apply_tunnel_config "$side" "$iran_ip" "$kh_ip" "$proto" "$encrypt" "$key" "$ports" "$oldcpu" "$offset"
  enable_watchdog

  # Re-read resolved encrypt after possible fallback
  if [[ -f "$CONF_ENV" ]]; then
    # shellcheck disable=SC1090
    source "$CONF_ENV"
    encrypt="${ENCRYPT:-$encrypt}"
    offset="${PORT_OFFSET:-$offset}"
  fi

  echo
  ok "Edit applied on side=${side}"
  echo "  iran ip   : $iran_ip"
  echo "  kharej ip : $kh_ip"
  echo "  proto     : $proto   (saved in $CONF_ENV as PROTO=)"
  echo "  encrypt   : $encrypt"
  echo "  ports     : ${ports:-none}  (PUBLIC)"
  echo "  offset    : $offset"
  if [[ "$encrypt" == "1" ]]; then
    echo -e "  ${YLW}key       : ${key}${NC}"
    echo "  algorithm : ${ENC_ALGO:-$ENC_ALGO_DEFAULT}  salt=${ENC_SALT_DEFAULT}"
    echo "  internal  : $(internal_ports_list "$ports" "$offset")  (TUN encrypt hop)"
    echo "  panel     : may stay on 0.0.0.0:PUBLIC (installer never moves it)"
  else
    echo "  encrypt  : off (packet tunnel only; panel may stay on 0.0.0.0)"
  fi
  echo "  Apply the same IPs / PROTO / encrypt / key / ports / PORT_OFFSET / algorithm on the other server if you changed them."
}

prompt_install() {
  local side iran_ip kh_ip ports proto encrypt key oldcpu offset mtu this_ip
  local iran_default="" kh_default=""
  offset="$PORT_OFFSET_DEFAULT"
  this_ip="$(detect_public_ip || true)"

  echo
  echo -e "${CYN}WaterWall Proto51 v2 — second tunnel${NC}"
  echo "  Runs alongside v1 (ww51 / waterwall-proto51). Does NOT stop or change v1."
  echo "  v2 uses: ${TUN_DEVICE} ${TUN_CIDR} peer ${TUN_PEER} | menu ww51v2 | ports ${DEFAULT_PORTS}"
  echo
  echo -e "${CYN}Select side:${NC}"
  echo "  1) Iran   (listen 0.0.0.0 and forward selected ports to kharej)"
  echo "  2) Kharej (packet tunnel endpoint; panel should listen on ports)"
  if [[ -n "${this_ip:-}" ]]; then
    echo -e "  Detected this server public IP: ${GRN}${this_ip}${NC}  (used as default for the matching side)"
  fi
  read_tty -r -p "Choice [1/2]: " side
  case "$side" in
    1) side="ir" ;;
    2) side="kharej" ;;
    *) err "Invalid choice" ;;
  esac

  if [[ -n "${this_ip:-}" ]]; then
    if [[ "$side" == "ir" ]]; then
      iran_default="$this_ip"
    else
      kh_default="$this_ip"
    fi
  fi

  if [[ -n "${iran_default:-}" ]]; then
    read_tty -r -p "Iran public IP [${iran_default}]: " iran_ip || true
    iran_ip="${iran_ip:-$iran_default}"
  else
    read_tty -r -p "Iran public IP: " iran_ip
  fi
  validate_ip "$iran_ip" || err "Invalid Iran IP"

  if [[ -n "${kh_default:-}" ]]; then
    read_tty -r -p "Kharej public IP [${kh_default}]: " kh_ip || true
    kh_ip="${kh_ip:-$kh_default}"
  else
    read_tty -r -p "Kharej public IP: " kh_ip
  fi
  validate_ip "$kh_ip" || err "Invalid Kharej IP"

  echo
  echo -e "${CYN}IP protocol number (protoswap)${NC}"
  echo "  Saved as PROTO in tunnel.env; must be identical on Iran and Kharej."
  echo "  You can change it later via menu 4) Edit tunnel."
  proto=51
  read_tty -r -p "Protocol number [${proto}]: " tmp || true
  [[ -n "${tmp:-}" ]] && proto="$tmp"
  [[ "$proto" =~ ^[0-9]+$ ]] && ((proto >= 0 && proto <= 255)) || err "Invalid protocol (0-255)"

  # Default OFF until user opts in. Encryption uses built-in EncryptionClient/Server
  # (docs), not the removed AesGcm dynamic library that crashed with:
  #   library "AesGcm" ... could not be loaded
  encrypt=0
  echo
  echo -e "${CYN}Encryption (optional, default OFF)${NC}"
  echo "  Uses official AEAD nodes EncryptionClient + EncryptionServer (built into binary)."
  echo "  Docs: https://radkesvat.github.io/WaterWall-Docs/docs/noderefs/EncryptionClient"
  echo "  Encrypt hop uses INTERNAL ports on TUN: INTERNAL = PUBLIC + PORT_OFFSET (default ${PORT_OFFSET_DEFAULT})."
  echo "  Iran 0.0.0.0 + encryption is OK. Kharej panel may stay on 0.0.0.0:PUBLIC (never moved)."
  echo "  Algorithm auto-selected after download (prefer chacha20-poly1305; aes-gcm only if usable)."
  echo "  old-cpu binaries: AES-GCM is unavailable — script uses chacha20-poly1305 or falls back to OFF."
  echo "  No libs/ plugin download is required. AesGcm plugin is NOT used."
  read_tty -r -p "Enable EncryptionClient/Server? [y/N]: " tmp || true
  case "${tmp:-N}" in
    y|Y|yes|YES) encrypt=1 ;;
    *) encrypt=0 ;;
  esac

  ports=""
  if [[ -f "$CONF_ENV" ]]; then
    # shellcheck disable=SC1090
    # Keep previously saved PORTS / AES_KEY / PORT_OFFSET hints when reinstalling.
    source "$CONF_ENV"
    ports="${PORTS:-}"
    offset="${PORT_OFFSET:-$PORT_OFFSET_DEFAULT}"
  fi
  if [[ "$side" == "ir" ]]; then
    echo "PUBLIC ports to forward from Iran 0.0.0.0 (space/comma separated)"
    read_tty -r -p "Ports [${ports:-$DEFAULT_PORTS}]: " tmp || true
    ports="$(normalize_ports "${tmp:-${ports:-$DEFAULT_PORTS}}")"
    validate_ports "$ports" || err "Invalid ports"
    warn_v1_port_overlap "$ports"
  elif [[ "$encrypt" == "1" ]]; then
    echo
    echo -e "${CYN}Kharej PUBLIC ports (same list as Iran)${NC}"
    echo "  WaterWall binds INTERNAL=PUBLIC+PORT_OFFSET on ${TUN_LOCAL} (not PUBLIC)."
    echo "  Panel may keep 0.0.0.0:PUBLIC — installer never touches x-ui/xray."
    if [[ -n "${ports:-}" ]]; then
      echo -e "  Auto-using saved PORTS from tunnel.env: ${GRN}${ports}${NC}"
      read_tty -r -p "Press Enter to keep, or type new ports: " tmp || true
      [[ -n "${tmp:-}" ]] && ports="$(normalize_ports "$tmp")"
    else
      read_tty -r -p "Same PUBLIC ports as Iran [${DEFAULT_PORTS}]: " tmp || true
      ports="$(normalize_ports "${tmp:-$DEFAULT_PORTS}")"
    fi
    ports="$(normalize_ports "${ports:-$DEFAULT_PORTS}")"
    validate_ports "$ports" || err "Invalid ports"
  fi

  key=""
  if [[ "$encrypt" == "1" ]]; then
    read_tty -r -p "PORT_OFFSET for INTERNAL hop [${offset}]: " tmp || true
    [[ -n "${tmp:-}" ]] && offset="$tmp"
    validate_port_offset "$offset" || err "Invalid PORT_OFFSET (1..60000)"
    validate_ports_with_offset "$ports" "$offset" \
      || err "PUBLIC+PORT_OFFSET must be <= 65535 for all ports"
    PORT_OFFSET="$offset"
    echo "  INTERNAL ports will be: $(internal_ports_list "$ports" "$offset")"

    read_tty -r -p "Shared password / AES key (32 chars, empty=auto): " key || true
    if [[ -z "${key:-}" ]]; then
      msg "Generating 32-char key..."
      key="$(gen_key)" || err "Key auto-generation failed"
      echo
      echo -e "${YLW}Generated key (save + use SAME key on the other side):${NC}"
      echo -e "  ${GRN}${key}${NC}"
      echo
    fi
    [[ ${#key} -eq 32 ]] || err "Key must be exactly 32 characters (got ${#key})"
  fi

  oldcpu=0
  read_tty -r -p "Use old-cpu WaterWall binary? [y/N]: " tmp || true
  case "${tmp:-N}" in
    y|Y|yes|YES) oldcpu=1 ;;
    *) oldcpu=0 ;;
  esac

  if [[ "$side" == "ir" ]]; then mtu=1320; else mtu=1380; fi

  msg "Starting install for side=${side}..."
  ensure_deps
  download_waterwall "$oldcpu"

  if [[ "$encrypt" == "1" ]]; then
    resolve_encryption_or_fallback "$encrypt" "$key" "$oldcpu"
    encrypt="$ENCRYPT_RESOLVED"
    key="$KEY_RESOLVED"
  else
    ENC_ALGO="$ENC_ALGO_DEFAULT"
  fi

  msg "Writing core.json and tunnel config..."
  write_core_json "$side" "$mtu"

  if [[ "$side" == "ir" ]]; then
    msg "Checking Iran PUBLIC listen ports are free..."
    assert_ports_free "$ports"
    write_iran_config "$iran_ip" "$kh_ip" "$proto" "$encrypt" "$key" "$ports" "$offset"
  else
    if [[ "$encrypt" == "1" ]]; then
      msg "Checking Kharej INTERNAL encrypt ports (PUBLIC+${offset}) are free..."
      # Stop existing unit first so we do not false-positive on our own listeners.
      systemctl stop "${SERVICE_NAME}.service" 2>/dev/null || true
      sleep 1
      resolve_kharej_encrypt_bind_or_fallback "$encrypt" "$key" "$ports" "$offset"
      encrypt="$ENCRYPT_RESOLVED"
      key="$KEY_RESOLVED"
    fi
    write_kharej_config "$iran_ip" "$kh_ip" "$proto" "$encrypt" "$key" "$ports" "$offset"
  fi
  ok "Config files written under $INSTALL_DIR"

  # keep installer locally for ww51v2 menu
  msg "Saving installer copy..."
  if [[ -f "${BASH_SOURCE[0]:-}" && -r "${BASH_SOURCE[0]}" ]]; then
    cp -f "${BASH_SOURCE[0]}" "${INSTALL_DIR}/install.sh" 2>/dev/null || true
  fi
  if [[ ! -f "${INSTALL_DIR}/install.sh" ]]; then
    curl -fsSL "${REPO_RAW}/install.sh" -o "${INSTALL_DIR}/install.sh" || warn "Could not cache install.sh locally"
  fi
  chmod +x "${INSTALL_DIR}/install.sh" 2>/dev/null || true

  msg "Writing config (tunnel.env)..."
  write_env "$side" "$iran_ip" "$kh_ip" "$proto" "$encrypt" "$key" "$ports" "$oldcpu" "$offset"
  [[ -f "$CONF_ENV" ]] || err "Failed to write $CONF_ENV"

  msg "Installing systemd unit..."
  write_service
  [[ -f "/etc/systemd/system/${SERVICE_NAME}.service" ]] || err "Failed to write systemd unit"
  write_menu_wrapper
  sysctl_tune

  # disable ufw if present (common for raw/tun tunnels)
  if command -v ufw >/dev/null 2>&1; then
    msg "Disabling ufw (raw/tun tunnels)..."
    ufw disable >/dev/null 2>&1 || true
  fi

  start_service
  enable_watchdog

  # Verify boot persistence
  if systemctl is-enabled --quiet "${SERVICE_NAME}.service" 2>/dev/null; then
    ok "Service enabled at boot (survives reboot)"
  else
    warn "Service may not be enabled at boot — run: systemctl enable ${SERVICE_NAME}"
  fi

  echo
  ok "Installed on side=${side}"
  echo "  dir      : $INSTALL_DIR"
  echo "  service  : systemctl status ${SERVICE_NAME}"
  echo "  watchdog : systemctl status ${SERVICE_NAME}-watchdog.timer"
  echo "  menu     : ww51v2"
  echo "  config   : $CONF_ENV"
  echo "  PROTO    : $proto  (change anytime: sudo ww51v2 edit)"
  if [[ "$side" == "ir" ]]; then
    echo "  forward  : 0.0.0.0:{${ports// /,}} -> ${kh_ip} via ${TUN_PEER}"
    if [[ "$encrypt" == "1" ]]; then
      echo "  encrypt  : EncryptionClient on PUBLIC ports; hop to INTERNAL on TUN"
      echo "  internal : $(internal_ports_list "$ports" "$offset")  (PORT_OFFSET=${offset})"
      echo "  note     : on Kharej enable encryption too (same key/PROTO/ports/offset)"
      echo "            panel may stay on 0.0.0.0:PUBLIC — never moved by this installer"
    else
      echo "  note     : on Kharej, panel/xray may listen on the same ports (0.0.0.0 or ${TUN_LOCAL})"
    fi
  else
    echo "  note     : start Kharej first, then Iran"
    if [[ "$encrypt" == "1" ]]; then
      echo "  encrypt  : EncryptionServer on ${TUN_LOCAL}:INTERNAL -> 127.0.0.1:PUBLIC"
      echo "  internal : $(internal_ports_list "$ports" "$offset")  (PORT_OFFSET=${offset})"
      echo "  panel    : may stay on 0.0.0.0:PUBLIC (installer never touches x-ui)"
    else
      echo "  encrypt  : off (compatible with panel on 0.0.0.0)"
    fi
  fi
  if [[ "$encrypt" == "1" ]]; then
    echo -e "  ${YLW}key      : ${key}${NC}"
    echo "            use the SAME key + PROTO + ports + PORT_OFFSET + algorithm on both servers"
    echo "  algo     : ${ENC_ALGO:-$ENC_ALGO_DEFAULT}  salt=${ENC_SALT_DEFAULT}"
    echo "            old-cpu binaries use chacha20-poly1305 (AES-GCM unavailable)"
  else
    echo "  encrypt  : off"
  fi
}

apply_from_env() {
  # Non-interactive: rewrite JSON + restart from existing tunnel.env
  [[ -f "$CONF_ENV" ]] || err "Not installed (missing $CONF_ENV)"
  # shellcheck disable=SC1090
  source "$CONF_ENV"
  [[ -n "${SIDE:-}" && -n "${IRAN_IP:-}" && -n "${KHAREJ_IP:-}" ]] || err "tunnel.env incomplete"
  ENC_ALGO="${ENC_ALGO:-$ENC_ALGO_DEFAULT}"
  PORT_OFFSET="${PORT_OFFSET:-$PORT_OFFSET_DEFAULT}"
  apply_tunnel_config "${SIDE}" "$IRAN_IP" "$KHAREJ_IP" "${PROTO:-51}" "${ENCRYPT:-0}" "${AES_KEY:-}" "${PORTS:-}" "${OLDCPU:-0}" "$PORT_OFFSET"
  enable_watchdog
}

change_ports() {
  [[ -f "$CONF_ENV" ]] || err "Not installed"
  # shellcheck disable=SC1090
  source "$CONF_ENV"

  # Iran always owns forward ports. Kharej needs the same list when encryption is on.
  if [[ "${SIDE}" != "ir" && "${ENCRYPT:-0}" != "1" ]]; then
    err "Port list is edited on Iran (or enable encryption on Kharej and use Edit tunnel)"
  fi

  local ports offset
  offset="${PORT_OFFSET:-$PORT_OFFSET_DEFAULT}"
  read_tty -r -p "New PUBLIC ports (space/comma) [${PORTS:-$DEFAULT_PORTS}]: " ports
  ports="$(normalize_ports "${ports:-${PORTS:-$DEFAULT_PORTS}}")"
  validate_ports "$ports" || err "Invalid ports"
  if [[ "${ENCRYPT:-0}" == "1" ]]; then
    validate_ports_with_offset "$ports" "$offset" \
      || err "PUBLIC+PORT_OFFSET=${offset} must be <= 65535 for all ports"
  fi

  apply_tunnel_config "${SIDE}" "$IRAN_IP" "$KHAREJ_IP" "$PROTO" "${ENCRYPT:-0}" "${AES_KEY:-}" "$ports" "${OLDCPU:-0}" "$offset"
  ok "Ports updated: $ports (PROTO=${PROTO} OFFSET=${offset})"
  if [[ "${SIDE}" == "ir" && "${ENCRYPT:-0}" == "1" ]]; then
    warn "Also update the same PUBLIC ports + PORT_OFFSET on Kharej (sudo ww51v2 edit)."
  fi
}

menu() {
  local this_ip=""
  while true; do
    clear 2>/dev/null || true
    this_ip="$(detect_public_ip || true)"
    echo -e "${CYN}WaterWall Proto51 v2 Tunnel (second instance — alongside v1)${NC}"
    echo "========================="
    if [[ -n "${this_ip:-}" ]]; then
      echo -e "This server IP: ${GRN}${this_ip}${NC}  (auto-detected — copy for the other side)"
    else
      echo "This server IP: (auto-detect failed)"
    fi
    echo
    echo "1) Install / Reinstall"
    echo "2) Status"
    echo "3) Restart"
    echo "4) Edit tunnel (IPs / PROTO / ports / encryption)"
    echo "5) Change ports"
    echo "6) Show tunnel logs"
    echo "7) Uninstall"
    echo "0) Exit"
    echo
    echo -e "  Docs: ${CYN}https://radkesvat.github.io/WaterWall-Docs/docs/intro${NC}"
    echo
    read_tty -r -p "Select: " c || exit 0
    case "$c" in
      1) prompt_install ;;
      2) show_status ;;
      3) systemctl restart "$SERVICE_NAME"; show_status ;;
      4) edit_tunnel ;;
      5) change_ports ;;
      6) show_tunnel_logs ;;
      7) uninstall_all ;;
      0) exit 0 ;;
      *) warn "Invalid option" ;;
    esac
    echo
    read_tty -r -p "Press Enter to continue..." _ || true
  done
}

main() {
  need_root
  case "${1:-}" in
    install) prompt_install ;;
    status) show_status ;;
    restart) systemctl restart "$SERVICE_NAME"; show_status ;;
    edit) edit_tunnel ;;
    uninstall) uninstall_all ;;
    ports) change_ports ;;
    logs) show_tunnel_logs ;;
    apply) apply_from_env ;;
    *) menu ;;
  esac
}

main "$@"
