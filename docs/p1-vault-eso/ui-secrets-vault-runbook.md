# skirmbooks-ui-secrets → 1Password/ESO — Runbook (DR + rotation + safe apply)

Phase **P1** (2026-06-21, Vault era): migrate the k8s Secret
`skirmshop/skirmbooks-ui-secrets` (the manual Opaque secret holding
**SESSION_SECRET**, the HMAC root of every session + the signed `sb_tenant`
cookie) from a hand-applied secret to an ESO-managed ExternalSecret — **zero
downtime, zero key loss**.

**SC-496 (2026-09)**: the ExternalSecret source is now the 1Password item
`skirmshop-skirmbooks-ui` (vault `k8s-pocharlies`); item field = former Vault
property. The Vault-era SAFE APPLY PLAN and the validation evidence below are
kept as a dated historical record; the live seed / rotation / DR mechanics use
`op`.

The skirmbooks-ui Deployment consumes this secret via `envFrom.secretRef`
(`k8s/manifest.yaml`). With `AUTH_ENABLED=true` the pod is **fail-closed (C3)**:
if `SESSION_SECRET` is missing/empty the pod will not start. So we must never let
the secret lose a key.

## Topology / facts (verified 2026-06-21)

| Item | Value |
|---|---|
| k8s Secret | `skirmshop/skirmbooks-ui-secrets` (Opaque, MANUAL, no ownerRef) |
| Keys (5) | `SESSION_SECRET`, `LITELLM_API_KEY`, `SYNAPSE_AMQP_URL`, `TINK_CLIENT_ID`, `TINK_CLIENT_SECRET` |
| Consumer | Deployment `skirmshop/skirmbooks-ui` → `envFrom.secretRef` |
| ClusterSecretStore | `onepassword` (since SC-496; was `vault-backend`) |
| 1Password item (source of truth) | `skirmshop-skirmbooks-ui` (vault `k8s-pocharlies`); item field = former Vault property |
| Argo app | `argocd/skirmbooks`, source path `k8s`, branch `deploy/prod`, syncPolicy `automated{prune:false, selfHeal:true}` |

### GOTCHA (Vault era, proven 2026-06-21 — historical) — ESO Vault role was write-scoped
A PushSecret to `skirmshop/skirmbooks-ui` **failed with HTTP 403** — the
`external-secrets` Vault role could write `secret/skirmshop-drive/*` but **not**
`secret/skirmshop/*`, and could not DELETE anywhere. Therefore:
- **Seeding was break-glass** (`vault kv put` with a privileged token), not a
  GitOps PushSecret. Since SC-496 seeding is the `op` CLI on a signed-in
  session — the same property holds for 1Password: ESO only reads. See
  `seed-ui-secrets-to-1password.sh`.
- **Do NOT** widen the ESO write policy to `skirmshop/*` just to push — that would
  let ESO overwrite the entire skirmshop subtree (incl. the 30+ backend keys in
  `secret/skirmshop/skirmbooks`). Security regression — rejected.
- The **read** of `secret/skirmshop/skirmbooks-ui` IS permitted (tested: not-found,
  no 403). So the ExternalSecret read side works once Vault is seeded.

### GOTCHA (Vault era — historical) — KV mount prefix (project_skirmshop_drive_s3_eso_push)
On **write**: path is `skirmshop/skirmbooks-ui` (no `secret/`).
On **read**: key is `secret/skirmshop/skirmbooks-ui` (with `secret/`).
Same asymmetry as the working `skirmshop-drive` pair.

---

## Manifests (in this repo, `k8s/`)

- `k8s/ui-secrets-external.yaml` — ExternalSecret `skirmbooks-ui-secrets`
  (`creationPolicy: Owner`, `deletionPolicy: Retain`, `dataFrom.extract` of the
  item → publishes ALL fields found in the 1Password item → zero-drop adoption).
- `docs/p1-vault-eso/seed-ui-secrets-to-1password.sh` — seed/verify script:
  reads the live k8s Secret and writes the 1Password item via `op` (values via
  an item JSON template on stdin, never on argv).

`creationPolicy: Owner` makes ESO **adopt** the existing same-named Secret
(patch-in-place, add ownerReference=ExternalSecret); it does not delete+recreate.
`deletionPolicy: Retain` keeps the Secret if the ExternalSecret is ever deleted.

---

## SAFE APPLY PLAN (P1, Vault era — dated historical record; live mechanics: Seed / Rotation / DR below)

