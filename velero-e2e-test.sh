#!/usr/bin/env bash
#
# Velero E2E Backup & Restore Verification Test
#
# Deploys a PostgreSQL instance with known data, backs it up via Velero,
# destroys the namespace, restores, and verifies data integrity.
#
# Usage:
#   ./velero-e2e-test.sh [--kubeconfig <path>] [--keep] [--skip-cleanup]
#
# Requirements:
#   - kubectl with cluster access
#   - Velero CLI (optional, kubectl-native fallback)
#   - Cluster with working Velero + BSL
#

set -euo pipefail

# --- Configuration -----------------------------------------------------------
TEST_NS="${VELERO_TEST_NS:-velero-e2e-test}"
VELERO_NS="${VELERO_NS:-velero}"
BACKUP_NAME="e2e-test-$(date +%Y%m%d-%H%M%S)"
RESTORE_NAME="${BACKUP_NAME}-restore"
PG_PASSWORD="e2e-test-$(openssl rand -hex 8)"
STORAGE_CLASS="${VELERO_TEST_SC:-default}"
PVC_SIZE="${VELERO_TEST_PVC_SIZE:-1Gi}"
SEED_ROWS="${VELERO_TEST_ROWS:-100}"

# Timeouts (seconds)
BACKUP_TIMEOUT="${VELERO_BACKUP_TIMEOUT:-300}"
RESTORE_TIMEOUT="${VELERO_RESTORE_TIMEOUT:-300}"
POD_READY_TIMEOUT="${VELERO_POD_TIMEOUT:-180}"
NS_DELETE_TIMEOUT="${VELERO_NS_DELETE_TIMEOUT:-120}"
SNAPSHOT_READY_TIMEOUT="${VELERO_SNAPSHOT_TIMEOUT:-180}"

# Flags
KEEP_RESOURCES=false
SKIP_CLEANUP=false
KUBECONFIG_FLAG=""

# --- Parse args --------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig)  KUBECONFIG_FLAG="--kubeconfig=$2"; export KUBECONFIG="$2"; shift 2 ;;
    --keep)        KEEP_RESOURCES=true; shift ;;
    --skip-cleanup) SKIP_CLEANUP=true; shift ;;
    --storage-class) STORAGE_CLASS="$2"; shift 2 ;;
    --namespace)   TEST_NS="$2"; shift 2 ;;
    --help|-h)
      echo "Usage: $0 [--kubeconfig <path>] [--keep] [--skip-cleanup] [--storage-class <sc>] [--namespace <ns>]"
      echo ""
      echo "  --kubeconfig     Path to kubeconfig file"
      echo "  --keep           Keep test resources after successful run"
      echo "  --skip-cleanup   Skip cleanup on failure (for debugging)"
      echo "  --storage-class  Storage class for PVC (default: default)"
      echo "  --namespace      Test namespace name (default: velero-e2e-test)"
      exit 0
      ;;
    *) echo "Unknown flag: $1"; exit 1 ;;
  esac
done

# --- Helpers -----------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

log()      { echo -e "${CYAN}[$(date +%H:%M:%S)]${NC} $*"; }
log_ok()   { echo -e "${GREEN}[$(date +%H:%M:%S)] PASS${NC} $*"; }
log_fail() { echo -e "${RED}[$(date +%H:%M:%S)] FAIL${NC} $*"; }
log_warn() { echo -e "${YELLOW}[$(date +%H:%M:%S)] WARN${NC} $*"; }

kc() { kubectl ${KUBECONFIG_FLAG} "$@"; }

cleanup() {
  if [[ "$SKIP_CLEANUP" == "true" ]]; then
    log_warn "Skipping cleanup (--skip-cleanup). Resources left in ${TEST_NS}"
    return
  fi
  log "Cleaning up..."
  kc delete namespace "${TEST_NS}" --ignore-not-found --wait=false 2>/dev/null || true
  kc -n "${VELERO_NS}" delete backup "${BACKUP_NAME}" --ignore-not-found 2>/dev/null || true
  kc -n "${VELERO_NS}" delete restore "${RESTORE_NAME}" --ignore-not-found 2>/dev/null || true
}

