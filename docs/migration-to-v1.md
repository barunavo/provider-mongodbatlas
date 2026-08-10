# Migration Guide to v1

> **Disclaimer:** This script and guide are provided "as is", without warranty of any kind, express
> or implied. Use at your own risk. Always test in a non-production environment first and ensure you
> have backups before running migration operations against your cluster.

## Breaking Changes

v1.0.0 upgrades these CRDs from `v1alpha2` to `v1alpha3`:

| CRD | Breaking Change |
|-----|----------------|
| `advancedclusters.mongodbatlas.crossplane.io` | Version bump. Also adds new required fields (`spec.forProvider.name`, `spec.forProvider.clusterType`, `spec.forProvider.replicationSpecs`), enforced via CEL validation. |
| `users.database.mongodbatlas.crossplane.io` | `spec.forProvider.username` is now a required field. Previously inferred from `metadata.name` via `crossplane.io/external-name`. |

## Prerequisites

- `kubectl` access to the cluster running `provider-mongodbatlas` v0.x.
- `jq` and `python3` (with PyYAML) installed.
- The v1.x provider's CRD YAMLs available locally (e.g. by checking out this
  repo at the target tag, or extracting `package/crds/` from the target
  provider image). You will need:
  - `package/crds/mongodbatlas.crossplane.io_advancedclusters.yaml`
  - `package/crds/database.mongodbatlas.crossplane.io_users.yaml`

## Why this is a two-phase migration involving a transitional CRD

`spec.forProvider.username` does not exist in the `v0.x` (`v1alpha2`) schema for
`users.database.mongodbatlas.crossplane.io` — it is only added in the `v1.x`
(`v1alpha3`) schema, which **replaces** `v1alpha2` rather than adding alongside
it. This creates a real chicken-and-egg problem:

- You cannot backfill `username` before the `v1.x` CRD is installed: the field
  doesn't exist yet, and Kubernetes' structural-schema pruning silently drops
  the patch ("Warning: unknown field").
- You cannot install the `v1.x` CRD (which only declares `v1alpha3`) while
  `status.storedVersions` on the live CRD still lists `v1alpha2` — Kubernetes
  refuses with an error like:
  ```
  status.storedVersions[0]: Invalid value: "v1alpha2": missing from spec.versions;
  v1alpha2 was previously a storage version, and must remain in spec.versions
  until a storage migration ensures no data remains persisted in v1alpha2 and
  removes v1alpha2 from status.storedVersions
  ```

The only way through is a **transitional CRD**, applied directly with `kubectl
apply` (bypassing Crossplane's package manager, which only ever ships the
single-version `v1.x` CRD), that serves both `v1alpha2` and `v1alpha3` side by
side. This lets existing objects be re-stored at `v1alpha3` (and `username`
backfilled) *before* `v1alpha2` is dropped, satisfying Kubernetes' migration
rule — without ever installing the real `v1.x` provider package prematurely.

The migration therefore runs in two phases:

1. **`pre`**: back up existing `DatabaseUser` and `AdvancedCluster` CRs; pause
   them (and their owning composites, see below); build and apply a
   transitional CRD (both versions served, `v1alpha3` as storage) for each
   affected CRD, using the v1.x CRD YAMLs you provide via `--v1-crds-dir`.
2. **`post`**: backfill `spec.forProvider.username` and
   `spec.forProvider.authDatabaseName` on `DatabaseUser` CRs, trigger
   re-storage of `AdvancedCluster` CRs, remove `v1alpha2` from
   `status.storedVersions`, then drop `v1alpha2` from `spec.versions`
   entirely so the CRD shape matches what the `v1.x` provider package will
   install.
3. Install/activate the `v1.x` provider package. Because the CRDs already
   match its expected (single-version `v1alpha3`) shape, it can now establish
   control cleanly.
4. Unpause the CRs and their owning composites.

## Composites/claims must also be paused

Pausing the leaf `DatabaseUser`/`AdvancedCluster` CR
(`crossplane.io/paused: "true"`) only stops **the provider's** reconciler from
touching it. It does **not** stop a Composite Resource (XR) that owns/composes
that CR from continuing to render and re-apply its (`v1alpha2`-shaped,
`username`-less) `base` template over it on every reconcile loop — which will
silently overwrite any `username` you just backfilled, with no error, the very
next time the composite reconciles. If you're running these resources as part
of a Crossplane Composition (the normal way they're consumed), this is *not*
optional.

The script discovers each affected CR's controlling owner
(`ownerReferences[]` where `controller: true`) and pauses it too. If it can't
find or pause the owner (e.g. an unexpected RBAC restriction), it prints a
warning — pause it manually before continuing in that case.

## Migration Steps

```bash
./scripts/migrate-to-v1.sh pre --v1-crds-dir /path/to/v1.x/package/crds
# follow the printed next steps: run `post`, THEN install/activate the v1.x
# provider package, THEN unpause
./scripts/migrate-to-v1.sh post
# install / activate the v1.x provider package here
# once it is Healthy, remove the crossplane.io/paused annotation from every
# CR and composite the script paused
```

## Dry Run

Preview changes without modifying anything:

```bash
DRY_RUN=true ./scripts/migrate-to-v1.sh pre --v1-crds-dir /path/to/v1.x/package/crds
DRY_RUN=true ./scripts/migrate-to-v1.sh post
```

Example output:

```
[migrate] Pre-phase 1/3: backing up DatabaseUser and AdvancedCluster CRs...
[migrate]   [dry-run] would back up all DatabaseUser and AdvancedCluster CRs to /tmp/crossplane-migration-backup
[migrate] Pre-phase 2/3: pausing DatabaseUser/AdvancedCluster CRs and their owning composites...
[migrate]   Pausing users.database.mongodbatlas.crossplane.io/my-db-user (and its owning composite, if any)
[migrate]     [dry-run] would pause users.database.mongodbatlas.crossplane.io/my-db-user
[migrate]     Owning composite: XDBUser/my-db-user-abc12 (composite.example.org/v1alpha1)
[migrate]     [dry-run] would pause xdbuser/my-db-user-abc12
[migrate] Pre-phase 3/3: building and applying transitional (dual-version) CRDs...
[migrate]   [dry-run] would build and apply transitional CRDs for users.database.mongodbatlas.crossplane.io and advancedclusters.mongodbatlas.crossplane.io
[migrate]
[migrate] Pre-phase complete. Backups saved to /tmp/crossplane-migration-backup
...
```

## Rollback

The script creates a backup of each modified CR (and, in the `pre` phase, each
CRD before it was made transitional) in `/tmp/crossplane-migration-backup/`.
To restore a CR from backup:

```bash
for f in /tmp/crossplane-migration-backup/*.yaml; do
  kubectl apply -f "$f"
done
```

Restoring a CRD from its backup (`live-crd-<name>.yaml`) after `spec.versions`
has already been narrowed down (e.g. by `post`) is more involved: you may need
to temporarily re-widen `spec.versions` to make the currently-stored objects
readable again before re-storing them at the old version and narrowing the
CRD back down. Treat this migration as far easier to move forward through than
to reverse once `post` has run against real data — verify thoroughly in a
non-production environment first.
