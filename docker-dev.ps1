<#
.SYNOPSIS
    Paperless-NGX Docker development launcher.

.DESCRIPTION
    Manages a local Docker Compose stack built from YOUR source code.
    On first run it builds a local image from the Dockerfile, then starts
    the full stack: Redis broker + Paperless webserver (Django + Angular together).

    Access the app at:  http://localhost:8000
    Default login:      admin / admin   (auto-created on first start)

    When to rebuild vs restart:
      Python/Django change       →  .\docker-dev.ps1 -Action rebuild
      Angular/HTML/SCSS change   →  .\docker-dev.ps1 -Action rebuild
      docker-compose.env change  →  .\docker-dev.ps1 -Action restart  (no rebuild needed)
      Wipe all data + fresh start→  .\docker-dev.ps1 -Action reset

.PARAMETER Action
    start    - Smart start: builds image if source changed, then starts
    stop     - Stop containers (data volumes are preserved)
    restart  - Stop then start without rebuilding
    rebuild  - Force full image rebuild then start
    reset    - DANGER: wipe all data volumes then rebuild + start fresh
    status   - Show running container status
    logs     - Tail live logs (Ctrl+C to exit)
    open     - Open http://localhost:8000 in browser

.PARAMETER Service
    With 'logs': restrict to 'webserver' or 'broker'.

.PARAMETER NoBuild
    Skip build check even when source changes are detected.

.EXAMPLE
    .\docker-dev.ps1                         # smart start
    .\docker-dev.ps1 -Action rebuild         # force rebuild + start
    .\docker-dev.ps1 -Action logs            # live log tail
    .\docker-dev.ps1 -Action logs -Service webserver
    .\docker-dev.ps1 -Action reset           # wipe all data, fresh start
    .\docker-dev.ps1 -Action open            # open browser
#>
param(
    [ValidateSet("start","stop","restart","rebuild","reset","status","logs","open")]
    [string]$Action = "start",

    [ValidateSet("","webserver","broker")]
    [string]$Service = "",

    [switch]$NoBuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── paths ──────────────────────────────────────────────────────────────────────
$RepoRoot     = $PSScriptRoot
$ComposeDir   = Join-Path $RepoRoot "docker\compose"
$ComposeFile  = Join-Path $ComposeDir "docker-compose.sqlite.yml"
$EnvFile      = Join-Path $ComposeDir "docker-compose.env"
$OverrideFile = Join-Path $ComposeDir "docker-compose.dev-override.yml"
$StateFile    = Join-Path $RepoRoot ".paperless-dev\docker-state.json"
$LocalImage   = "paperless-ngx-dev:local"
$ProjectName  = "paperless-dev"
$AppUrl       = "http://localhost:8000"

# ── console helpers ────────────────────────────────────────────────────────────
function Write-Step([string]$msg) { Write-Host ""; Write-Host "  >>> $msg" -ForegroundColor Cyan }
function Write-Ok([string]$msg)   { Write-Host "  [OK] $msg" -ForegroundColor Green }
function Write-Warn([string]$msg) { Write-Host "  [!!] $msg" -ForegroundColor Yellow }
function Write-Err([string]$msg)  { Write-Host "  [XX] $msg" -ForegroundColor Red }

function Write-Banner {
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════════════╗" -ForegroundColor DarkCyan
    Write-Host "  ║       Paperless-NGX  Docker Dev Launcher         ║" -ForegroundColor DarkCyan
    Write-Host "  ╚══════════════════════════════════════════════════╝" -ForegroundColor DarkCyan
    Write-Host ""
}

# ── docker guard ───────────────────────────────────────────────────────────────
function Ensure-Docker {
    if ($null -eq (Get-Command "docker" -ErrorAction SilentlyContinue)) {
        Write-Err  "Docker is not installed or not on PATH."
        Write-Host "  Install Docker Desktop: https://www.docker.com/products/docker-desktop/" -ForegroundColor Yellow
        Write-Host "  Enable 'Use the WSL 2 based engine' in Docker Desktop settings."           -ForegroundColor Yellow
        exit 1
    }
    $prevPref = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    docker info *> $null
    $ok = ($LASTEXITCODE -eq 0)
    $ErrorActionPreference = $prevPref
    if (-not $ok) {
        Write-Err  "Docker daemon is not running."
        Write-Host "  Start Docker Desktop, wait for it to fully initialize, then retry." -ForegroundColor Yellow
        exit 1
    }
}

# ── state helpers ──────────────────────────────────────────────────────────────
function Ensure-StateDir {
    $d = Split-Path -Parent $StateFile
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d | Out-Null }
}