die() {
  log_fail "$1"
  if [[ "$SKIP_CLEANUP" != "true" ]]; then
    cleanup
  fi
  exit 1
}

wait_for_condition() {
  local resource="$1" condition="$2" timeout="$3" namespace="$4"
  local elapsed=0
  while [[ $elapsed -lt $timeout ]]; do
    if kc -n "${namespace}" wait "${resource}" --for="${condition}" --timeout=5s 2>/dev/null; then
      return 0
    fi
    elapsed=$((elapsed + 5))
  done
  return 1
}

pg_exec() {
  kc -n "${TEST_NS}" exec sts/velero-test-pg -- \
    env PGPASSWORD="${PG_PASSWORD}" psql -U postgres -d e2etest -qtAX -c "$1" 2>/dev/null
}

# Verbose variant: surfaces psql errors to stderr (use for debugging seed/restore)
pg_exec_v() {
  kc -n "${TEST_NS}" exec sts/velero-test-pg -- \
    env PGPASSWORD="${PG_PASSWORD}" psql -U postgres -d e2etest -qtAX -c "$1"
}

# Pipe SQL via stdin (avoids shell-arg length limits and quoting issues)
pg_exec_stdin() {
  kc -n "${TEST_NS}" exec -i sts/velero-test-pg -- \
    env PGPASSWORD="${PG_PASSWORD}" psql -U postgres -d e2etest -qtAX
}

# Poll until the e2etest database + backup_test table are actually ready.
# postgres:16-alpine's pg_isready returns true on local socket BEFORE init
# scripts complete and BEFORE the TCP listener restarts. We must wait for
# the schema, not just the process.
wait_for_db_ready() {
  local timeout="${1:-90}"
  local elapsed=0
  while [[ $elapsed -lt $timeout ]]; do
    if kc -n "${TEST_NS}" exec sts/velero-test-pg -- \
      env PGPASSWORD="${PG_PASSWORD}" psql -U postgres -d e2etest -qtAX \
      -c "SELECT 1 FROM backup_test LIMIT 1;" &>/dev/null; then
      return 0
    fi
    sleep 3
    elapsed=$((elapsed + 3))
  done
  return 1
}

# --- Preflight ---------------------------------------------------------------
log "=== Velero E2E Backup/Restore Test ==="
log "Namespace:     ${TEST_NS}"
log "Backup name:   ${BACKUP_NAME}"
log "Storage class: ${STORAGE_CLASS}"
log "Seed rows:     ${SEED_ROWS}"
echo ""

