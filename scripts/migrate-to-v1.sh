#!/usr/bin/env bash
#
# Migration script: provider-mongodbatlas v0.x --> v1.x
#
# Prepares a cluster for the v1alpha2 --> v1alpha3 version bump by:
#   1. Backfilling required fields on DatabaseUser CRs
#   2. Triggering re-storage of AdvancedCluster CRs
#   3. Removing v1alpha2 from storedVersions on affected CRDs
#
# IMPORTANT: v0.x's CRD schema for `users.database.mongodbatlas.crossplane.io`
# (v1alpha2) does not define `spec.forProvider.username`. Patching that field
# while v0.x's CRD is still installed is silently dropped by structural-schema
# pruning ("Warning: unknown field"). The field only exists once the v1.x CRD
# (v1alpha3) is installed. This script therefore MUST run in "pre" phase before
# the v1.x provider/CRDs are installed (to take backups only), and in "post"
# phase after the v1.x provider/CRDs are installed but before the provider's
# controller has reconciled the affected CRs, to backfill the now-required
# fields before any Update is attempted against them.
#
# Usage:
#   ./scripts/migrate-to-v1.sh pre    # run BEFORE installing/activating v1.x
#   ./scripts/migrate-to-v1.sh post   # run AFTER installing/activating v1.x,
#                                      # before letting the v1.x provider run
#
# Dry run (no changes applied):
#   DRY_RUN=true ./scripts/migrate-to-v1.sh pre
#   DRY_RUN=true ./scripts/migrate-to-v1.sh post
#
# DISCLAIMER: This script is provided "as is", without warranty of any kind,
# express or implied. Use at your own risk. Always test in a non-production
# environment first and ensure you have backups before running this script.
# The authors assume no liability for data loss or cluster disruption.

set -euo pipefail

BACKUP_DIR="/tmp/crossplane-migration-backup"
DRY_RUN="${DRY_RUN:-false}"

AFFECTED_CRDS=(
  "advancedclusters.mongodbatlas.crossplane.io"
  "advancedclusters.mongodbatlas.m.crossplane.io"
  "users.database.mongodbatlas.crossplane.io"
  "users.database.mongodbatlas.m.crossplane.io"
)

GREEN='\033[0;32m' ORANGE='\033[0;33m' RED='\033[0;31m' NC='\033[0m'
log()  { echo -e "${GREEN}[migrate]${NC} $*"; }
warn() { echo -e "${GREEN}[migrate]${NC} ${ORANGE}WARNING:${NC} $*" >&2; }
die()  { echo -e "${GREEN}[migrate]${NC} ${RED}ERROR:${NC} $*" >&2; exit 1; }

command -v kubectl >/dev/null || die "kubectl not found"
command -v jq >/dev/null      || die "jq not found"

PHASE="${1:-}"
case "$PHASE" in
  pre|post) ;;
  *) die "usage: $0 <pre|post>  (see script header for details)" ;;
esac

mkdir -p "$BACKUP_DIR"

backup_users() {
  db_users=$(kubectl get users.database.mongodbatlas.crossplane.io -A -o json 2>/dev/null || echo '{"items":[]}')
  echo "$db_users" | jq -c '.items[]' 2>/dev/null | while read -r cr; do
    name=$(echo "$cr" | jq -r '.metadata.name')
    ns=$(echo "$cr" | jq -r '.metadata.namespace // "cluster-scoped"')
    if [ "$ns" = "cluster-scoped" ]; then
      kubectl get users.database.mongodbatlas.crossplane.io "$name" -o yaml > "$BACKUP_DIR/dbuser-$name.yaml"
    else
      kubectl get users.database.mongodbatlas.crossplane.io "$name" -n "$ns" -o yaml > "$BACKUP_DIR/dbuser-$ns-$name.yaml"
    fi
  done
}

backup_advancedclusters() {
  adv_clusters=$(kubectl get advancedclusters.mongodbatlas.crossplane.io -A -o json 2>/dev/null || echo '{"items":[]}')
  echo "$adv_clusters" | jq -c '.items[]' 2>/dev/null | while read -r cr; do
    name=$(echo "$cr" | jq -r '.metadata.name')
    ns=$(echo "$cr" | jq -r '.metadata.namespace // "cluster-scoped"')
    if [ "$ns" = "cluster-scoped" ]; then
      kubectl get advancedclusters.mongodbatlas.crossplane.io "$name" -o yaml > "$BACKUP_DIR/advcluster-$name.yaml"
    else
      kubectl get advancedclusters.mongodbatlas.crossplane.io "$name" -n "$ns" -o yaml > "$BACKUP_DIR/advcluster-$ns-$name.yaml"
    fi
  done
}

if [ "$PHASE" = "pre" ]; then
  # -------------------------------------------------------------------------
  # Pre-phase: take backups only. Do NOT attempt to patch `username` yet -
  # v0.x's CRD schema doesn't have the field, so the patch would silently
  # no-op. Also do not touch storedVersions yet - v1alpha2 CRs still need
  # to be readable/writable by the still-installed v0.x provider.
  # -------------------------------------------------------------------------
  log "Pre-phase: backing up DatabaseUser and AdvancedCluster CRs..."

  if [ "$DRY_RUN" = "true" ]; then
    log "  [dry-run] would back up all DatabaseUser and AdvancedCluster CRs to $BACKUP_DIR"
  else
    backup_users
    backup_advancedclusters
  fi

  log ""
  log "Pre-phase complete. Backups saved to $BACKUP_DIR"
  log "Now install/activate the v1.x provider package (this installs the"
  log "v1alpha3 CRDs), WITHOUT yet letting its controller reconcile, then run:"
  log "  $0 post"
  exit 0
