# Spacebar agent surface

The one-line claim: **Spacebar reports what deleting would actually return, in APFS's own
numbers, as JSON an agent can read.**

A storage app that only prints folder sizes is a bar chart. The useful questions are harder, and
they have measured answers:

- "Finder says 43 GB available. `statvfs` says 38 GB. Which is true?" Both. The gap is
  purgeable space macOS evicts before it calls the volume full.
- "I deleted 30 GB and free space moved 4 GB. Why?" Snapshots pin blocks, clones share extents,
  and the container pool is shared with the System, VM and Update volumes.
- "How much of this folder is really mine to free?" Allocated blocks, counted once per inode,
  with the shared-block and coverage caveats attached.

`spacebar` answers those without an account, a network call, administrator rights or a delete path.

## Install

```sh
./Scripts/install-cli.sh              # -> ~/.local/bin/spacebar
```

The installer prefers the binary bundled inside `SpaceBar.app/Contents/Helpers/spacebar`, so the
command and the app are always the same build.

## Commands

| Command | Answers |
| --- | --- |
| `spacebar status` | CPU, memory, pressure, swap, GPU, capacity — the same readings the app shows |
| `spacebar volume` | Filesystem vs container vs eviction-hint free space, per-volume usage, snapshot flags |
| `spacebar scan [path]` | Folder sizes by allocated blocks and apparent lengths, with shared-inode counts |
| `spacebar reclaim [path]` | Dry-run plan: measured reclaim per row, a confidence level, and the reasons |
| `spacebar explain` | Prose answer to "why is my storage full when I deleted 40 GB?" |
| `spacebar schema` | This contract, field by field, in JSON |

Flags: `--json`, `--limit N`, `--seconds N`, `--no-snapshots` (skips the per-volume snapshot calls).
Paths expand `~`. Default scan root is the home directory.

Exit codes: `0` complete, `2` partial coverage (the numbers are floors, read
`plan.limits` / `findings` before acting), `1` the measurement failed and nothing was invented.

## Contract

Payload keys are snake_case; byte fields are decimal integers (`1 GB = 1_000_000_000`);
timestamps are ISO 8601. An absent key means "not measured" — never zero.

```jsonc
{
  "ok": true,
  "coverage": "complete" | "partial" | "failed",
  "measured_at": "2026-11-20T16:50:35Z",
  "accounting": {
    "filesystem_free_bytes": 39425089536,          // statvfs: what a plain write can take now
    "important_usage_available_bytes": 42976912633, // what Finder calls available
    "purgeable_bytes": 3551823097,                  // the difference, derived
    "opportunistic_usage_available_bytes": 27900000000,
    "container_free_bytes": 39425064960,            // the shared APFS pool
    "reserved_for_siblings_bytes": 0,                // advertised free the pool lacks
    "volumes": [{ "identifier": "disk3s5", "name": "Data", "roles": ["Data"],
                  "capacity_in_use_bytes": 395690000000 }],
    "non_data_used_bytes": 60530331648,             // invisible to any home-folder scan
    "unattributed_bytes": 160374784,                // may be negative; reported as measured
    "snapshots": { "count": 3, "non_purgeable_count": 3, "shrink_limiting_count": 0,
                   "snapshots": [{ "name": "com.apple.os.update-…", "kind": "systemUpdate",
                                   "is_purgeable": false, "limits_container_shrink": false }],
                   "byte_sizes_available": false,
                   "byte_size_reason": "APFS snapshot sizes are not exposed to an unprivileged process…" },
    "failures": ["Snapshot lists unreadable for: disk3s3 (Recovery)."]
  },
  "findings": [{ "id": "purgeable-space", "severity": "note", "title": "3.55 GB is purgeable, not used.",
                 "detail": "…", "bytes": 3551823097, "action": "No action needed unless a write actually fails." }],
  "scan": { "rows": [{ "url": "file:///Users/you/Library/Caches", "allocated_bytes": 1009754112,
                       "apparent_bytes": 1009754112, "shared_block_files": 522, "is_partial": false }],
            "scanned_files": 44290, "denied_count": 3, "skipped_symlinks": 143,
            "skipped_cloud_placeholders": 0, "skipped_mounts": 0,
            "was_cancelled": false, "was_time_limited": false },
  "plan": {
    "schema_version": 1,
    "candidates": [{ "path": "/Users/you/Library/Caches/Homebrew",
                     "allocated_bytes": 1009754112, "apparent_bytes": 1009754112,
                     "estimated_free_bytes": 1009754112, "shared_block_files": 522,
                     "confidence": "qualified",
                     "reasons": ["522 files share blocks with paths outside this scan.",
                                 "A non-purgeable APFS snapshot may pin blocks this scan counted."],
                     "action": "Move to Trash from SpaceBar's Storage view, then empty Trash in Finder.",
                     "deletes_automatically": false }],
    "total_estimated_free_bytes": 2545197056,
    "guarantees": ["Nothing here is deleted by Spacebar; …", "estimated_free_bytes counts filesystem blocks, measured once per inode.", "Sizes use decimal units …"],
    "limits": ["Scan coverage was incomplete, so totals are floors, not sums.", "…"]
  }
}
```

### `confidence`

| Value | Means |
| --- | --- |
| `measured` | Every counted inode was exclusive to this subtree, coverage was complete, no snapshot flag |
| `qualified` | The bytes are right, but returning them is uncertain: shared blocks or a live snapshot |
| `low` | The scan did not finish — the number is a floor |

## What an agent may rely on

- `allocated_bytes` / `estimated_free_bytes` are block claims measured once per inode. Sparse files
  show up as apparent > allocated; many small files show the reverse.
- Volumes and snapshots are read from the container, so the numbers include what a home-directory
  scan can never see: swap on the VM volume, staged installer data, the System volume.
- `findings[].bytes` is the measurement behind the sentence, not a projection.
- A failed helper call becomes an entry in `accounting.failures` and a `measurement-failed`
  finding. It never becomes `0`.

## What an agent must not conclude

- Deleting a file returns its bytes immediately: snapshots and clones can delay it, which is why
  `confidence` exists and why `plan.limits` is a list rather than a footnote.
- APFS clone extents are invisible to an unprivileged process. A clone reports one link and shared
  blocks; Spacebar marks that subtree `qualified` instead of pretending it knows.
- Snapshot byte sizes are not exposed without administrator access. Spacebar reports names,
  purgeable flags and `limits_container_shrink`, and says the sizes are unavailable.
- Spacebar has no delete, no Empty Trash, no process termination, no network call and no sudo. The
  only destructive step in the product is a confirmed move to Trash that a person triggers in the app.

## Reading it from an agent

```sh
spacebar reclaim ~/Library/Caches --json --limit 5 | jq -r '.plan.candidates[] | "\(.confidence) \(.estimated_free_bytes) \(.path)"'
spacebar explain                       # the human version of the same numbers
spacebar volume --json | jq '.accounting.purgeable_bytes'
```