function Read-BuildState {
    if (-not (Test-Path -LiteralPath $StateFile)) { return $null }
    return Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json
}

function Write-BuildState([string]$hash) {
    Ensure-StateDir
    @{ sourceHash = $hash; builtAt = (Get-Date).ToString("s") } |
        ConvertTo-Json | Set-Content -LiteralPath $StateFile -Encoding UTF8
}

function Get-SourceHash {
    $watched = @(
        (Join-Path $RepoRoot "src"),
        (Join-Path $RepoRoot "src-ui"),
        (Join-Path $RepoRoot "Dockerfile"),
        (Join-Path $RepoRoot "pyproject.toml"),
        (Join-Path $RepoRoot "uv.lock")
    )
    $sb = [System.Text.StringBuilder]::new()
    foreach ($p in $watched) {
        if (Test-Path -LiteralPath $p -PathType Container) {
            Get-ChildItem -Recurse -File -LiteralPath $p -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -notmatch "\\node_modules\\" -and $_.FullName -notmatch "\\.venv\\" } |
                Sort-Object FullName |
                ForEach-Object { [void]$sb.Append("$($_.FullName):$($_.LastWriteTimeUtc.Ticks);") }
        } elseif (Test-Path -LiteralPath $p) {
            $f = Get-Item -LiteralPath $p
            [void]$sb.Append("$($f.FullName):$($f.LastWriteTimeUtc.Ticks);")
        }
    }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($sb.ToString())
    $hash  = [System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
    return ([System.BitConverter]::ToString($hash) -replace "-","").Substring(0,16)
}

function Test-ImageExists {
    $prevPref = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    docker image inspect $LocalImage *> $null
    $e = ($LASTEXITCODE -eq 0)
    $ErrorActionPreference = $prevPref
    return $e
}

# ── env file ───────────────────────────────────────────────────────────────────
function Ensure-EnvFile {
    if (-not (Test-Path -LiteralPath $EnvFile)) { Write-Err "Missing: $EnvFile"; exit 1 }
    $c = Get-Content -LiteralPath $EnvFile -Raw
    if ($c -match "PAPERLESS_SECRET_KEY=change-me") {
        $s = -join ((48..57)+(97..122) | Get-Random -Count 64 | ForEach-Object { [char]$_ })
        $c = $c -replace "PAPERLESS_SECRET_KEY=change-me","PAPERLESS_SECRET_KEY=$s"
        Set-Content -LiteralPath $EnvFile -Value $c -Encoding UTF8
        Write-Ok "Generated unique PAPERLESS_SECRET_KEY in docker-compose.env"
    }
}

# ── compose override (swaps published image for local build) ───────────────────
function Write-DevOverride {
    @"
services:
  webserver:
    image: $LocalImage
    environment:
      PAPERLESS_DEBUG: "true"
      PAPERLESS_ADMIN_USER: "admin"
      PAPERLESS_ADMIN_PASSWORD: "admin"
      PAPERLESS_ADMIN_MAIL: "admin@localhost"
"@ | Set-Content -LiteralPath $OverrideFile -Encoding UTF8
}

function Remove-DevOverride {
    if (Test-Path -LiteralPath $OverrideFile) {
        Remove-Item -LiteralPath $OverrideFile -Force -ErrorAction SilentlyContinue
    }
}

# ── compose runner ─────────────────────────────────────────────────────────────
function Invoke-Compose([string[]]$extraArgs, [switch]$AllowFailure) {
    $base = @("compose","--project-name",$ProjectName,"--file",$ComposeFile,"--env-file",$EnvFile)
    if (Test-Path -LiteralPath $OverrideFile) { $base += @("--file",$OverrideFile) }
    & docker ($base + $extraArgs)
    if ($LASTEXITCODE -ne 0 -and -not $AllowFailure) {
        throw "docker compose failed (exit $LASTEXITCODE)"
    }
}