# Verify Velero is operational
BSL_PHASE=$(kc -n "${VELERO_NS}" get backupstoragelocation primary -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
if [[ "${BSL_PHASE}" != "Available" ]]; then
  die "Velero BSL 'primary' is not Available (phase: ${BSL_PHASE}). Fix Velero first."
fi
log_ok "Velero BSL 'primary' is Available"

# Clean up leftover resources from previous failed runs
if kc get namespace "${TEST_NS}" &>/dev/null; then
  log_warn "Leftover namespace ${TEST_NS} found, cleaning up..."
  kc delete namespace "${TEST_NS}" --wait=true --timeout="${NS_DELETE_TIMEOUT}s" 2>/dev/null || true
  sleep 5
fi
kc -n "${VELERO_NS}" delete backup -l velero-e2e-test=true --ignore-not-found 2>/dev/null || true
kc -n "${VELERO_NS}" delete restore -l velero-e2e-test=true --ignore-not-found 2>/dev/null || true

# =============================================================================
# PHASE 1: Deploy PostgreSQL with PVC
# =============================================================================
log ""
log "=== Phase 1: Deploy test PostgreSQL ==="

kc create namespace "${TEST_NS}"
kc label namespace "${TEST_NS}" velero-e2e-test=true purpose=velero-backup-verification

cat <<EOF | kc apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-all
  namespace: ${TEST_NS}
  labels:
    velero-e2e-test: "true"
  annotations:
    description: "E2E test namespace - overrides Kyverno default-deny. Temporary."
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - {}
  egress:
    - {}
---
apiVersion: v1
kind: Secret
metadata:
  name: pg-secret
  namespace: ${TEST_NS}
  labels:
    velero-e2e-test: "true"
type: Opaque
stringData:
  POSTGRES_PASSWORD: "${PG_PASSWORD}"
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: pg-init
  namespace: ${TEST_NS}
  labels:
    velero-e2e-test: "true"
data:
  init.sql: |
    CREATE DATABASE e2etest;
    \c e2etest
    CREATE TABLE backup_test (
      id SERIAL PRIMARY KEY,
      seed_key VARCHAR(64) NOT NULL,
      payload TEXT NOT NULL,
      checksum VARCHAR(64) NOT NULL,
      created_at TIMESTAMP DEFAULT NOW()
    );
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: velero-test-pg
  namespace: ${TEST_NS}
  labels:
    app: velero-test-pg
    velero-e2e-test: "true"
spec:
  serviceName: velero-test-pg
  replicas: 1
  selector:
    matchLabels:
      app: velero-test-pg
  template:
    metadata:
      labels:
        app: velero-test-pg
        velero-e2e-test: "true"
    spec:
      terminationGracePeriodSeconds: 10
      containers:
      - name: postgres
        image: postgres:16-alpine
        ports:
        - containerPort: 5432
        env:
        - name: POSTGRES_PASSWORD
          valueFrom:
            secretKeyRef:
              name: pg-secret
              key: POSTGRES_PASSWORD
        - name: PGDATA
          value: /var/lib/postgresql/data/pgdata
        volumeMounts:
        - name: pg-data
          mountPath: /var/lib/postgresql/data
        - name: pg-init
          mountPath: /docker-entrypoint-initdb.d
        resources:
          requests:
            cpu: 50m
            memory: 128Mi
          limits:
            memory: 256Mi
        readinessProbe:
          exec:
            command: ["pg_isready", "-U", "postgres"]
          initialDelaySeconds: 5
          periodSeconds: 5
        livenessProbe:
          exec:
            command: ["pg_isready", "-U", "postgres"]
          initialDelaySeconds: 15
          periodSeconds: 10
      volumes:
      - name: pg-init
        configMap:
          name: pg-init
  volumeClaimTemplates:
  - metadata:
      name: pg-data
      labels:
        velero-e2e-test: "true"
    spec:
      accessModes: ["ReadWriteOnce"]
      storageClassName: "${STORAGE_CLASS}"
      resources:
        requests:
          storage: ${PVC_SIZE}
EOF

log "Waiting for PostgreSQL pod to be ready..."
if ! wait_for_condition "pod/velero-test-pg-0" "condition=Ready" "${POD_READY_TIMEOUT}" "${TEST_NS}"; then
  die "PostgreSQL pod did not become ready within ${POD_READY_TIMEOUT}s"
fi
log_ok "PostgreSQL pod is running"

# pg_isready goes True on the local socket BEFORE init scripts finish and
# BEFORE postgres restarts on TCP. Poll the actual schema instead of sleeping.
log "Waiting for e2etest database + backup_test table (init scripts)..."
if ! wait_for_db_ready 90; then
  log_warn "Database not ready. Dumping diagnostics..."
  kc -n "${TEST_NS}" exec sts/velero-test-pg -- \
    env PGPASSWORD="${PG_PASSWORD}" psql -U postgres -c "\l" 2>&1 || true
  kc -n "${TEST_NS}" logs sts/velero-test-pg --tail=50 2>&1 || true
  die "e2etest database / backup_test table not ready after init scripts"
fi
log_ok "Database e2etest ready"

# =============================================================================
# PHASE 2: Seed data and capture fingerprint
# =============================================================================
log ""
log "=== Phase 2: Seed data and capture fingerprint ==="

# Seed deterministic rows
SEED_SQL="INSERT INTO backup_test (seed_key, payload, checksum) VALUES"
for i in $(seq 1 "${SEED_ROWS}"); do
  KEY="velero-e2e-row-${i}"
  PAYLOAD="test-data-for-row-${i}-with-padding-$(printf '%040d' ${i})"
  CHECKSUM=$(echo -n "${KEY}:${PAYLOAD}" | md5sum | awk '{print $1}')
  SEP=","
  if [[ $i -eq ${SEED_ROWS} ]]; then SEP=";"; fi
  SEED_SQL="${SEED_SQL} ('${KEY}', '${PAYLOAD}', '${CHECKSUM}')${SEP}"
done

printf '%s\n' "${SEED_SQL}" | pg_exec_stdin 2>/tmp/pg_seed_err.$$ >/dev/null || {
  log_fail "Seed SQL failed. psql stderr:"
  cat /tmp/pg_seed_err.$$ >&2 || true
  rm -f /tmp/pg_seed_err.$$
  die "Failed to seed data"
}
rm -f /tmp/pg_seed_err.$$
log_ok "Seeded ${SEED_ROWS} rows"

# Capture fingerprint: row count + aggregate MD5
ROW_COUNT_BEFORE=$(pg_exec "SELECT count(*) FROM backup_test;")
FINGERPRINT_BEFORE=$(pg_exec "SELECT md5(string_agg(seed_key || ':' || payload || ':' || checksum, '|' ORDER BY id)) FROM backup_test;")

if [[ -z "${ROW_COUNT_BEFORE}" || -z "${FINGERPRINT_BEFORE}" ]]; then
  die "Failed to capture data fingerprint"
fi

log_ok "Data fingerprint captured"
log "  Row count:   ${ROW_COUNT_BEFORE}"
log "  Fingerprint: ${FINGERPRINT_BEFORE}"

# Verify individual row checksums are consistent
BAD_ROWS=$(pg_exec "SELECT count(*) FROM backup_test WHERE checksum != md5(seed_key || ':' || payload);")
if [[ "${BAD_ROWS}" != "0" ]]; then
  die "Data integrity check failed before backup: ${BAD_ROWS} rows with bad checksums"
fi
log_ok "All row checksums valid"

# =============================================================================
# PHASE 3: Create Velero backup
# =============================================================================
log ""
log "=== Phase 3: Create Velero backup ==="

cat <<EOF | kc apply -f -
apiVersion: velero.io/v1
kind: Backup
metadata:
  name: ${BACKUP_NAME}
  namespace: ${VELERO_NS}
  labels:
    velero-e2e-test: "true"
spec:
  includedNamespaces:
  - ${TEST_NS}
  includedResources:
  - '*'
  storageLocation: primary
  volumeSnapshotLocations:
  - primary
  snapshotMoveData: false
  defaultVolumesToFsBackup: false
  ttl: 2h0m0s
EOF

log "Waiting for backup '${BACKUP_NAME}' to complete (timeout: ${BACKUP_TIMEOUT}s)..."

ELAPSED=0
while [[ $ELAPSED -lt $BACKUP_TIMEOUT ]]; do
  PHASE=$(kc -n "${VELERO_NS}" get backup "${BACKUP_NAME}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  case "${PHASE}" in
    Completed)
      break
      ;;
    Failed|FailedValidation)
      FAILURE_REASON=$(kc -n "${VELERO_NS}" get backup "${BACKUP_NAME}" -o jsonpath='{.status.failureReason}' 2>/dev/null || echo "unknown")
      die "Backup failed with phase '${PHASE}': ${FAILURE_REASON}"
      ;;
    PartiallyFailed)
      # PartiallyFailed is terminal — surface warnings but continue (mirrors restore handling)
      ERRORS=$(kc -n "${VELERO_NS}" get backup "${BACKUP_NAME}" -o jsonpath='{.status.errors}' 2>/dev/null || echo "0")
      WARNINGS=$(kc -n "${VELERO_NS}" get backup "${BACKUP_NAME}" -o jsonpath='{.status.warnings}' 2>/dev/null || echo "0")
      if [[ "${ERRORS}" != "0" && "${ERRORS}" != "" ]]; then
        die "Backup PartiallyFailed with ${ERRORS} error(s) and ${WARNINGS} warning(s). Check: kubectl -n ${VELERO_NS} describe backup ${BACKUP_NAME}"
      fi
      log_warn "Backup PartiallyFailed with ${WARNINGS} warning(s) but 0 errors - continuing"
      break
      ;;
    ""|New|InProgress|WaitingForPluginOperations|WaitingForPluginOperationsPartiallyFailed|Finalizing|FinalizingPartiallyFailed)
      sleep 5
      ELAPSED=$((ELAPSED + 5))
      ;;
    *)
      die "Unexpected backup phase: ${PHASE}"
      ;;
  esac