> Pre-req: `export KUBECONFIG=$HOME/.kube/config`. Backup of the live secret is at
> `/home/dibanez/k8s/.skirmbooks-ui-secrets.backup.<ts>.yaml` (chmod 600).

**Step 0 — Re-confirm the live baseline (5 keys + per-key sha256):**
```
kubectl -n skirmshop get secret skirmbooks-ui-secrets \
  -o go-template='{{range $k,$v := .data}}{{$k}} {{$v}}{{"\n"}}{{end}}' \
| while read k v; do echo "$k $(printf %s "$v" | base64 -d | sha256sum | cut -c1-16)"; done
```
Expected (recorded 2026-06-21):
```
LITELLM_API_KEY   7185b23ddf950072
SESSION_SECRET    71aeb22a6b085c63
SYNAPSE_AMQP_URL  6c9f36a471d5f97b
TINK_CLIENT_ID    6d055873cb3b27c9
TINK_CLIENT_SECRET 3280d6ccfe423152
```

**Step 1 — Get a Vault break-glass token** (per project_vault_break_glass_eso):
`vault operator generate-root` with Shamir 5/3. It needs write on
`secret/data/skirmshop/*`. Note its accessor for revocation.

**Step 2 — Seed Vault (copies values verbatim; SESSION_SECRET NOT regenerated):**
```
export VAULT_TOKEN=<break-glass>
/home/dibanez/k8s/k8s-skirmbooks-pocharlies/docs/seed-ui-secrets-to-vault.sh
```
The script ends with a verify that all 5 Vault values match the live sha256s.
**Gate:** if it prints `MISMATCH` → STOP, do not continue.

**Step 3 — Independently verify Vault holds the 5 keys (still pre-apply):**
```
/home/dibanez/k8s/k8s-skirmbooks-pocharlies/docs/seed-ui-secrets-to-vault.sh --verify
```
Must print `ALL 5 KEYS MATCH.`

**Step 4 — Apply the ExternalSecret with a pre-apply diff (no surprise to the live secret).**
Apply ONLY the ExternalSecret object (not via Argo yet, to control timing):
```
kubectl apply --dry-run=server -f k8s/ui-secrets-external.yaml   # sanity
kubectl apply -f k8s/ui-secrets-external.yaml
```
ESO reconciles within seconds. Immediately re-hash the secret:
```
kubectl -n skirmshop get secret skirmbooks-ui-secrets \
  -o go-template='{{range $k,$v := .data}}{{$k}} {{$v}}{{"\n"}}{{end}}' \
| while read k v; do echo "$k $(printf %s "$v" | base64 -d | sha256sum | cut -c1-16)"; done
```
**Gate:** the 5 sha256s MUST equal Step 0. Also confirm adoption:
```
kubectl -n skirmshop get secret skirmbooks-ui-secrets \
  -o jsonpath='{.metadata.ownerReferences[0].kind}/{.metadata.ownerReferences[0].name}{"\n"}'
# -> ExternalSecret/skirmbooks-ui-secrets
kubectl -n skirmshop get externalsecret skirmbooks-ui-secrets \
  -o jsonpath='{.status.conditions[0].reason}{"\n"}'   # -> SecretSynced
```

**Step 5 — Do NOT restart the UI to "test".** The running pod already has the env
from the original secret; ESO patched the SAME secret in place with IDENTICAL
values, so a future natural restart is safe. If you want positive proof, roll ONE
pod and watch `/api/health`:
```
kubectl -n skirmshop rollout restart deploy/skirmbooks-ui
kubectl -n skirmshop rollout status deploy/skirmbooks-ui --timeout=120s
```

**Step 6 — Commit + push** the manifest to `deploy/prod` (per Git CI/CD discipline)
so Argo's `selfHeal` keeps the ExternalSecret in sync. (The seed in Vault is NOT
in git — only the ExternalSecret is.) Then `argocd app sync skirmbooks` if needed.

**Step 7 — Revoke the break-glass token:** `vault token revoke -accessor <acc>`.

### Rollback (any gate fails)
The original secret is backed up. Restore the manual secret and remove the ESO
object:
```
kubectl delete externalsecret skirmbooks-ui-secrets -n skirmshop   # Retain -> secret stays
kubectl apply -f /home/dibanez/k8s/.skirmbooks-ui-secrets.backup.<ts>.yaml
```
Because `deletionPolicy: Retain`, deleting the ExternalSecret never deletes the
Secret; the apply just re-asserts the manual values. UI is unaffected throughout
(pod keeps its env; secret is never empty).

---

## Rotation (1Password, since SC-496)