# ── CRLF→LF normalisation (Windows Git CRLF poison prevention) ────────────────
function Repair-LineEndings {
    # docker/rootfs contains scripts that run inside the Linux container.
    # Windows Git with core.autocrlf=true injects \r into shebangs, causing
    #   env: 'python3\r': No such file or directory
    # This function converts all text files under docker/rootfs to LF before build.
    $dirs = @(
        (Join-Path $RepoRoot "docker\rootfs")
    )
    $textExts = @('.py','.sh','.bash','','.conf','.ini','.cfg','.txt','.env','.json','.yml','.yaml')
    $fixed = 0
    foreach ($dir in $dirs) {
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        Get-ChildItem -Recurse -File -LiteralPath $dir -ErrorAction SilentlyContinue | ForEach-Object {
            $ext = $_.Extension.ToLower()
            if ($ext -eq '' -or $textExts -contains $ext) {
                $bytes = [System.IO.File]::ReadAllBytes($_.FullName)
                $hasCRLF = $false
                for ($i = 0; $i -lt $bytes.Length - 1; $i++) {
                    if ($bytes[$i] -eq 0x0D -and $bytes[$i+1] -eq 0x0A) { $hasCRLF = $true; break }
                }
                if ($hasCRLF) {
                    $content = [System.IO.File]::ReadAllText($_.FullName)
                    [System.IO.File]::WriteAllText($_.FullName, ($content -replace "`r`n","`n"), [System.Text.UTF8Encoding]::new($false))
                    $fixed++
                }
            }
        }
    }
    if ($fixed -gt 0) {
        Write-Ok "Normalised line endings (CRLF→LF) in $fixed file(s) under docker/rootfs."
    }
}

# ── build ──────────────────────────────────────────────────────────────────────
function Build-Image([switch]$NoCache) {
    Write-Step "Building local Docker image '$LocalImage'..."
    Write-Host "  Compiles Angular frontend + installs all Python packages." -ForegroundColor DarkGray
    Write-Host "  First build: 5-15 min  |  Later builds: 1-3 min (cached layers)." -ForegroundColor DarkGray
    Write-Host ""

    # Fix Windows CRLF line endings in docker/rootfs before the build.
    Repair-LineEndings

    $args = @("build","--tag",$LocalImage)
    if ($NoCache) { $args += "--no-cache"; Write-Warn "No-cache: all layers re-downloaded." }
    $args += $RepoRoot

    & docker @args
    if ($LASTEXITCODE -ne 0) { throw "Docker image build failed. See output above." }

    Write-BuildState -hash (Get-SourceHash)
    Write-Ok "Image built: $LocalImage"
}

function Ensure-ImageUpToDate([switch]$ForceRebuild, [switch]$NoCache) {
    if ($NoBuild) { Write-Warn "Skipping build (-NoBuild)."; return }

    if ($ForceRebuild) { Build-Image -NoCache:$NoCache; return }

    if (-not (Test-ImageExists)) {
        Write-Step "No local image found — building for the first time."
        Build-Image; return
    }

    $state = Read-BuildState
    $hash  = Get-SourceHash
    if ($null -eq $state -or $state.sourceHash -ne $hash) {
        Write-Host ""
        Write-Warn "Source files have changed since last build."
        Write-Host "  Last build: $(if ($state) { $state.builtAt } else { 'never' })" -ForegroundColor DarkGray
        Write-Host ""
        $a = Read-Host "  Rebuild?  [Y] yes   [n] skip   [f] force no-cache rebuild"
        switch -Regex ($a.Trim().ToLower()) {
            "^f$"         { Build-Image -NoCache }
            "^n(o)?$"     { Write-Warn "Skipping rebuild — app may not reflect your changes." }
            default       { Build-Image }
        }
    } else {
        Write-Ok "Image is up to date with current source."
    }
}