done

if [[ "${PHASE}" != "Completed" && "${PHASE}" != "PartiallyFailed" ]]; then
  die "Backup timed out after ${BACKUP_TIMEOUT}s (last phase: ${PHASE})"
fi

SNAP_COUNT=$(kc -n "${VELERO_NS}" get backup "${BACKUP_NAME}" -o jsonpath='{.status.volumeSnapshotsCompleted}' 2>/dev/null || echo "0")
ITEMS=$(kc -n "${VELERO_NS}" get backup "${BACKUP_NAME}" -o jsonpath='{.status.progress.itemsBackedUp}' 2>/dev/null || echo "?")

log_ok "Backup completed: ${ITEMS} items, ${SNAP_COUNT} volume snapshot(s)"

if [[ "${SNAP_COUNT}" == "0" ]]; then
  log_warn "No volume snapshots taken - PVC data may not be included. Check CSI driver / VolumeSnapshotClass."
fi

# Wait for EBS snapshot to be ready (CSI VolumeSnapshot readyToUse=true)
# Velero marks backup Completed when snapshot is initiated, but AWS EBS snapshot
# can still be in 'pending' state. Restoring before it's ready causes:
#   "Snapshot is in invalid state - pending"
log "Waiting for VolumeSnapshot to be readyToUse (timeout: ${SNAPSHOT_READY_TIMEOUT}s)..."
ELAPSED=0
SNAP_READY=false
while [[ $ELAPSED -lt $SNAPSHOT_READY_TIMEOUT ]]; do
  # Find the VolumeSnapshot created for our PVC
  VS_READY=$(kc -n "${TEST_NS}" get volumesnapshot -o jsonpath='{.items[0].status.readyToUse}' 2>/dev/null || echo "")
  if [[ "${VS_READY}" == "true" ]]; then
    SNAP_READY=true
    break
  fi
  sleep 5
  ELAPSED=$((ELAPSED + 5))