Source of truth: item `skirmshop-skirmbooks-ui` (vault `k8s-pocharlies`).
`op item edit` merges the fields given — it never drops siblings (same rule as
the old `vault kv patch`: never a full replace). For real keys, prefer piping
an item JSON template (`cat item.json | op item edit skirmshop-skirmbooks-ui
--vault k8s-pocharlies`) to keep values off argv, as the seed script does.

### Rotate any non-session key (LITELLM_API_KEY, SYNAPSE_AMQP_URL, TINK_*)
1. `op item edit skirmshop-skirmbooks-ui --vault k8s-pocharlies KEY=<new>`
   (in x86: skill `op-via-mac`).
2. ESO refreshes within `refreshInterval: 6h` (or force:
   `kubectl annotate es skirmbooks-ui-secrets force-sync="$(date +%s)" --overwrite`).
3. Roll the UI to pick up the new env: `kubectl rollout restart deploy/skirmbooks-ui`.

### Rotate SESSION_SECRET (logs everyone out — coordinate with app lane)
SESSION_SECRET is the HMAC root; changing it invalidates all sessions and the
signed `sb_tenant` cookie. **Dual-secret window** (requires app support for a
secondary verification key, e.g. `SESSION_SECRET_PREVIOUS`):
1. Generate new: `openssl rand -hex 32`.
2. `op item edit skirmshop-skirmbooks-ui --vault k8s-pocharlies SESSION_SECRET_PREVIOUS=<current> SESSION_SECRET=<new>`.
3. Add `SESSION_SECRET_PREVIOUS` to the ExternalSecret (extract already pulls all
   fields) and to the app's verifier so old cookies still validate.
4. Roll the UI. Both keys valid during the window.
5. After max cookie TTL, `op item edit skirmshop-skirmbooks-ui --vault k8s-pocharlies SESSION_SECRET_PREVIOUS=` (clear) and
   drop the verifier path; roll again.
If the app has NO dual-key support yet, a hard rotation just forces a global
re-login — acceptable only in a maintenance window. **Coordinate with the backend
lane before rotating SESSION_SECRET.**

---

## DR — reseed in a clean namespace / fresh cluster

Pre-req: the 1Password item `skirmshop-skirmbooks-ui` is present (it is the
source of truth since SC-496), ESO + the `onepassword` ClusterSecretStore
healthy.

1. Ensure namespace exists: `kubectl create ns skirmshop` (idempotent).
2. Apply the ExternalSecret: `kubectl apply -f k8s/ui-secrets-external.yaml`
   (or let Argo sync `deploy/prod`).
3. ESO reads the item and creates the Secret from scratch
   (`creationPolicy: Owner` creates if absent). Verify:
   ```
   kubectl -n skirmshop get secret skirmbooks-ui-secrets \
     -o go-template='{{range $k,$v := .data}}{{$k}}{{"\n"}}{{end}}'   # 5 keys
   kubectl -n skirmshop get es skirmbooks-ui-secrets \
     -o jsonpath='{.status.conditions[0].reason}'                     # SecretSynced
   ```
4. The UI Deployment then starts (envFrom finds all 5 keys).

If the 1Password item was lost, restore it from 1Password's own history /
backup first; if the item is gone but the live secret survives, re-run
`seed-ui-secrets-to-1password.sh` to re-seed from the live secret.

Validation evidence (P1, Vault era, 2026-06-21, throwaway namespaces, live secret never touched):
- **Adoption + full-key publish**: an ExternalSecret `creationPolicy: Owner` +
  `dataFrom.extract: secret/skirmshop/skirmbooks` was applied over a pre-existing
  MANUAL secret of the same name. Result: ownerRef became
  `ExternalSecret/<name>` + label `reconcile.external-secrets.io/managed=true`
  (adopted in place, no recreate); the secret then held all **39** keys from the
  Vault path; the 2 pre-existing sentinel keys were **replaced** (mergePolicy
  Replace). => after seeding, the target == exactly the Vault key set.
- **Implication (the danger this gates against)**: because Replace makes the
  secret == the Vault set, the ExternalSecret MUST only be applied AFTER Vault has
  all 5 keys (Step 3 gate). Applying it against a partial Vault set would DROP the
  missing key(s) and break the UI.
- **Read scope**: a read of `secret/skirmshop/skirmbooks-ui` returned not-found
  (no 403) => the ESO role can read the new subpath.
- **Write scope (why seeding is break-glass)**: a PushSecret to
  `skirmshop/skirmbooks-ui` returned 403; a PushSecret to `skirmshop-drive/*`
  synced — confirming the ESO write policy excludes `skirmshop/*`.
