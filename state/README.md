# state

This folder contains small local state files used by Plex Caretaker while it runs.

Typical contents:
- `plex-caretaker-state.json`
- future local state or checkpoint files

Use this folder to:
- see the last known health/restart state
- track cooldown-related behavior
- understand what the watchdog did most recently

These files are local runtime artifacts and should not normally be committed to git.