fi

# ---------------------------------------------------------------------------
# Post-phase: v1.x CRDs (v1alpha3) are now installed and serve `username`.
# Backfill required fields on existing CRs before the v1.x provider's
# controller attempts to reconcile (and thus Update/validate) them.
# ---------------------------------------------------------------------------

log "Post-phase Step 1: Patching DatabaseUser CRs..."

db_users=$(kubectl get users.database.mongodbatlas.crossplane.io -A -o json 2>/dev/null || echo '{"items":[]}')
user_count=$(echo "$db_users" | jq '.items | length')
log "  Found $user_count DatabaseUser CR(s)"

echo "$db_users" | jq -c '.items[]' | while read -r cr; do
  name=$(echo "$cr" | jq -r '.metadata.name')
  ns=$(echo "$cr" | jq -r '.metadata.namespace // "cluster-scoped"')
  ext_name=$(echo "$cr" | jq -r '.metadata.annotations["crossplane.io/external-name"] // empty')
  existing_username=$(echo "$cr" | jq -r '.spec.forProvider.username // empty')
  existing_auth_db=$(echo "$cr" | jq -r '.spec.forProvider.authDatabaseName // empty')

  log "  Processing DatabaseUser $ns/$name (external-name: $ext_name)"

  if [ -n "$existing_username" ]; then
    log "    username already set ($existing_username), skipping"
    continue
  fi

  if [ -z "$ext_name" ]; then
    warn "    No external-name annotation on $name, cannot infer username, skipping"
    continue
  fi

  # In v0.x the external-name format was: the raw username (via NameAsIdentifier)
  username="$ext_name"
  log "    Setting spec.forProvider.username = $username"

  patch_fields="\"username\":\"$username\""
  if [ -z "$existing_auth_db" ]; then
    log "    Setting spec.forProvider.authDatabaseName = admin (default)"
    patch_fields="$patch_fields,\"authDatabaseName\":\"admin\""
  fi
  patch="{\"spec\":{\"forProvider\":{$patch_fields}}}"

  if [ "$DRY_RUN" = "true" ]; then
    log "    [dry-run] would patch: $patch"
  else
    if [ "$ns" = "cluster-scoped" ]; then
      kubectl patch users.database.mongodbatlas.crossplane.io "$name" \
        --type=merge -p "$patch"
    else
      kubectl patch users.database.mongodbatlas.crossplane.io "$name" \
        -n "$ns" --type=merge -p "$patch"
    fi
  fi
done

# ---------------------------------------------------------------------------
# Post-phase Step 2: Touch AdvancedCluster CRs to trigger re-storage
# ---------------------------------------------------------------------------
log "Post-phase Step 2: Triggering re-storage of AdvancedCluster CRs..."

adv_clusters=$(kubectl get advancedclusters.mongodbatlas.crossplane.io -A -o json 2>/dev/null || echo '{"items":[]}')
ac_count=$(echo "$adv_clusters" | jq '.items | length')
log "  Found $ac_count AdvancedCluster CR(s)"

echo "$adv_clusters" | jq -c '.items[]' | while read -r cr; do
  name=$(echo "$cr" | jq -r '.metadata.name')
  ns=$(echo "$cr" | jq -r '.metadata.namespace // "cluster-scoped"')

  log "  Touching AdvancedCluster $ns/$name"

  if [ "$DRY_RUN" = "true" ]; then
    log "    [dry-run] would touch $name"
  else
    # Add a benign annotation to force a write (re-stores at current storage version)
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    patch='{"metadata":{"annotations":{"migration.crossplane.io/v1alpha3-restorage":"'"$ts"'"}}}'
    if [ "$ns" = "cluster-scoped" ]; then
      kubectl patch advancedclusters.mongodbatlas.crossplane.io "$name" \
        --type=merge -p "$patch"
    else
      kubectl patch advancedclusters.mongodbatlas.crossplane.io "$name" \
        -n "$ns" --type=merge -p "$patch"
    fi
  fi
done

# ---------------------------------------------------------------------------
# Post-phase Step 3: Remove v1alpha2 from storedVersions on affected CRDs
# ---------------------------------------------------------------------------
log "Post-phase Step 3: Removing v1alpha2 from storedVersions..."

for crd in "${AFFECTED_CRDS[@]}"; do
  stored=$(kubectl get crd "$crd" -o jsonpath='{.status.storedVersions}' 2>/dev/null || echo "[]")

  if echo "$stored" | grep -q 'v1alpha2'; then
    log "  $crd: replacing storedVersions with [\"v1alpha3\"]"
    if [ "$DRY_RUN" = "true" ]; then
      log "    [dry-run] would set storedVersions=[\"v1alpha3\"]"
    else
      kubectl patch crd "$crd" \
        --type='json' \
        --subresource=status \
        -p='[{"op":"replace","path":"/status/storedVersions","value":["v1alpha3"]}]'
    fi
  else
    log "  $crd: v1alpha2 not in storedVersions, skipping"
  fi
done

log ""
log "Post-phase complete. Backups (from the pre-phase run) are in $BACKUP_DIR"
log "The v1.x provider can now safely reconcile all migrated resources."
