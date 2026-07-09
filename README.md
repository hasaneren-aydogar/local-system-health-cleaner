# Local System Health Check & Auto-Cleaner

A PowerShell script that checks the health of a Windows machine (disk space, RAM usage), safely removes accumulated junk files from the `Temp` and `Prefetch` directories, and generates a clean, dark-mode HTML report summarizing what changed.

No third-party modules, no external dependencies — just native Windows CIM/WMI queries and the filesystem.

## Why this exists

Most "PC cleaner" scripts either delete things too aggressively or give you zero visibility into what actually happened. This script takes a measure-before / measure-after approach: it records the exact disk and memory state before touching anything, performs the cleanup with per-file error handling (so a locked file never crashes the run), and then reports the real, measured difference — not an estimate.

## Features

- **Disk check** — total, used, and free space on the `C:` drive, plus usage percentage.
- **Memory check** — total and free physical RAM.
- **Safe Temp cleanup** — clears both the current user's `%TEMP%` folder and the system-wide `C:\Windows\Temp`, skipping any file still in use instead of failing.
- **Prefetch cleanup** — clears `C:\Windows\Prefetch` when the script is run with Administrator privileges (this step is automatically skipped otherwise, and the report reflects that).
- **Age-based targeting** — only files older than a configurable threshold (default: 1 day) are removed, so anything actively being written to is left alone.
- **Dark-mode HTML report** — saved to the Desktop and opened automatically, showing before/after disk and RAM state, total space freed, and a breakdown of deleted vs. skipped files per location.
- **Fully commented source** — every function explains not just *what* it does but *why*, in Turkish, aimed at someone learning PowerShell and Windows internals.

## Requirements

- Windows 10 or Windows 11
- PowerShell 5.1 or later (built into Windows; PowerShell 7+ also works)
- Administrator privileges — only required for the Prefetch cleanup step. Everything else runs fine as a standard user.

## Usage

Clone or download the repository, then run:

```powershell
.\SystemHealthCheck.ps1
```

If your execution policy blocks local scripts, run this once in an elevated PowerShell session:

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

To also clean the Prefetch folder, run PowerShell **as Administrator** before executing the script.

### Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-MinimumFileAgeDays` | int | `1` | Only files last modified before this many days ago are eligible for deletion. |
| `-NoAutoOpen` | switch | off | Prevents the HTML report from opening automatically after generation. |

Example:

```powershell
.\SystemHealthCheck.ps1 -MinimumFileAgeDays 3 -NoAutoOpen
```

## How it works

1. **Baseline measurement** — `Get-DiskStatus` and `Get-MemoryStatus` query `Win32_LogicalDisk` and `Win32_OperatingSystem` via CIM to capture the starting state.
2. **Temp cleanup** — `Remove-JunkFiles` recursively walks `%TEMP%` and `C:\Windows\Temp`, deleting files older than the age threshold. Each deletion is wrapped in its own `try/catch`; locked or permission-denied files are counted as *skipped* rather than stopping the script. Empty subfolders left behind are cleaned up afterward.
3. **Prefetch cleanup** — the same function runs against `C:\Windows\Prefetch`, but only if the script detects it's running elevated. Prefetch entries are safe to delete: Windows regenerates them automatically as needed.
4. **Post-cleanup measurement** — disk and RAM are measured again so the report shows a real, not estimated, delta.
5. **Report generation** — `New-HealthReportHtml` builds a self-contained HTML file (inline CSS, no external assets) with color-coded usage bars and a summary of files deleted / MB freed / files skipped. It's saved to the Desktop with a timestamped filename and opened via `Invoke-Item`.

## Sample report layout

The report includes:
- A summary card with total space freed and files cleaned
- Before/after disk usage cards with a color-coded usage bar (green / yellow / red based on thresholds)
- Before/after RAM usage cards
- A detail table showing deleted count, size, skipped count, and status per location (Temp / Prefetch)

## Safety notes

- The script never deletes files younger than the configured age threshold, by design.
- Deletions are try/caught individually — a single locked file will never abort the whole run.
- Prefetch cleanup is opt-in by nature: it only runs when the script has the privileges it actually needs, and clearly reports when it was skipped.
- No registry changes, no service modifications, no silent background execution — the script does exactly what's described above and nothing else.

## Roadmap

- [ ] Optional cleanup of the Recycle Bin and Windows Update cache
- [ ] CSV export alongside the HTML report
- [ ] Scheduled Task installer for periodic automated runs
- [ ] Multi-drive support (not just `C:`)

## License

MIT — use it, modify it, learn from it.

## Hasan Eren Aydoğar www.linkedin.com/in/hasan-eren-aydoğar-8b5644340

Built as a first public project while studying Computer Engineering, focused on PowerShell automation and Windows system administration fundamentals.
