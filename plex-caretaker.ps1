[CmdletBinding()]
param(
    # Path to the environment file. Keep machine-specific settings out of git by
    # storing them in .env and committing only .env.example.
    [string]$EnvFile = (Join-Path $PSScriptRoot '.env'),

    # Safe test mode: evaluate health and log what would happen, but do not
    # actually restart Plex.
    [switch]$WhatIfRestart
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Load-EnvFile {
    <#
        .SYNOPSIS
        Loads simple KEY=VALUE pairs from a .env-style file.

        .DESCRIPTION
        Windows PowerShell does not natively read dotenv files, so we do a very
        small amount of parsing here ourselves.

        Supported format:
            KEY=value
            KEY="quoted value"
            # comments are ignored

        We intentionally keep the parser small and predictable. This is enough
        for local automation settings without bringing in extra dependencies.
    #>
    param(
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    foreach ($line in Get-Content -LiteralPath $Path) {
        $trimmed = $line.Trim()

        if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }
        if ($trimmed.StartsWith('#')) { continue }

        if ($trimmed -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\s*$') {
            $name = $matches[1]
            $value = $matches[2].Trim()

            # Remove one matching layer of surrounding single or double quotes.
            if (
                ($value.StartsWith('"') -and $value.EndsWith('"')) -or
                ($value.StartsWith("'") -and $value.EndsWith("'"))
            ) {
                $value = $value.Substring(1, $value.Length - 2)
            }

            Set-Item -Path ("Env:{0}" -f $name) -Value $value
        }
    }
}

function Resolve-ConfigPath {
    <#
        .SYNOPSIS
        Resolves a config path relative to the script root unless already absolute.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$BasePath
    )

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }

    return (Join-Path $BasePath $Path)
}

function New-DefaultState {
    <#
        .SYNOPSIS
        Creates the initial on-disk state object.

        .DESCRIPTION
        We keep the state file tiny and human-readable. The main value is a
        restart cooldown so the watchdog does not flap Plex repeatedly.
    #>
    return [pscustomobject]@{
        LastHealthyAt       = $null
        LastNasHealthyAt    = $null
        LastRestartAt       = $null
        ConsecutiveFailures = 0
        LastAction          = 'none'
        LastReason          = $null
    }
}

function Load-State {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return (New-DefaultState)
    }

    try {
        return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json)
    }
    catch {
        # If the state file is corrupt, fail open instead of bricking the agent.
        return (New-DefaultState)
    }
}

function Save-State {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$State,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $directory = Split-Path -Path $Path -Parent
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $State | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Write-Log {
    <#
        .SYNOPSIS
        Writes a log line to both stdout and the rolling log file.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = '[{0}] [{1}] {2}' -f $timestamp, $Level, $Message

    Write-Host $line
    Add-Content -LiteralPath $script:LogFile -Value $line
}

function Get-DateSafeString {
    param([datetime]$Value)
    if ($null -eq $Value) { return $null }
    return $Value.ToString('o')
}

function Get-Config {
    <#
        .SYNOPSIS
        Reads runtime configuration from environment variables.

        .DESCRIPTION
        The minimal v1 watchdog needs only a few inputs:
          - Plex health URL
          - a NAS path to verify
          - either a Plex service name OR a Plex executable path/process name
          - a cooldown to prevent restart loops
    #>
    param(
        [string]$ScriptRoot
    )

    $logDir = Resolve-ConfigPath -Path ($env:LOG_DIR ?? 'logs') -BasePath $ScriptRoot
    $stateFile = Resolve-ConfigPath -Path ($env:STATE_FILE ?? 'state\\plex-caretaker-state.json') -BasePath $ScriptRoot

    return [pscustomobject]@{
        PlexUrl                 = if ($env:PLEX_URL) { $env:PLEX_URL } else { 'http://127.0.0.1:32400/identity' }
        PlexToken               = $env:PLEX_TOKEN
        PlexMediaPath           = $env:PLEX_MEDIA_PATH
        PlexServiceName         = $env:PLEX_SERVICE_NAME
        PlexProcessName         = if ($env:PLEX_PROCESS_NAME) { $env:PLEX_PROCESS_NAME } else { 'Plex Media Server' }
        PlexProcessPath         = $env:PLEX_PROCESS_PATH
        RestartCooldownMinutes  = [int](if ($env:RESTART_COOLDOWN_MINUTES) { $env:RESTART_COOLDOWN_MINUTES } else { 30 })
        PlexStartupDelaySeconds = [int](if ($env:PLEX_STARTUP_DELAY_SECONDS) { $env:PLEX_STARTUP_DELAY_SECONDS } else { 20 })
        RequestTimeoutSeconds   = [int](if ($env:REQUEST_TIMEOUT_SECONDS) { $env:REQUEST_TIMEOUT_SECONDS } else { 5 })
        LogDir                  = $logDir
        StateFile               = $stateFile
    }
}

function Test-PlexHealth {
    <#
        .SYNOPSIS
        Checks whether Plex is responding to its local HTTP endpoint.

        .DESCRIPTION
        /identity is intentionally light-weight and a good first signal that the
        local Plex web service stack is up.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Config
    )

    $headers = @{}
    if ($Config.PlexToken) {
        $headers['X-Plex-Token'] = $Config.PlexToken
    }

    try {
        $response = Invoke-WebRequest \
            -Uri $Config.PlexUrl \
            -Headers $headers \
            -Method Get \
            -TimeoutSec $Config.RequestTimeoutSeconds \
            -UseBasicParsing

        return [pscustomobject]@{
            Healthy = $true
            Detail  = 'HTTP {0}' -f [int]$response.StatusCode
        }
    }
    catch {
        return [pscustomobject]@{
            Healthy = $false
            Detail  = $_.Exception.Message
        }
    }
}

