param(
    [ValidateSet("start", "stop", "status", "toggle", "restart", "doctor")]
    [string]$Action = "toggle",

    [switch]$Lite,

    # Skip trying to install missing tools (Python/Node/uv/pnpm).
    [switch]$SkipBootstrapTools,

    # Skip syncing repo dependencies (uv sync / pnpm install).
    [switch]$SkipDependencySync
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RepoRoot = $PSScriptRoot
$StateDir = Join-Path $RepoRoot ".paperless-dev"
$PidFile = Join-Path $StateDir "processes.json"

$script:UvCommandText = "uv"
$script:PnpmCommandText = "pnpm"
$script:PythonLauncher = $null
$script:NodeAvailable = $false

function Ensure-StateDir {
    if (-not (Test-Path -LiteralPath $StateDir)) {
        New-Item -ItemType Directory -Path $StateDir | Out-Null
    }
}

function Escape-SingleQuotes([string]$value) {
    return $value -replace "'", "''"
}

function Test-CommandAvailable([string]$name) {
    return $null -ne (Get-Command $name -ErrorAction SilentlyContinue)
}

function Refresh-ProcessPath {
    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $processPath = [Environment]::GetEnvironmentVariable("Path", "Process")
    $env:Path = ($machinePath, $userPath, $processPath -join ";")

    # Add all known Python user-scripts directories (handles Python312, Python313, etc.).
    $pythonBase = Join-Path $env:APPDATA "Python"
    if (Test-Path -LiteralPath $pythonBase) {
        Get-ChildItem -LiteralPath $pythonBase -Directory -ErrorAction SilentlyContinue |
            ForEach-Object {
                $scripts = Join-Path $_.FullName "Scripts"
                if ((Test-Path -LiteralPath $scripts) -and ($env:Path -notlike "*$scripts*")) {
                    $env:Path = "$scripts;$env:Path"
                }
            }
        # Also the bare Scripts folder.
        $bare = Join-Path $pythonBase "Scripts"
        if ((Test-Path -LiteralPath $bare) -and ($env:Path -notlike "*$bare*")) {
            $env:Path = "$bare;$env:Path"
        }
    }
}

function Install-WithWinget([string]$id, [string]$label) {
    if (-not (Test-CommandAvailable "winget")) {
        throw "Missing required tool '$label' and winget is not available for auto-install. Install it manually and retry."
    }

    Write-Host "Installing $label using winget..." -ForegroundColor Cyan
    & winget install --id $id --exact --accept-source-agreements --accept-package-agreements --silent
    if ($LASTEXITCODE -ne 0) {
        throw "winget failed to install '$label' (package id: $id)."
    }

    Refresh-ProcessPath
}

function Resolve-PythonLauncher {
    if (Test-CommandAvailable "py") {
        return "py"
    }
    if (Test-CommandAvailable "python") {
        return "python"
    }
    return $null
}

function Ensure-Python {
    $launcher = Resolve-PythonLauncher
    if ($null -ne $launcher) {
        $script:PythonLauncher = $launcher
        return
    }

    if ($SkipBootstrapTools) {
        throw "Python is required but not installed (or not on PATH)."
    }

    Install-WithWinget -id "Python.Python.3.12" -label "Python"
    $launcher = Resolve-PythonLauncher
    if ($null -eq $launcher) {
        throw "Python install completed, but 'py'/'python' is still not available on PATH. Open a new shell and retry."
    }

    $script:PythonLauncher = $launcher
}

function Ensure-Node {
    if (Test-CommandAvailable "node") {
        $script:NodeAvailable = $true
        return
    }

    if ($SkipBootstrapTools) {
        throw "Node.js is required but not installed (or not on PATH)."
    }

    Install-WithWinget -id "OpenJS.NodeJS.LTS" -label "Node.js LTS"
    if (-not (Test-CommandAvailable "node")) {
        throw "Node.js install completed, but 'node' is still not available on PATH. Open a new shell and retry."
    }

    $script:NodeAvailable = $true
}

function Test-PythonModule([string]$module) {
    # Probe without raising a terminating error regardless of $ErrorActionPreference.
    try {
        $output = & $script:PythonLauncher -m $module --version 2>&1
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}

function Ensure-UvCommand {
    if (Test-CommandAvailable "uv") {
        $script:UvCommandText = "uv"
        return
    }

    Ensure-Python

    # Check if uv is importable as a Python module (silent probe).
    if (Test-PythonModule "uv") {
        $script:UvCommandText = "$($script:PythonLauncher) -m uv"
        return
    }

    if ($SkipBootstrapTools) {
        throw "uv is required but not installed. Install it from https://docs.astral.sh/uv/getting-started/installation/ or run without -SkipBootstrapTools."
    }

    Write-Host "uv not found. Installing via pip..." -ForegroundColor Cyan
    $prevPref = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & $script:PythonLauncher -m pip install --user --upgrade pip uv
    $pipExit = $LASTEXITCODE
    $ErrorActionPreference = $prevPref

    if ($pipExit -ne 0) {
        throw "Failed to install uv using pip (exit code $pipExit). Install uv manually: https://docs.astral.sh/uv/getting-started/installation/"
    }

    Refresh-ProcessPath

    if (Test-CommandAvailable "uv") {
        $script:UvCommandText = "uv"
        return
    }

    if (Test-PythonModule "uv") {
        $script:UvCommandText = "$($script:PythonLauncher) -m uv"
        return
    }

    throw "uv install completed, but it is still not usable. Try reopening your terminal, or install manually: https://docs.astral.sh/uv/getting-started/installation/"
}

function Find-NodeBinDir {
    # Try to locate Node's bin directory from the 'node' executable itself.
    $nodeExe = Get-Command "node" -ErrorAction SilentlyContinue
    if ($null -ne $nodeExe) {
        return Split-Path -Parent $nodeExe.Path
    }

    # Common Windows install locations as fallback.
    $candidates = @(
        "$env:ProgramFiles\nodejs",
        "${env:ProgramFiles(x86)}\nodejs",
        "$env:APPDATA\nvm\current",
        "$env:LOCALAPPDATA\Programs\nodejs"
    )
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath (Join-Path $c "node.exe")) {
            return $c
        }
    }

    return $null
}