done

if [[ "${SNAP_READY}" == "true" ]]; then
  log_ok "VolumeSnapshot is readyToUse"
else
  # Even if we can't confirm, the underlying EBS snapshot might still become ready
  # by the time restore runs. Log warning but continue.
  log_warn "VolumeSnapshot readyToUse not confirmed after ${SNAPSHOT_READY_TIMEOUT}s - proceeding anyway"
fi

# =============================================================================
# PHASE 4: Destroy test namespace (simulate disaster)
# =============================================================================
log ""
log "=== Phase 4: Destroy test namespace ==="

kc delete namespace "${TEST_NS}" --wait=true --timeout="${NS_DELETE_TIMEOUT}s" 2>/dev/null || true

# Verify it's gone
ELAPSED=0
while kc get namespace "${TEST_NS}" &>/dev/null && [[ $ELAPSED -lt $NS_DELETE_TIMEOUT ]]; do
  sleep 5
  ELAPSED=$((ELAPSED + 5))
done

if kc get namespace "${TEST_NS}" &>/dev/null; then
  die "Namespace ${TEST_NS} still exists after deletion timeout"
fi

log_ok "Namespace ${TEST_NS} fully deleted"

# Verify PVC is also gone
PVC_EXISTS=$(kc get pvc -A -l velero-e2e-test=true --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [[ "${PVC_EXISTS}" != "0" ]]; then
  log_warn "Orphaned PVCs found with velero-e2e-test label"
fi

# Wait for underlying EBS snapshot to leave 'pending' state
# The VolumeSnapshot was deleted with the namespace, but the VolumeSnapshotContent
# (cluster-scoped) and the AWS EBS snapshot still exist.
log "Waiting for EBS snapshot to be fully available..."
VSC_NAME=$(kc get volumesnapshotcontent -o json 2>/dev/null | \
  python3 -c "
import sys, json
data = json.load(sys.stdin)
for item in data.get('items', []):
  ref = item.get('spec', {}).get('volumeSnapshotRef', {})
  if ref.get('namespace') == '${TEST_NS}':
    print(item['metadata']['name'])
    break
" 2>/dev/null || echo "")

if [[ -n "${VSC_NAME}" ]]; then
  ELAPSED=0
  while [[ $ELAPSED -lt $SNAPSHOT_READY_TIMEOUT ]]; do
    VSC_READY=$(kc get volumesnapshotcontent "${VSC_NAME}" -o jsonpath='{.status.readyToUse}' 2>/dev/null || echo "")
    if [[ "${VSC_READY}" == "true" ]]; then
      log_ok "VolumeSnapshotContent ${VSC_NAME} is readyToUse"
      break
    fi
    sleep 5
    ELAPSED=$((ELAPSED + 5))
  done
  if [[ "${VSC_READY}" != "true" ]]; then
    log_warn "VolumeSnapshotContent not confirmed ready after ${SNAPSHOT_READY_TIMEOUT}s"
  fi
else
  log_warn "Could not find VolumeSnapshotContent for test PVC - snapshot may have been cleaned up"
fi

# =============================================================================
# PHASE 5: Restore from backup
# =============================================================================
log ""
log "=== Phase 5: Restore from backup ==="

cat <<EOF | kc apply -f -
apiVersion: velero.io/v1
kind: Restore
metadata:
  name: ${RESTORE_NAME}
  namespace: ${VELERO_NS}
  labels:
    velero-e2e-test: "true"
spec:
  backupName: ${BACKUP_NAME}
  includedNamespaces:
  - ${TEST_NS}
  includedResources:
  - '*'
  restorePVs: true
  existingResourcePolicy: update
EOF

log "Waiting for restore '${RESTORE_NAME}' to complete (timeout: ${RESTORE_TIMEOUT}s)..."

ELAPSED=0
while [[ $ELAPSED -lt $RESTORE_TIMEOUT ]]; do
  PHASE=$(kc -n "${VELERO_NS}" get restore "${RESTORE_NAME}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  case "${PHASE}" in
    Completed|PartiallyFailed)
      break
      ;;
    Failed)
      FAILURE_REASON=$(kc -n "${VELERO_NS}" get restore "${RESTORE_NAME}" -o jsonpath='{.status.failureReason}' 2>/dev/null || echo "unknown")
      die "Restore failed: ${FAILURE_REASON}"
      ;;
    ""|InProgress|WaitingForPluginOperations|WaitingForPluginOperationsPartiallyFailed)
      sleep 5
      ELAPSED=$((ELAPSED + 5))
      ;;
    *)
      die "Unexpected restore phase: ${PHASE}"
      ;;
  esac
