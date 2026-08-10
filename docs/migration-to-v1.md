# Migration Guide to v1

> **Disclaimer:** This script and guide are provided "as is", without warranty of any kind, express
> or implied. Use at your own risk. Always test in a non-production environment first and ensure you
> have backups before running migration operations against your cluster.

## Breaking Changes

v1.0.0 upgrades these CRDs from `v1alpha2` to `v1alpha3`:

| CRD | Breaking Change |
|-----|----------------|
| `advancedclusters.mongodbatlas.crossplane.io` | Version bump only (schema compatible) |
| `users.database.mongodbatlas.crossplane.io` | `spec.forProvider.username` is now a required field. Previously inferred from `metadata.name` via `crossplane.io/external-name` |

## Prerequisites

- `kubectl` access to the cluster running `provider-mongodbatlas` v0.x.
- `jq` installed.
- Provider v1.x package ready to install.

## Why this is a two-phase migration

`spec.forProvider.username` does not exist in the `v0.x` (`v1alpha2`) schema for
`users.database.mongodbatlas.crossplane.io` — it is only added in the `v1.x`
(`v1alpha3`) schema. Patching `username` while the `v0.x` CRD is still active is
silently dropped by Kubernetes' structural-schema pruning ("Warning: unknown
field"), so the field **cannot** be backfilled before the `v1.x` CRDs are
installed. It also cannot be left until after the `v1.x` provider's controller
starts reconciling, because the CRD's CEL validation rejects any `Update`/`Create`
against a `User` missing `username`.

The migration therefore runs in two phases:

1. **`pre`** (before installing/activating the `v1.x` provider): back up existing
   `DatabaseUser` and `AdvancedCluster` CRs.
2. Install/activate the `v1.x` provider package. This installs the `v1alpha3`
   CRDs (which serve `username`) but you should do this before its controller
   has a chance to reconcile the affected CRs — e.g. scale/pause the provider
   deployment immediately after activation if your setup allows it.
3. **`post`** (after the `v1.x` CRDs are installed): backfill `spec.forProvider.username`
   and `spec.forProvider.authDatabaseName` on `DatabaseUser` CRs, trigger
   re-storage of `AdvancedCluster` CRs, and remove `v1alpha2` from
   `status.storedVersions` on the affected CRDs.

## Migration Steps

```bash
./scripts/migrate-to-v1.sh pre
# install / activate the v1.x provider package here
./scripts/migrate-to-v1.sh post
```

## Dry Run

Preview changes without modifying anything:

```bash
DRY_RUN=true ./scripts/migrate-to-v1.sh pre
DRY_RUN=true ./scripts/migrate-to-v1.sh post
```

Example output:

```
[migrate] Post-phase Step 1: Patching DatabaseUser CRs...
[migrate]   Found 2 DatabaseUser CR(s)
[migrate]   Processing default/my-db-user (external-name: admin)
[migrate]     [dry-run] would patch: {"spec":{"forProvider":{"username":"admin","authDatabaseName":"admin"}}}
[migrate]   Processing default/my-other-user (external-name: readonly)
[migrate]     [dry-run] would patch: {"spec":{"forProvider":{"username":"readonly","authDatabaseName":"admin"}}}
[migrate] Post-phase Step 2: Triggering re-storage of AdvancedCluster CRs...
[migrate]   Found 1 AdvancedCluster CR(s)
[migrate]   Touching default/my-cluster
[migrate]     [dry-run] would touch my-cluster
[migrate] Post-phase Step 3: Removing v1alpha2 from storedVersions...
[migrate]   advancedclusters.mongodbatlas.crossplane.io: removing v1alpha2 from storedVersions
[migrate]     [dry-run] would set storedVersions=["v1alpha3"]
[migrate]   users.database.mongodbatlas.crossplane.io: removing v1alpha2 from storedVersions
[migrate]     [dry-run] would set storedVersions=["v1alpha3"]
[migrate]
[migrate] Post-phase complete. Backups (from the pre-phase run) are in /tmp/crossplane-migration-backup
[migrate] The v1.x provider can now safely reconcile all migrated resources.
```

## Rollback

The script creates a backup of each modified CR in `/tmp/crossplane-migration-backup/` before patching. To restore:

```bash
for f in /tmp/crossplane-migration-backup/*.yaml; do
  kubectl apply -f "$f"
done
```
