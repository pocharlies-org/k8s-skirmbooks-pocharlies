#!/usr/bin/env bash
# =============================================================================
# seed-ui-secrets-to-vault.sh  —  Phase P1 of skirmbooks SESSION_SECRET → Vault
# -----------------------------------------------------------------------------
# Seeds the 5 keys currently living in the MANUAL k8s Secret
# `skirmshop/skirmbooks-ui-secrets` UP into Vault KV v2 at
#   secret/skirmshop/skirmbooks-ui   (read by the ExternalSecret of the same name)
#
# WHY a break-glass script and NOT an ESO PushSecret?
#   PROVEN 2026-06-21 (DevOps lane): the ESO Vault role (k8s auth role
#   `external-secrets`) is path-scoped. It can WRITE to `secret/skirmshop-drive/*`
#   but a write to `secret/metadata/skirmshop/*` returns HTTP 403 permission
#   denied (and it cannot DELETE anywhere). So a PushSecret targeting
#   `skirmshop/skirmbooks-ui` will NEVER sync. The backend bundle
#   `secret/skirmshop/skirmbooks` was likewise seeded by a privileged token, not
#   by ESO. Widening the ESO write policy to `skirmshop/*` just to push would let
#   ESO overwrite the whole skirmshop subtree (incl. the 30+ backend keys) — a
#   security regression we explicitly reject.
#
# The READ side IS allowed: an ExternalSecret reading
# `secret/skirmshop/skirmbooks-ui` was tested and got not-found (no 403), i.e.
# the read policy already covers the new subpath. Once this script seeds Vault,
# ui-secrets-external.yaml will materialise the secret cleanly.
#
# LEAK-SAFETY
#   - Values are passed to `vault kv put` via STDIN JSON (`put ... -`), never on
#     argv, so they don't appear in `ps`/audit argv.
#   - Plaintext only ever lives in this shell's memory + the vault-0 stdin pipe.
#   - SESSION_SECRET is COPIED verbatim — never regenerated — so no active
#     session/cookie is invalidated.
#
# REQUIREMENTS
#   - kubectl (KUBECONFIG=$HOME/.kube/config) with read on the live secret.
#   - A Vault break-glass token with write on secret/data/skirmshop/* exported as
#     VAULT_TOKEN (obtain via `vault operator generate-root` Shamir 5/3 per
#     project_vault_break_glass_eso, then REVOKE it after). Do NOT use the ESO role.
#
# USAGE
#   export KUBECONFIG=$HOME/.kube/config
#   export VAULT_TOKEN=<break-glass-token>
#   ./seed-ui-secrets-to-vault.sh           # seeds + verifies
#   ./seed-ui-secrets-to-vault.sh --verify  # verify only (compares Vault vs live)
# =============================================================================
set -euo pipefail

NS=skirmshop
SRC_SECRET=skirmbooks-ui-secrets
VAULT_NS=vault
VAULT_POD=vault-0
VAULT_MOUNT=secret
VAULT_PATH=skirmshop/skirmbooks-ui
KEYS=(SESSION_SECRET LITELLM_API_KEY SYNAPSE_AMQP_URL TINK_CLIENT_ID TINK_CLIENT_SECRET)

: "${KUBECONFIG:=$HOME/.kube/config}"; export KUBECONFIG

die() { echo "ERROR: $*" >&2; exit 1; }
[ -n "${VAULT_TOKEN:-}" ] || die "export VAULT_TOKEN (break-glass token with write on secret/data/skirmshop/*)"

# --- 1. read the 5 live values (decoded) into an associative array -----------
declare -A VAL
for k in "${KEYS[@]}"; do
  b64=$(kubectl -n "$NS" get secret "$SRC_SECRET" -o "jsonpath={.data.$k}" 2>/dev/null) \
    || die "cannot read $SRC_SECRET"
  [ -n "$b64" ] || die "key $k missing/empty in live secret — refusing to seed a partial set"
  VAL["$k"]=$(printf '%s' "$b64" | base64 -d)
done

# --- 2. compute live fingerprints (for the verify step) ---------------------
declare -A LIVE_SHA
for k in "${KEYS[@]}"; do
  LIVE_SHA["$k"]=$(printf '%s' "${VAL[$k]}" | sha256sum | cut -d' ' -f1)
done

verify() {
  echo "== verify: Vault $VAULT_MOUNT/$VAULT_PATH vs live $NS/$SRC_SECRET =="
  local ok=1
  # pull each key out of Vault as raw field, sha256, compare
  for k in "${KEYS[@]}"; do
    vsha=$(kubectl -n "$VAULT_NS" exec -i "$VAULT_POD" -- env VAULT_TOKEN="$VAULT_TOKEN" \
            sh -c "vault kv get -mount=$VAULT_MOUNT -field=$k $VAULT_PATH" 2>/dev/null \
          | sha256sum | cut -d' ' -f1) || vsha="<read-failed>"
    if [ "$vsha" = "${LIVE_SHA[$k]}" ]; then
      echo "  [OK]   $k  sha256:${vsha:0:16}"
    else
      echo "  [FAIL] $k  live:${LIVE_SHA[$k]:0:16}  vault:${vsha:0:16}"
      ok=0
    fi
  done
  [ "$ok" = 1 ] && echo "ALL 5 KEYS MATCH." || { echo "MISMATCH — do NOT apply the ExternalSecret."; return 1; }
}

if [ "${1:-}" = "--verify" ]; then verify; exit $?; fi

# --- 3. build a single JSON object and pipe to `vault kv put ... -` ----------
#     (jq -n keeps values off argv; vault reads the doc from stdin)
JSON=$(jq -n \
  --arg SESSION_SECRET    "${VAL[SESSION_SECRET]}" \
  --arg LITELLM_API_KEY   "${VAL[LITELLM_API_KEY]}" \
  --arg SYNAPSE_AMQP_URL  "${VAL[SYNAPSE_AMQP_URL]}" \
  --arg TINK_CLIENT_ID    "${VAL[TINK_CLIENT_ID]}" \
  --arg TINK_CLIENT_SECRET "${VAL[TINK_CLIENT_SECRET]}" \
  '{SESSION_SECRET:$SESSION_SECRET, LITELLM_API_KEY:$LITELLM_API_KEY, SYNAPSE_AMQP_URL:$SYNAPSE_AMQP_URL, TINK_CLIENT_ID:$TINK_CLIENT_ID, TINK_CLIENT_SECRET:$TINK_CLIENT_SECRET}')

echo "== seeding Vault $VAULT_MOUNT/$VAULT_PATH with 5 keys (values via stdin, not argv) =="
printf '%s' "$JSON" | kubectl -n "$VAULT_NS" exec -i "$VAULT_POD" -- \
  env VAULT_TOKEN="$VAULT_TOKEN" sh -c "vault kv put -mount=$VAULT_MOUNT $VAULT_PATH -" \
  || die "vault kv put failed (check break-glass token has write on secret/data/$VAULT_PATH)"

echo
verify
echo
echo "NEXT: apply k8s/ui-secrets-external.yaml (see ../docs/ui-secrets-vault-runbook.md step 4)."
echo "THEN: REVOKE the break-glass token:  vault token revoke <token-accessor>"