function Ensure-PnpmCommand {
    if (Test-CommandAvailable "pnpm") {
        $script:PnpmCommandText = "pnpm"
        return
    }

    Ensure-Node

    # corepack ships with Node.js but may not be on PATH yet.
    # Try to add the Node bin dir so corepack is reachable.
    $nodeBin = Find-NodeBinDir
    if ($null -ne $nodeBin -and $env:Path -notlike "*$nodeBin*") {
        $env:Path = "$nodeBin;$env:Path"
    }

    # Try npm as a direct install path if corepack is still missing.
    if (-not (Test-CommandAvailable "corepack")) {
        if ($SkipBootstrapTools) {
            throw "pnpm is missing and corepack is unavailable. Install pnpm manually: https://pnpm.io/installation"
        }

        if (Test-CommandAvailable "npm") {
            Write-Host "Installing pnpm globally via npm..." -ForegroundColor Cyan
            $prevPref = $ErrorActionPreference
            $ErrorActionPreference = "Continue"
            & npm install -g pnpm
            $npmExit = $LASTEXITCODE
            $ErrorActionPreference = $prevPref

            Refresh-ProcessPath
            if ($null -ne $nodeBin -and $env:Path -notlike "*$nodeBin*") {
                $env:Path = "$nodeBin;$env:Path"
            }

            if (Test-CommandAvailable "pnpm") {
                $script:PnpmCommandText = "pnpm"
                return
            }

            if ($npmExit -ne 0) {
                throw "npm install -g pnpm failed (exit code $npmExit). Install pnpm manually: https://pnpm.io/installation"
            }
        } else {
            throw "pnpm, corepack, and npm are all unavailable. Install pnpm manually: https://pnpm.io/installation"
        }
    }

    if (-not $SkipBootstrapTools -and (Test-CommandAvailable "corepack")) {
        Write-Host "Preparing pnpm using corepack..." -ForegroundColor Cyan
        $prevPref = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        & corepack enable
        $ErrorActionPreference = $prevPref

        $packageJsonPath = Join-Path $RepoRoot "src-ui\package.json"
        $pnpmSpec = "pnpm@latest"
        if (Test-Path -LiteralPath $packageJsonPath) {
            $pkg = Get-Content -LiteralPath $packageJsonPath -Raw | ConvertFrom-Json
            if ($pkg.packageManager -and ($pkg.packageManager -like "pnpm@*")) {
                $pnpmSpec = [string]$pkg.packageManager
            }
        }

        $prevPref = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        & corepack prepare $pnpmSpec --activate
        $ErrorActionPreference = $prevPref

        Refresh-ProcessPath
    }

    if (Test-CommandAvailable "pnpm") {
        $script:PnpmCommandText = "pnpm"
        return
    }

    try {
        & corepack pnpm --version 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            $script:PnpmCommandText = "corepack pnpm"
            return
        }
    } catch {
        # Ignore probe failure; fall through to throw.
    }

    throw "pnpm is not available after setup. Install it manually: https://pnpm.io/installation"
}