function Test-NasPath {
    <#
        .SYNOPSIS
        Verifies that Windows can actually reach a real media path.

        .DESCRIPTION
        This is the highest-value check in the whole script. If the NAS path is
        broken, restarting Plex often does not help. So we test the path first
        and only attempt a Plex restart when storage is healthy.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Config
    )

    if ([string]::IsNullOrWhiteSpace($Config.PlexMediaPath)) {
        return [pscustomobject]@{
            Reachable = $false
            Detail    = 'PLEX_MEDIA_PATH is not configured.'
        }
    }

    try {
        if (-not (Test-Path -LiteralPath $Config.PlexMediaPath)) {
            return [pscustomobject]@{
                Reachable = $false
                Detail    = 'Path does not exist or is not reachable.'
            }
        }

        # A lightweight directory read catches more cases than Test-Path alone,
        # especially around stale SMB sessions.
        Get-ChildItem -LiteralPath $Config.PlexMediaPath -ErrorAction Stop | Select-Object -First 1 | Out-Null

        return [pscustomobject]@{
            Reachable = $true
            Detail    = 'Media path is reachable.'
        }
    }
    catch {
        return [pscustomobject]@{
            Reachable = $false
            Detail    = $_.Exception.Message
        }
    }
}

function Get-CanRestart {
    <#
        .SYNOPSIS
        Enforces a simple cooldown so the script does not hammer Plex.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$State,

        [Parameter(Mandatory = $true)]
        [psobject]$Config
    )

    if (-not $State.LastRestartAt) {
        return $true
    }

    try {
        $lastRestart = [datetime]::Parse($State.LastRestartAt)
    }
    catch {
        return $true
    }

    $minutesSinceRestart = ((Get-Date) - $lastRestart).TotalMinutes
    return ($minutesSinceRestart -ge $Config.RestartCooldownMinutes)
}

function Restart-Plex {
    <#
        .SYNOPSIS
        Restarts Plex using either a Windows service or a standalone process.

        .DESCRIPTION
        Many Windows Plex installs are not true services; they run as a user app.
        So we support both models:
          1. If PLEX_SERVICE_NAME is configured and exists, restart that service.
          2. Otherwise, stop the named process and restart it via PLEX_PROCESS_PATH.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Config
    )

    if ($Config.PlexServiceName) {
        $service = Get-Service -Name $Config.PlexServiceName -ErrorAction SilentlyContinue
        if ($service) {
            Restart-Service -Name $Config.PlexServiceName -Force -ErrorAction Stop
            Start-Sleep -Seconds $Config.PlexStartupDelaySeconds
            return 'Restarted service ''{0}''.' -f $Config.PlexServiceName
        }
    }

    $processes = @(Get-Process -Name $Config.PlexProcessName -ErrorAction SilentlyContinue)
    if ($processes.Count -gt 0) {
        $processes | Stop-Process -Force -ErrorAction Stop
        Start-Sleep -Seconds 3
    }

    if ([string]::IsNullOrWhiteSpace($Config.PlexProcessPath)) {
        throw 'PLEX_PROCESS_PATH is required when Plex is not managed as a Windows service.'
    }

    if (-not (Test-Path -LiteralPath $Config.PlexProcessPath)) {
        throw ('PLEX_PROCESS_PATH was not found: {0}' -f $Config.PlexProcessPath)
    }

    Start-Process -FilePath $Config.PlexProcessPath | Out-Null
    Start-Sleep -Seconds $Config.PlexStartupDelaySeconds
    return 'Restarted Plex process from ''{0}''.' -f $Config.PlexProcessPath
}

