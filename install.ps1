[CmdletBinding(SupportsShouldProcess = $true)]
param(
    # Name of the Windows scheduled task to create.
    [string]$TaskName = 'PlexCaretaker',

    # How often to run the health check.
    [int]$IntervalMinutes = 15,

    # When supplied, create/update the Task Scheduler entry automatically.
    [switch]$RegisterScheduledTask
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$logsDir = Join-Path $repoRoot 'logs'
$stateDir = Join-Path $repoRoot 'state'
$envExample = Join-Path $repoRoot '.env.example'
$envFile = Join-Path $repoRoot '.env'
$scriptPath = Join-Path $repoRoot 'plex-caretaker.ps1'

Write-Host 'Preparing Plex caretaker repository for local use...'

foreach ($dir in @($logsDir, $stateDir)) {
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Write-Host "Created $dir"
    }
}

if (-not (Test-Path -LiteralPath $envFile)) {
    Copy-Item -LiteralPath $envExample -Destination $envFile
    Write-Host 'Created .env from .env.example. Edit it before enabling unattended restarts.'
}
else {
    Write-Host '.env already exists; leaving it untouched.'
}

if (-not $RegisterScheduledTask) {
    Write-Host ''
    Write-Host 'Install prep complete.'
    Write-Host 'Next steps:'
    Write-Host '  1. Edit .env'
    Write-Host '  2. Test manually:'
    Write-Host ('     powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}" -WhatIfRestart' -f $scriptPath)
    Write-Host '  3. Re-run install.ps1 with -RegisterScheduledTask to add the scheduled task.'
    exit 0
}

# We use schtasks.exe here because it is present on all normal Windows installs
# and avoids some of the version-specific awkwardness of the ScheduledTasks
# PowerShell module when configuring repetition intervals.
$taskCommand = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $scriptPath
$arguments = @(
    '/Create',
    '/SC', 'MINUTE',
    '/MO', $IntervalMinutes,
    '/TN', $TaskName,
    '/TR', $taskCommand,
    '/RL', 'HIGHEST',
    '/F'
)

Write-Host ('Registering scheduled task "{0}" to run every {1} minutes...' -f $TaskName, $IntervalMinutes)
& schtasks.exe @arguments | Out-Host
Write-Host 'Done.'
