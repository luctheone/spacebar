# SpaceBar

A native macOS menu-bar storage and system checker built for agents.
SpaceBar's one-line difference: **it reports what deleting would actually
return, in APFS's own numbers, as JSON an agent can read.** The panel and the
CLI run the same core, so a terminal or a coding agent sees exactly what you
see.

SpaceBar has its own app icon in the Dock and Command-Tab while it is running.
Opening the app shows its window. Closing the window keeps the Dock icon,
menu-bar icon and available-space label running; click its Dock icon to reopen
the window. Click the menu-bar item for the compact panel; **More → Open in a
window** also brings back the window. Quit SpaceBar to remove its running Dock
icon and stop monitoring.

## Views

- **Overview:** available storage on the home filesystem, the APFS container split, memory estimate and pressure, compressed memory, swap, aggregate CPU and GPU activity. Live readings refresh every two seconds while a panel is visible and about every thirty seconds while closed. Live updates can be paused.
- **Storage:** select Home, Documents, Library or a folder from the native picker. Scan sizes manually, drill into directories, move up, or reveal a row in Finder. Scans count allocated blocks and file lengths separately, exclude cloud-only placeholders and symlinks, deduplicate hardlinks, and report unreadable/partial coverage. They stop on request, at two minutes, or at the directory-depth bound. Scans never read file contents. **Container truth** shows, on demand, what Finder counts as available, what a plain write can take, and how much of the container sits outside any home-directory scan; **Findings** list the reasons the numbers disagree; a **Reclaim plan** ranks the scanned folders by blocks a delete would free, each with a confidence level and the reasons it is qualified or low. An item's **••• → Move to Trash…** shows its exact path and measured size before confirmation, then rescans. Cancelling leaves it in place. Trash is limited to descendants of your home directory; the home directory, standard top-level personal/Library containers and Trash itself are protected. Parent symlinks cannot escape that boundary or bypass those container checks. There is no permanent-delete fallback or Empty Trash action; reclaim space by emptying Trash yourself in Finder.
- **Memory:** current RAM estimate, kernel pressure, compression, swap, and a recent five-minute session trend. Apps and services are ranked by **physical footprint**, with helpers grouped through their outer app bundle or observed parent process. Expand an app for its PIDs and separate footprint/RSS readings; filter by app, process name or PID. Missing readings remain unavailable or partial (≥), never successful zeroes. App-level sampling runs at most every ten seconds while this view is open; Refresh requests a fresh sample. It stops when the panel/window is closed or minimized. System summary checks retain the normal lighter schedule.
- **Processes:** top resident-memory or CPU users, real process names and PIDs, application icons when available, and a shortcut to the system Activity Monitor for advanced operations. Process arguments and environment variables are never collected.

There is no account, password, Keychain use, cloud service, login item,
automatic folder scan or automatic cleanup. No Full Disk Access is required or
modified, and nothing needs root. A folder picker can grant access to a
selected folder; macOS may deny protected folders or Trash operations, which
remain explicit errors. The container readings come from read-only
`diskutil apfs` plist calls, run only when you ask for that view or invoke the
CLI.

## Agent surface

`spacebar` ships inside the app bundle at `Contents/Helpers/spacebar` and
installs to `~/.local/bin/spacebar` with `./Scripts/install-cli.sh`.

```sh
spacebar status --json          # disk, memory, pressure, swap, CPU, top processes
spacebar volume --json          # APFS container, per-volume use, purgeable, snapshots
spacebar scan ~/Library/Caches --json
spacebar reclaim ~/Library/Caches --json --limit 5
spacebar explain                # why Finder, a plain write and a folder scan disagree
spacebar schema                 # every JSON key, its meaning, and the exit codes
```

Run `spacebar schema` instead of guessing at the payload. Exit codes are `0`
complete, `2` measured with partial coverage, `1` measurement failed. A key
that was not measured is absent; there are no placeholder zeroes. SpaceBar
never deletes, never empties Trash, never terminates a process, never uploads,
and never uses elevated privileges — `reclaim` is a dry-run plan you then act
on yourself. See [docs/agent-surface.md](docs/agent-surface.md) for the full
contract and the confidence rules.

## Measurement limits

Storage reports three different true numbers and does not blend them: what
`statvfs` says is free right now, what Finder counts as available once macOS
evicts purgeable caches and thins iCloud files, and what the APFS container
itself has left. Per-volume use and the container totals come from
`diskutil apfs list`; the volume identifier behind your home directory comes
from `statfs`, so no path needs to be a mount point. `purgeable_bytes`,
`reserved_for_siblings_bytes`, `unattributed_bytes` and
`data_volume_used_bytes` are derived, and each derivation is stated in the
schema.

Folder sizes are estimates, not guaranteed recoverable space. A scan reports
allocated blocks (what a delete would release now) and file lengths (what the
entries claim) separately, and flags how many of its files share blocks by
hardlink. APFS clone and shared extents are not visible to unprivileged
metadata reads, so cloning is disclosed as a caveat, not measured per file.
Sizes use file-style decimal units for disk and memory-style units for RAM.

APFS snapshots are listed by name, kind and purgeable flag only:
`diskutil apfs listSnapshots` does not expose snapshot byte sizes without
elevated access, and asking would not make the number real. `bytes` therefore
stays absent from snapshot findings. Non-purgeable snapshots can pin blocks
that a scan counted, which is why a candidate's confidence drops to
*qualified* when one exists.

System memory is an estimate from active + wired + physical compressor pages,
capped at installed RAM. It is not a reproduction of Activity Monitor's
private accounting. Pressure comes from the kernel; swap can remain allocated
after pressure falls. Memory's process readings use macOS `proc_pid_rusage` /
`ri_phys_footprint` ledgers, which include dirty, compressed/swapped and some
graphics charges. They can exceed resident memory and do not partition
installed RAM. Never add footprint, RSS and GPU counters together.
Protected/exited processes produce explicit coverage gaps, and grouping by
ancestry cannot identify a broker-launched process's client when macOS does
not expose that link. Processes retains RSS and CPU views; per-process CPU can
exceed 100% across cores. GPU activity is an aggregate device counter when
available.

The scanner uses descriptor-relative no-follow traversal for descendants.
macOS resolves the explicitly selected root's ancestors.
Cancellation/deadline checks occur between metadata operations and cannot
interrupt a kernel call already blocked inside macOS. Shared hardlinks are
counted once per scan, so attribution across sibling folders can differ from
separate scans. `diskutil` runs are bounded by a deadline and reported as
failures rather than inferred as zeros.

## Build and checks

Requires the Xcode Command Line Tools; no third-party runtime or package
dependencies. `./Scripts/swift-package.sh` selects the SDK installed on your
machine.

```sh
swift build                                              # core + app + CLI
swift run SpaceBarChecks                                  # accounting, memory and trash checks
./Scripts/swift-package.sh run -c release SpaceBarChecks   # same checks, release config
./Scripts/build-app.sh                                     # app bundle + bundled CLI
./Scripts/install-cli.sh                                   # ~/.local/bin/spacebar
```

`build-app.sh` builds both products: the menu-bar app binary and
`spacebar-cli`, which is copied into the bundle as `Contents/Helpers/spacebar`
and ad-hoc signed with it. The app is roughly 2 MB, and build products stay in
the temporary directory the scripts choose.

## License

[MIT](LICENSE)
