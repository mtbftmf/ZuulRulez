# External RAID0 storage - M5 Max Studio 128 GB

Applies ONLY to the M5 Max Studio 128 GB host. Generic M-series and `houdini`
friends-and-family builds do not use it: `RAID_ENABLED` defaults to 0, which
makes `raid-guard.sh` do nothing.

## What lives where

| Location | Contents |
| --- | --- |
| Internal NVMe | Flash-Next and Gemma 4 (live models), LM Studio config, Open WebUI venv, SQLite DB and WAL |
| `/Volumes/<RAID_VOL>/models` | Extra models and an archive of older ones. Appears in LM Studio as `~/.lmstudio/models/raid-archive` (symlink) |
| `/Volumes/<RAID_VOL>/scratch`, `/tmp` | Quantize/convert intermediates, Hugging Face downloads, RAG/ETL staging, vector-index rebuilds. All recreatable |

Why Flash stays internal: it memory-maps 88 GB of weights. If the stripe
unmounts while it is mapped, the process faults, and a fallback only helps at
the next start. The stripe has no redundancy and has unmounted unexpectedly once.
The database stays internal because fsync'd writes on the stripe are slow.

## Runtime

- `flash-up.sh` sources `m5/scripts/raid-guard.sh` before starting the stack.
- The script reads `~/.config/lmstudio-raid.env` (not committed; template at
  `m5/config/lmstudio-raid.env.example`). It finds the volume by `RAID_UUID` if set,
  otherwise by volume name, mounts it (retrying up to `RAID_TIMEOUT` seconds),
  creates `models/`, `scratch/`, `tmp/`, and links `raid-archive`.
- If the volume is missing it removes the link, posts a notification and returns
  non-zero. Flash and Gemma are unaffected; only the extra models go offline.
- It exports `RAID_SCRATCH` when the volume is up, for scripts that want scratch.
- Never point `TMPDIR` at the volume, and never keep a lone canonical copy of
  anything on it.

## Setup

1. Copy `lmstudio-raid.env.example` to `~/.config/lmstudio-raid.env` and set
   `RAID_VOL`; optionally `RAID_UUID` (`diskutil info /Volumes/<RAID_VOL> | grep -i uuid`).
2. Lay models out as `/Volumes/<RAID_VOL>/models/<model-folder>/<file>.gguf`.
   LM Studio lists them under the publisher `raid-archive`.
3. Run `~/bin/flash-up.sh` (or log in) and check `ls ~/.lmstudio/models/raid-archive`.
4. Test one small model from the volume before moving anything else.

## Measured (2026-10-22, external volume only, direct I/O past the 128 GB RAM cache)

- Sequential read, 1 MiB, queue depth 1: 4,897 MB/s sustained, average completion
  latency 214 us (547 GiB moved).
- Sequential write, 1 MiB, fsync'd: 747 MB/s sustained.
- Random 4K write, QD32: roughly 2x the internal IOPS at about half the latency.

Not established: an internal-drive sequential read under the same test, and any
low-queue-depth random-read comparison. An earlier table claiming 1.7 ms external
vs 10.8 ms internal mmap latency did not reconcile with its own IOPS figures and
is not relied on here. The case for the volume is capacity, not speed.

## Reliability

AppleRAID stripe = zero redundancy; losing either drive loses the volume.
Keep everything on it re-downloadable or re-creatable.