done

if [[ "${PHASE}" == "PartiallyFailed" ]]; then
  # Check if there are actual errors (not just warnings)
  ERRORS=$(kc -n "${VELERO_NS}" get restore "${RESTORE_NAME}" -o jsonpath='{.status.errors}' 2>/dev/null || echo "0")
  WARNINGS=$(kc -n "${VELERO_NS}" get restore "${RESTORE_NAME}" -o jsonpath='{.status.warnings}' 2>/dev/null || echo "0")
  if [[ "${ERRORS}" != "0" && "${ERRORS}" != "" ]]; then
    die "Restore PartiallyFailed with ${ERRORS} error(s) and ${WARNINGS} warning(s). Check: kubectl -n ${VELERO_NS} describe restore ${RESTORE_NAME}"
  fi
  log_warn "Restore PartiallyFailed with ${WARNINGS} warning(s) but 0 errors (likely Kyverno/ExternalSecrets conflicts - acceptable)"
elif [[ "${PHASE}" == "Completed" ]]; then
  log_ok "Restore completed cleanly"
else
  die "Restore timed out after ${RESTORE_TIMEOUT}s (last phase: ${PHASE})"
fi

# Wait for PostgreSQL pod to be ready after restore
log "Waiting for PostgreSQL pod to recover after restore..."
sleep 10

