# MultiStress v2

HTTP stress testing tool with **7 attack vectors** running simultaneously.  
Supports proxy rotation, and runs on Linux, macOS, and Windows.

> **For authorized testing only.** Only use against infrastructure you own or have explicit written permission to test.

---

## Attack Vectors

| # | Tool | Vector | Protocol | What it tests |
|---|------|---------|----------|---------------|
| 1 | bombardier | HTTP/2 multiplexed flood | HTTP/2 | Multiplexed request handling |
| 2 | hey | HTTP/1.1 keep-alive flood | HTTP/1.1 | Connection pool exhaustion |
| 3 | vegeta | Constant-rate flood | HTTP/1.1 + HTTP/2 | Sustained load, rate limiters |
| 4 | fortio | Latency-aware flood | HTTP/1.1 + HTTP/2 | Backend throughput under pressure |
| 5 | slowloris | Never-closing connections | TCP/TLS | Connection slot exhaustion |
| 6 | ssl_exhaustion | TLS handshake flood | TLS | TLS termination CPU cost |
| 7 | cache_bypass | Random query string | HTTP/1.1 | CDN cache, origin server load |

Total default load: **400 workers × 4 HTTP tools + 200 slowloris + 100 SSL threads ≈ 1900 concurrent connections**

---

## Scripts

| Script | OS | Proxy |
|--------|----|-------|
| `run.sh` | Linux / Ubuntu | No |
| `run-proxy.sh` | Linux / Ubuntu | Yes (SOCKS5 + HTTP) |
| `run-mac.sh` | macOS | No |
| `run-mac-proxy.sh` | macOS | Yes (SOCKS5 + HTTP) |
| `run-windows.ps1` | Windows | No |
| `run-windows-proxy.ps1` | Windows | Yes (HTTP native, SOCKS5 for Python tools) |

---

## Quick Start

### Linux

```bash
git clone https://github.com/KLEFTIS30/multistress.git
cd multistress
chmod +x run.sh run-proxy.sh

# Without proxy
./run.sh

# With proxy
./run-proxy.sh proxies.txt
```

### macOS

```bash
git clone https://github.com/KLEFTIS30/multistress.git
cd multistress
chmod +x run-mac.sh run-mac-proxy.sh

# Without proxy (installs Homebrew + tools automatically)
./run-mac.sh

# With proxy
./run-mac-proxy.sh proxies.txt
```

### Windows

Open PowerShell as Administrator:

```powershell
git clone https://github.com/KLEFTIS30/multistress.git
cd multistress

# Allow script execution (once)
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned

# Without proxy
.\run-windows.ps1

# With proxy
.\run-windows-proxy.ps1 proxies.txt
```

> **Windows note:** SOCKS5 proxies are only supported for slowloris and ssl_exhaustion (via Python PySocks).  
> For bombardier, hey, fortio — use HTTP proxies on Windows.  
> On Linux/macOS all 7 tools work with SOCKS5 via proxychains.

---

## Proxy File Format

Edit `proxies.txt` — one proxy per line:

```
# SOCKS5 (recommended — works for all 7 vectors on Linux/macOS)
socks5://1.2.3.4:1080
socks5://user:password@5.6.7.8:1080

# HTTP (works on all platforms, but not for raw TCP vectors)
http://9.10.11.12:3128
http://user:password@13.14.15.16:8080
```

**Minimum 7 proxies** for one per tool. If you have fewer, they rotate in round-robin.

### SOCKS5 vs HTTP

| Feature | SOCKS5 | HTTP |
|---------|--------|------|
| HTTP flood tools | ✓ | ✓ |
| Slowloris (raw TCP) | ✓ | ✗ |
| SSL exhaustion (raw TCP) | ✓ | ✗ |
| Windows native support | Partial* | ✓ |
| Overhead | Low | Medium |

*On Windows, SOCKS5 works for Python-based tools (slowloris, ssl_exhaustion). For Go tools use HTTP proxy or proxychains on WSL.

---

## Configuration

Edit the top of any script to change defaults:

```bash
TARGET="https://your-site.com"   # target URL
DURATION=300                      # duration in seconds
WORKERS=400                       # concurrent workers per HTTP tool
```

---

## Deploying on Render.com (cloud)

Run from a different IP address using Render's free tier:

1. Fork this repo on GitHub
2. Go to [render.com](https://render.com) → **New** → **Background Worker**
3. Connect your forked GitHub repo
4. Set **Environment** to `Docker`
5. Click **Deploy**

To run from **multiple IPs simultaneously**, create multiple Render services pointing to the same repo — each gets a different IP.

---

## Stop

- **Linux/macOS:** `Ctrl+C` — all 7 processes killed immediately
- **Windows:** `Ctrl+C` — all PowerShell jobs stopped

---

## How Each Vector Works

**bombardier — HTTP/2 flood**  
Opens HTTP/2 connections and sends requests via multiplexing. One TCP connection carries many streams, bypassing per-connection rate limits.

**hey — HTTP/1.1 keep-alive flood**  
Opens many persistent TCP connections and floods with GET requests. Tests connection pool exhaustion on the server.

**vegeta — constant-rate flood**  
Sends at a perfectly steady request rate. Harder for adaptive rate limiters to detect since it mimics consistent legitimate traffic patterns.

**fortio — latency-aware flood**  
Keeps all workers busy at all times regardless of server response latency. Does not slow down when the server starts struggling.

**slowloris — slow open connections**  
Establishes TLS connections and sends partial HTTP headers, never completing the request. Ties up server connection slots without sending meaningful data. Effective against servers with limited connection pools.

**ssl_exhaustion — TLS handshake flood**  
Performs TLS handshakes and immediately closes, forcing the server to do expensive asymmetric crypto (RSA/ECDH key exchange) for each connection. Targets TLS termination CPU budget.

**cache_bypass — random query string**  
Appends a unique random string (`?bust=abc123`) to every request URL, making each URL unique. Forces CDN/cache layers to treat every request as a miss and forward to the origin server.