function Invoke-Uv([string[]]$cmdArgs, [string]$workingDir) {
    Push-Location -LiteralPath $workingDir
    try {
        if ($script:UvCommandText -eq "uv") {
            & uv @cmdArgs
        } else {
            & $script:PythonLauncher -m uv @cmdArgs
        }
        if ($LASTEXITCODE -ne 0) {
            throw "uv command failed in '$workingDir': $($script:UvCommandText) $($cmdArgs -join ' ')"
        }
    } finally {
        Pop-Location
    }
}

function Invoke-Pnpm([string[]]$cmdArgs, [string]$workingDir) {
    Push-Location -LiteralPath $workingDir
    try {
        if ($script:PnpmCommandText -eq "pnpm") {
            & pnpm @cmdArgs
        } else {
            & corepack pnpm @cmdArgs
        }
        if ($LASTEXITCODE -ne 0) {
            throw "pnpm command failed in '$workingDir': $($script:PnpmCommandText) $($cmdArgs -join ' ')"
        }
    } finally {
        Pop-Location
    }
}

function Ensure-RepoDependencies {
    if ($SkipDependencySync) {
        Write-Host "Skipping dependency sync due to -SkipDependencySync." -ForegroundColor DarkYellow
        return
    }

    $srcUi = Join-Path $RepoRoot "src-ui"

    Write-Host "Syncing Python dependencies (uv sync --group dev)..." -ForegroundColor Cyan
    # NOTE: pyproject.toml locks environments to darwin/linux only.
    # On Windows, uv sync will fail with a lockfile platform error.
    # The backend services require WSL2 or Docker on Windows.
    $prevPref = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        Invoke-Uv -cmdArgs @("sync", "--group", "dev") -workingDir $RepoRoot
    } catch {
        Write-Host "" -ForegroundColor Yellow
        Write-Host "  WARNING: Python dependency sync failed." -ForegroundColor Yellow
        Write-Host "  This project's lockfile targets Linux/macOS only (see pyproject.toml [tool.uv] environments)." -ForegroundColor Yellow
        Write-Host "  Backend services (backend, consumer, celery) require WSL2 or Docker on Windows." -ForegroundColor Yellow
        Write-Host "  The frontend will still start. For backend dev use -Lite and run the backend in WSL2 / Docker." -ForegroundColor Yellow
        Write-Host "" -ForegroundColor Yellow
    } finally {
        $ErrorActionPreference = $prevPref
    }

    Write-Host "Installing frontend dependencies (pnpm install)..." -ForegroundColor Cyan
    Invoke-Pnpm -cmdArgs @("install") -workingDir $srcUi
}

function Run-Preflight {
    # Validate expected repo structure early.
    foreach ($requiredPath in @("src", "src-ui", "src\manage.py", "src-ui\package.json")) {
        $full = Join-Path $RepoRoot $requiredPath
        if (-not (Test-Path -LiteralPath $full)) {
            throw "Expected path is missing: $full"
        }
    }

    Refresh-ProcessPath
    Ensure-Python
    Ensure-Node
    Ensure-UvCommand
    Ensure-PnpmCommand
    Ensure-RepoDependencies

    Write-Host "Preflight completed: tools and dependencies are ready." -ForegroundColor Green
    Write-Host ("Using uv command: {0}" -f $script:UvCommandText) -ForegroundColor DarkGray
    Write-Host ("Using pnpm command: {0}" -f $script:PnpmCommandText) -ForegroundColor DarkGray
}

function Get-Targets {
    $src = Join-Path $RepoRoot "src"
    $srcUi = Join-Path $RepoRoot "src-ui"

    $frontendCommand = "$($script:PnpmCommandText) ng serve"

    $fullTargets = @(
        [pscustomobject]@{ Name = "backend"; Cwd = $src; Command = "$($script:UvCommandText) run manage.py runserver" },
        [pscustomobject]@{ Name = "consumer"; Cwd = $src; Command = "$($script:UvCommandText) run manage.py document_consumer" },
        [pscustomobject]@{ Name = "celery"; Cwd = $src; Command = "$($script:UvCommandText) run celery --app paperless worker -l DEBUG" },
        [pscustomobject]@{ Name = "frontend"; Cwd = $srcUi; Command = $frontendCommand }
    )

    if ($Lite) {
        return @(
            [pscustomobject]@{ Name = "backend"; Cwd = $src; Command = "$($script:UvCommandText) run manage.py runserver" },
            [pscustomobject]@{ Name = "frontend"; Cwd = $srcUi; Command = $frontendCommand }
        )
    }

    return $fullTargets
}

