# velero-dr-e2e

Automated **end-to-end disaster-recovery test for [Velero](https://velero.io/)** on Kubernetes.

It proves that a Velero backup can actually be *restored with byte-for-byte data
integrity* — not just that the backup phase reports `Completed`. The script
stands up a real stateful workload (PostgreSQL + PVC), seeds deterministic data,
backs it up, **destroys the namespace**, restores from the backup, and verifies
the data matches by row count and cryptographic fingerprint.

## Why this matters

A green backup is not a recovery. Most "backup works" claims never test the
restore path, the CSI volume snapshot lifecycle, or data integrity. This test
exercises the whole loop, including the subtle race conditions that make restores
fail in the real world.

## What it verifies

| Phase | Check |
|-------|-------|
| 1. Deploy | PostgreSQL StatefulSet with a PVC comes up Ready |
| 2. Seed | N deterministic rows inserted; per-row MD5 checksums valid |
| 3. Backup | Velero `Backup` reaches `Completed` (or `PartiallyFailed` with 0 errors) |
| 3b. Snapshot | CSI `VolumeSnapshot` / `VolumeSnapshotContent` reaches `readyToUse=true` |
| 4. Disaster | Namespace + PVC fully deleted |
| 5. Restore | Velero `Restore` reaches `Completed`; workload recovers |
| 6. Integrity | Row count **and** aggregate MD5 fingerprint match pre-backup state |

Real-world edge cases handled explicitly:

- `pg_isready` returns healthy on the local socket **before** init scripts finish
  and before the TCP listener restarts — the script polls the actual schema
  instead of sleeping.
- Velero marks a backup `Completed` when the snapshot is *initiated*, but the
  underlying cloud (e.g. AWS EBS) snapshot can still be `pending`. Restoring too
  early throws `Snapshot is in invalid state - pending`; the script waits for
  `readyToUse`.
- `PartiallyFailed` with warnings-but-zero-errors (common with admission
  webhooks / external-secrets conflicts) is treated as a pass.

## Requirements

- `kubectl` with cluster access
- A working Velero install with an `Available` BackupStorageLocation named `primary`
- A CSI driver + `VolumeSnapshotClass` for PVC snapshots
- `openssl`, `python3` (used for VolumeSnapshotContent lookup)

## Usage

```bash
./velero-e2e-test.sh                          # run against current kube-context
./velero-e2e-test.sh --kubeconfig ~/.kube/config
./velero-e2e-test.sh --storage-class gp3      # pick a storage class
./velero-e2e-test.sh --namespace dr-check     # custom test namespace
./velero-e2e-test.sh --keep                   # leave resources for inspection
./velero-e2e-test.sh --skip-cleanup           # keep resources on failure (debug)
```

### Tunables (env vars)

| Var | Default | Meaning |
|-----|---------|---------|
| `VELERO_NS` | `velero` | Velero install namespace |
| `VELERO_TEST_NS` | `velero-e2e-test` | Test namespace |
| `VELERO_TEST_SC` | `default` | Storage class for the PVC |
| `VELERO_TEST_ROWS` | `100` | Rows to seed |
| `VELERO_BACKUP_TIMEOUT` | `300` | Backup wait (s) |
| `VELERO_RESTORE_TIMEOUT` | `300` | Restore wait (s) |

## Sample output

```
[12:00:01] === Velero E2E Backup/Restore Test ===
[12:00:02] PASS Velero BSL 'primary' is Available
[12:00:20] PASS PostgreSQL pod is running
[12:01:05] PASS Backup completed: 34 items, 1 volume snapshot(s)
[12:02:40] PASS Restore completed cleanly
[12:02:55] PASS Row count matches
[12:02:56] PASS Data fingerprint matches
==============================================
 VELERO E2E TEST PASSED
==============================================
```

Exit code is `0` on pass, non-zero on any integrity failure — ready to drop into
CI as a scheduled DR verification job.

## License

[MIT](./LICENSE)