if ! wait_for_condition "pod/velero-test-pg-0" "condition=Ready" "${POD_READY_TIMEOUT}" "${TEST_NS}"; then
  # Show pod status for debugging
  kc -n "${TEST_NS}" get pods -o wide 2>/dev/null || true
  kc -n "${TEST_NS}" describe pod velero-test-pg-0 2>/dev/null | tail -20 || true
  die "PostgreSQL pod did not become ready after restore within ${POD_READY_TIMEOUT}s"
fi

log_ok "PostgreSQL pod is running after restore"

# Give PG a moment to finish recovery
sleep 5

# =============================================================================
# PHASE 6: Verify data integrity
# =============================================================================
log ""
log "=== Phase 6: Verify data integrity ==="

# Row count
ROW_COUNT_AFTER=$(pg_exec "SELECT count(*) FROM backup_test;" 2>/dev/null || echo "ERROR")
if [[ "${ROW_COUNT_AFTER}" == "ERROR" || -z "${ROW_COUNT_AFTER}" ]]; then
  die "Cannot query PostgreSQL after restore - database not accessible"
fi

log "  Row count before: ${ROW_COUNT_BEFORE}"
log "  Row count after:  ${ROW_COUNT_AFTER}"

if [[ "${ROW_COUNT_BEFORE}" != "${ROW_COUNT_AFTER}" ]]; then
  die "Row count mismatch: expected ${ROW_COUNT_BEFORE}, got ${ROW_COUNT_AFTER}"
fi
log_ok "Row count matches"

# Aggregate fingerprint
FINGERPRINT_AFTER=$(pg_exec "SELECT md5(string_agg(seed_key || ':' || payload || ':' || checksum, '|' ORDER BY id)) FROM backup_test;")

log "  Fingerprint before: ${FINGERPRINT_BEFORE}"
log "  Fingerprint after:  ${FINGERPRINT_AFTER}"

if [[ "${FINGERPRINT_BEFORE}" != "${FINGERPRINT_AFTER}" ]]; then
  die "Data fingerprint mismatch - data was corrupted during backup/restore"
fi
log_ok "Data fingerprint matches"

# Verify individual row checksums
BAD_ROWS_AFTER=$(pg_exec "SELECT count(*) FROM backup_test WHERE checksum != md5(seed_key || ':' || payload);")
if [[ "${BAD_ROWS_AFTER}" != "0" ]]; then
  die "Post-restore integrity check failed: ${BAD_ROWS_AFTER} rows with bad checksums"
fi
log_ok "All individual row checksums valid"

# Verify sequence continuity (no gaps)
MAX_ID=$(pg_exec "SELECT max(id) FROM backup_test;")
log "  Max ID: ${MAX_ID} (expected: ${SEED_ROWS})"
if [[ "${MAX_ID}" != "${SEED_ROWS}" ]]; then
  log_warn "Sequence max ID (${MAX_ID}) differs from seed count (${SEED_ROWS}) - sequence may have reset"
fi

# =============================================================================
# PHASE 7: Cleanup
# =============================================================================
log ""
if [[ "${KEEP_RESOURCES}" == "true" ]]; then
  log "=== Keeping test resources (--keep flag) ==="
  log "  Namespace: ${TEST_NS}"
  log "  Backup:    ${BACKUP_NAME}"
  log "  Restore:   ${RESTORE_NAME}"
else
  log "=== Phase 7: Cleanup ==="
  cleanup
  log_ok "Cleanup complete"
fi

# =============================================================================
# RESULT
# =============================================================================
echo ""
echo "=============================================="
echo -e "${GREEN} VELERO E2E TEST PASSED ${NC}"
echo "=============================================="
echo "  Backup:      ${BACKUP_NAME}"
echo "  Rows tested: ${SEED_ROWS}"
echo "  Snapshots:   ${SNAP_COUNT}"
echo "  Fingerprint: ${FINGERPRINT_BEFORE}"
echo "=============================================="
exit 0