# ── actions ────────────────────────────────────────────────────────────────────
function Start-Stack([switch]$ForceRebuild, [switch]$NoCache) {
    Ensure-EnvFile
    Ensure-ImageUpToDate -ForceRebuild:$ForceRebuild -NoCache:$NoCache
    Write-DevOverride
    try {
        Write-Step "Starting Docker Compose stack..."
        Invoke-Compose @("up","--detach","--remove-orphans")
    } finally {
        Remove-DevOverride
    }

    Write-Host ""
    Write-Host "  ┌──────────────────────────────────────────────────────┐" -ForegroundColor Green
    Write-Host "  │                                                      │" -ForegroundColor Green
    Write-Host "  │   App URL  :  http://localhost:8000                  │" -ForegroundColor Green
    Write-Host "  │   Username :  admin                                  │" -ForegroundColor Green
    Write-Host "  │   Password :  admin                                  │" -ForegroundColor Green
    Write-Host "  │                                                      │" -ForegroundColor Green
    Write-Host "  │   .\docker-dev.ps1 -Action logs   (live log tail)    │" -ForegroundColor Green
    Write-Host "  │   .\docker-dev.ps1 -Action open   (open browser)     │" -ForegroundColor Green
    Write-Host "  │                                                      │" -ForegroundColor Green
    Write-Host "  └──────────────────────────────────────────────────────┘" -ForegroundColor Green
    Write-Host ""
    Write-Host "  After making code changes:" -ForegroundColor DarkGray
    Write-Host "    Python / Angular change  →  .\docker-dev.ps1 -Action rebuild" -ForegroundColor DarkGray
    Write-Host "    Env config change only   →  .\docker-dev.ps1 -Action restart" -ForegroundColor DarkGray
    Write-Host ""
}

function Stop-Stack {
    Write-Step "Stopping stack (volumes preserved)..."
    $prevPref = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    & docker compose --project-name $ProjectName --file $ComposeFile --env-file $EnvFile down
    $ErrorActionPreference = $prevPref
    Write-Ok "Stack stopped."
}

function Reset-Stack {
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════════════════════╗" -ForegroundColor Red
    Write-Host "  ║  WARNING: This permanently deletes ALL Paperless data.   ║" -ForegroundColor Red
    Write-Host "  ║  Documents, thumbnails, tags, database — everything.     ║" -ForegroundColor Red
    Write-Host "  ╚══════════════════════════════════════════════════════════╝" -ForegroundColor Red
    Write-Host ""
    $a = Read-Host "  Type 'yes' to confirm complete data wipe"
    if ($a -ne "yes") { Write-Warn "Reset cancelled."; return }

    Write-Step "Removing containers and volumes..."
    $prevPref = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    & docker compose --project-name $ProjectName --file $ComposeFile --env-file $EnvFile down --volumes --remove-orphans
    $ErrorActionPreference = $prevPref
    Write-Ok "All volumes removed."
    Start-Stack -ForceRebuild
}

function Show-Status {
    Write-Step "Container status (project: $ProjectName):"
    $prevPref = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    & docker compose --project-name $ProjectName --file $ComposeFile --env-file $EnvFile ps
    $ErrorActionPreference = $prevPref
}

function Show-Logs {
    $a = @("compose","--project-name",$ProjectName,"--file",$ComposeFile,"--env-file",$EnvFile,"logs","--follow","--tail","200")
    if ($Service -ne "") { $a += $Service; Write-Step "Tailing '$Service' logs (Ctrl+C to stop)..." }
    else                 { Write-Step "Tailing all logs (Ctrl+C to stop)..." }
    & docker @a
}

function Open-Browser { Write-Step "Opening $AppUrl..."; Start-Process $AppUrl }

# ── entrypoint ─────────────────────────────────────────────────────────────────
Write-Banner
Ensure-Docker

switch ($Action) {
    "start"   { Start-Stack }
    "stop"    { Stop-Stack }
    "restart" { Stop-Stack; Start-Stack }
    "rebuild" { Start-Stack -ForceRebuild }
    "reset"   { Reset-Stack }
    "status"  { Show-Status }
    "logs"    { Show-Logs }
    "open"    { Open-Browser }
}
