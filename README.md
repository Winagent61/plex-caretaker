# Plex Caretaker

A small Windows-first watchdog for a Plex server whose media lives on a NAS.

> This is the MVP version of Plex Caretaker.
>
> This MVP is a prototype.

The goal of v1 is intentionally narrow:

1. Check whether the NAS media path is reachable.
2. Check whether Plex responds on its local HTTP endpoint.
3. Restart Plex **only when the NAS is healthy but Plex is not**.
4. Write a log and a tiny state file so the behavior is understandable.

This is meant to reduce the boring "Plex got confused again, go reboot it" maintenance loop without jumping straight to a giant automation system.

---

## Why this exists

When Plex runs on Windows but reads media from a NAS over SMB, failures can come from different places:

- Plex itself is hung or unhealthy.
- The NAS share is unreachable.
- Windows lost or stale SMB access to the NAS path.
- Plex is fine, but storage is not.

Blindly rebooting the whole machine treats all of those as the same problem. This watchdog does not. Its first job is to distinguish **"Plex is broken"** from **"the storage path is broken"**.

---

## Design principles

- **Local execution on the Plex host**: the repair logic should run on the same Windows machine as Plex.
- **GitHub for code, local machine for execution**: keep the repo in git, but run the script from the Plex host.
- **UNC paths, not mapped drives**: use paths like `\\TatooineNAS\\Movies`, not `Z:\\Movies`.
- **Minimal first version**: solve the highest-value failure mode before adding dashboards, alerts, or host reboots.
- **Safe restart behavior**: use a cooldown so the script does not flap Plex repeatedly.

---

## Repo structure

```text
plex-caretaker/
├── .env.example              # Machine-specific config template; copy to .env locally
├── .gitignore                # Ignore secrets, logs, and local state
├── install.ps1               # Local setup helper and optional Task Scheduler registration
├── plex-caretaker.ps1        # Main watchdog script
├── logs/
│   └── .gitkeep              # Keeps the folder in git; real logs stay untracked
└── state/
    └── .gitkeep              # Keeps the folder in git; runtime state stays untracked
```

---

## How the watchdog decides what to do

### Healthy case
If both of these are true:
- the NAS media path is reachable
- Plex responds at its local endpoint

then the script logs success and exits.

### NAS problem case
If the NAS path is **not** reachable:
- the script logs that storage is the more likely root cause
- the script **does not restart Plex**
- the script exits and waits for the next scheduled run

This matters because restarting Plex while storage is down usually adds churn instead of fixing anything.

### Plex-only problem case
If the NAS path **is** reachable, but Plex is not:
- the script checks a restart cooldown
- if allowed, it restarts Plex
- it waits briefly
- it checks Plex again
- it logs success or failure

---

## Supported Plex deployment styles on Windows

There are two common ways Plex shows up on Windows:

### 1. Plex managed like a service
If you have a real Windows service for Plex, set:
- `PLEX_SERVICE_NAME`

The script will restart that service.

### 2. Plex running as a user process / tray app
If Plex is not a service, set:
- `PLEX_PROCESS_NAME`
- `PLEX_PROCESS_PATH`

The script will stop the process and launch the executable again.

> Important: if Plex runs as a user app rather than a service, schedule the task under the same Windows user context that normally runs Plex.

---

## Configuration

Copy `.env.example` to `.env` on the Plex host and edit the values.

### Key settings

| Variable | Required | Purpose |
|---|---:|---|
| `PLEX_MEDIA_PATH` | Yes | Real library path on the NAS, ideally a UNC path |
| `PLEX_URL` | No | Plex health endpoint; default is `http://127.0.0.1:32400/identity` |
| `PLEX_SERVICE_NAME` | Maybe | Use this if Plex is managed as a Windows service |
| `PLEX_PROCESS_NAME` | Maybe | Process name if Plex is not a service |
| `PLEX_PROCESS_PATH` | Maybe | Full path to the Plex executable when process restart is needed |
| `RESTART_COOLDOWN_MINUTES` | No | Prevents repeated restarts too close together |
| `PLEX_STARTUP_DELAY_SECONDS` | No | Wait time after a restart before re-checking health |
| `REQUEST_TIMEOUT_SECONDS` | No | HTTP timeout for the Plex health check |
| `LOG_DIR` | No | Folder for text logs |
| `STATE_FILE` | No | JSON state file path |