Load-EnvFile -Path $EnvFile
$config = Get-Config -ScriptRoot $PSScriptRoot

if (-not (Test-Path -LiteralPath $config.LogDir)) {
    New-Item -ItemType Directory -Path $config.LogDir -Force | Out-Null
}

$script:LogFile = Join-Path $config.LogDir 'plex-caretaker.log'
$state = Load-State -Path $config.StateFile

Write-Log -Level INFO -Message ('Starting Plex caretaker check. PlexUrl={0}; MediaPath={1}' -f $config.PlexUrl, $config.PlexMediaPath)

$nasResult = Test-NasPath -Config $config
$plexResult = Test-PlexHealth -Config $config

if ($nasResult.Reachable) {
    $state.LastNasHealthyAt = Get-DateSafeString -Value (Get-Date)
}

if ($nasResult.Reachable -and $plexResult.Healthy) {
    $state.LastHealthyAt = Get-DateSafeString -Value (Get-Date)
    $state.ConsecutiveFailures = 0
    $state.LastAction = 'healthy'
    $state.LastReason = 'Plex and NAS both healthy.'

    Write-Log -Level INFO -Message 'Plex and NAS are both healthy. No action needed.'
    Save-State -State $state -Path $config.StateFile
    exit 0
}

$state.ConsecutiveFailures = [int]$state.ConsecutiveFailures + 1

if (-not $nasResult.Reachable) {
    $state.LastAction = 'skipped_restart'
    $state.LastReason = 'NAS path unavailable; skipping Plex restart.'

    Write-Log -Level WARN -Message ('NAS path is unavailable: {0}' -f $nasResult.Detail)
    Write-Log -Level WARN -Message ('Plex health was: {0}' -f $plexResult.Detail)
    Write-Log -Level WARN -Message 'Skipping Plex restart because storage is the more likely root cause.'

    Save-State -State $state -Path $config.StateFile
    exit 1
}

# If we reached this branch, the NAS path is healthy but Plex is not.
Write-Log -Level WARN -Message ('NAS is healthy but Plex failed health check: {0}' -f $plexResult.Detail)

if (-not (Get-CanRestart -State $state -Config $config)) {
    $state.LastAction = 'cooldown_blocked'
    $state.LastReason = 'Restart blocked by cooldown.'

    Write-Log -Level WARN -Message ('Restart blocked because the last restart is within the {0}-minute cooldown window.' -f $config.RestartCooldownMinutes)
    Save-State -State $state -Path $config.StateFile
    exit 1
}

try {
    if ($WhatIfRestart) {
        $actionDetail = 'WhatIfRestart enabled; restart skipped.'
        Write-Log -Level WARN -Message $actionDetail
    }
    else {
        $actionDetail = Restart-Plex -Config $config
        Write-Log -Level WARN -Message $actionDetail
        $state.LastRestartAt = Get-DateSafeString -Value (Get-Date)
    }

    $postRestartHealth = Test-PlexHealth -Config $config
    if ($postRestartHealth.Healthy) {
        $state.LastHealthyAt = Get-DateSafeString -Value (Get-Date)
        $state.ConsecutiveFailures = 0
        $state.LastAction = 'restart_success'
        $state.LastReason = 'Plex recovered after restart.'

        Write-Log -Level INFO -Message ('Plex is healthy after restart check: {0}' -f $postRestartHealth.Detail)
        Save-State -State $state -Path $config.StateFile
        exit 0
    }

    $state.LastAction = 'restart_failed'
    $state.LastReason = 'Plex still unhealthy after restart.'

    Write-Log -Level ERROR -Message ('Plex is still unhealthy after restart: {0}' -f $postRestartHealth.Detail)
    Save-State -State $state -Path $config.StateFile
    exit 2
}
catch {
    $state.LastAction = 'restart_error'
    $state.LastReason = $_.Exception.Message

    Write-Log -Level ERROR -Message ('Restart attempt failed: {0}' -f $_.Exception.Message)
    Save-State -State $state -Path $config.StateFile
    exit 2
}