function Read-ProcessState {
    if (-not (Test-Path -LiteralPath $PidFile)) {
        return @()
    }

    $raw = Get-Content -LiteralPath $PidFile -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return @()
    }

    $data = $raw | ConvertFrom-Json

    if ($data -is [System.Array]) {
        return @($data)
    }

    return @($data)
}

function Write-ProcessState([object[]]$entries) {
    Ensure-StateDir
    $entries | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $PidFile -Encoding UTF8
}

function Get-RunningEntries([object[]]$entries) {
    $running = @()

    foreach ($entry in $entries) {
        try {
            $proc = Get-Process -Id ([int]$entry.pid) -ErrorAction Stop
            $running += [pscustomobject]@{
                name = $entry.name
                pid = $entry.pid
                started = $entry.started
                cwd = $entry.cwd
                command = $entry.command
                processName = $proc.ProcessName
            }
        } catch {
            # Process no longer exists.
        }
    }

    return $running
}

function Show-Status {
    $saved = @(Read-ProcessState)
    $running = @(Get-RunningEntries -entries $saved)

    if ($running.Count -eq 0) {
        Write-Host "No managed Paperless dev processes are currently running." -ForegroundColor Yellow
        return
    }

    Write-Host "Managed Paperless dev processes:" -ForegroundColor Green
    $running |
        Select-Object name, pid, processName, started, cwd |
        Format-Table -AutoSize
}

function Start-Dev {
    $saved = @(Read-ProcessState)
    $running = @(Get-RunningEntries -entries $saved)

    if ($running.Count -gt 0) {
        Write-Host "Some managed processes are already running. Stop or toggle first." -ForegroundColor Yellow
        Show-Status
        return
    }

    Run-Preflight

    $targets = Get-Targets
    $startedEntries = @()

    foreach ($target in $targets) {
        $cwdEsc = Escape-SingleQuotes $target.Cwd
        $cmd = "Set-Location -LiteralPath '$cwdEsc'; $($target.Command)"

        $proc = Start-Process -FilePath "powershell.exe" -ArgumentList @(
            "-NoExit",
            "-Command",
            $cmd
        ) -PassThru

        $entry = [pscustomobject]@{
            name = $target.Name
            pid = $proc.Id
            started = (Get-Date).ToString("s")
            cwd = $target.Cwd
            command = $target.Command
        }

        $startedEntries += $entry
        Write-Host ("Started {0} (PID {1})" -f $target.Name, $proc.Id) -ForegroundColor Cyan
    }

    Write-ProcessState -entries $startedEntries
    Write-Host "All selected dev services started." -ForegroundColor Green
}

function Stop-Dev {
    $saved = @(Read-ProcessState)

    if ($saved.Count -eq 0) {
        Write-Host "No saved managed processes found." -ForegroundColor Yellow
        return
    }

    $anyStopped = $false

    foreach ($entry in $saved) {
        try {
            Stop-Process -Id ([int]$entry.pid) -Force -ErrorAction Stop
            Write-Host ("Stopped {0} (PID {1})" -f $entry.name, $entry.pid) -ForegroundColor Cyan
            $anyStopped = $true
        } catch {
            Write-Host ("Process already stopped or missing: {0} (PID {1})" -f $entry.name, $entry.pid) -ForegroundColor DarkYellow
        }
    }

    if (Test-Path -LiteralPath $PidFile) {
        Remove-Item -LiteralPath $PidFile -Force
    }

    if ($anyStopped) {
        Write-Host "Managed dev services stopped." -ForegroundColor Green
    }
}

function Toggle-Dev {
    $saved = @(Read-ProcessState)
    $running = @(Get-RunningEntries -entries $saved)

    if ($running.Count -gt 0) {
        Stop-Dev
    } else {
        Start-Dev
    }
}

switch ($Action) {
    "start" { Start-Dev }
    "stop" { Stop-Dev }
    "status" { Show-Status }
    "toggle" { Toggle-Dev }
    "restart" { Stop-Dev; Start-Dev }
    "doctor" { Run-Preflight }
}