### Notes
- You generally need **either** `PLEX_SERVICE_NAME` **or** `PLEX_PROCESS_PATH`.
- `PLEX_TOKEN` is optional in v1. It is included now so the repo can grow into richer Plex API checks later.

---

## Recommended installation approach

### 1. Clone the repo onto the Plex host
Recommended path example:

```powershell
git clone <your-repo-url> C:\ProgramData\PlexCaretaker\app
cd C:\ProgramData\PlexCaretaker\app
```

### 2. Prepare local config

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\install.ps1
notepad .env
```

### 3. Do a dry run first

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\plex-caretaker.ps1 -WhatIfRestart
```

This will:
- load config
- test NAS reachability
- test Plex health
- log what it would do
- **not** actually restart Plex

### 4. Register the scheduled task

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\install.ps1 -RegisterScheduledTask -IntervalMinutes 15
```

---

## Logging and local state

### Log file
The script writes plain text log lines to:

- `logs\plex-caretaker.log`

### State file
The script keeps a tiny JSON state file at:

- `state\plex-caretaker-state.json`

That state currently tracks:
- last healthy time
- last NAS healthy time
- last restart time
- consecutive failure count
- last action
- last reason

This is intentionally simple. The file is meant to help you reason about what the watchdog actually did.

---

## Operational advice

### Use UNC paths
Prefer:

```text
\\TatooineNAS\\Movies
```

Avoid:

```text
Z:\Movies
```

Mapped drives are much less reliable for unattended background processes and scheduled tasks.

### Give the NAS and Plex host stable IPs
This helps remove avoidable name/address drift.

### Keep secrets out of git
Do not commit `.env`, tokens, credentials, logs, or state files.

### Start simple
Do **not** add host auto-reboots in v1. Get stable signal and sane Plex restarts first.

---

## Suggested v1 operating cadence

- Run every **10 to 15 minutes**.
- Review logs after the first few incidents.
- Tune cooldown and startup delay based on how long Plex actually takes to recover.

---

## What this repo does not do yet

By design, v1 does **not** yet include:

- Windows host reboots
- notification delivery
- Plex log parsing
- NAS SMB session repair steps
- library refresh triggers
- GitHub self-update logic
- dashboards or web UI

Those can come later once the basic health distinction is working reliably.

---

## Suggested next steps after v1 is stable

1. Add notifications only when an action was taken.
2. Add repeated-failure escalation.
3. Add optional SMB repair logic before restarting Plex.
4. Add off-hours host reboot as a last resort.
5. Add richer Plex API checks if needed.

---

## Example `.env` snippet

```dotenv
PLEX_URL=http://127.0.0.1:32400/identity
PLEX_MEDIA_PATH=\\TatooineNAS\\Movies
PLEX_PROCESS_NAME=Plex Media Server
PLEX_PROCESS_PATH=C:\Program Files\Plex\Plex Media Server\Plex Media Server.exe
RESTART_COOLDOWN_MINUTES=30
PLEX_STARTUP_DELAY_SECONDS=20
REQUEST_TIMEOUT_SECONDS=5
```

---

## GitHub workflow recommendation

Use GitHub as the **source of truth** for the code, but run the watchdog locally on the Plex host.

Recommended maintenance pattern:

1. Make changes in the repo.
2. Push to GitHub.
3. On the Plex host, run:

```powershell
git pull
```

That gives you a simple update path with version control and rollback, without depending on another machine to fix Plex.
