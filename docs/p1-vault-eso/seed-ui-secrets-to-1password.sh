#!/usr/bin/env bash
# =============================================================================
# seed-ui-secrets-to-1password.sh — seed/verify the 1Password item
#   skirmshop-skirmbooks-ui (vault k8s-pocharlies) from the live k8s Secret
#   `skirmshop/skirmbooks-ui-secrets` (5 keys: SESSION_SECRET + 4).
# -----------------------------------------------------------------------------
# SC-496: the ExternalSecret k8s/ui-secrets-external.yaml now reads the item
# from ClusterSecretStore/onepassword (item field = former Vault property).
# This script replaces seed-ui-secrets-to-vault.sh (Vault era, break-glass
# token). Seeding is the op CLI on a signed-in session — the cluster has no
# write path to 1Password (ESO only reads), the same property that made Vault
# seeding break-glass instead of GitOps (ESO 403 on secret/skirmshop/*,
# proven 2026-06-21).
#
# LEAK-SAFETY
#   - Values reach `op` as an item JSON template on STDIN, never on argv
#     (1Password CLI docs: "Command arguments can be visible to other
#     processes on your machine" — "To edit sensitive values, use an item
#     JSON template instead").
#   - On edit, the template is the item's own JSON with the 5 field values
#     replaced, so fields added later (e.g. SESSION_SECRET_PREVIOUS during a
#     rotation window) are never dropped.
#   - SESSION_SECRET is COPIED verbatim — never regenerated — so no active
#     session/cookie is invalidated.
#
# REQUIREMENTS
#   - kubectl (KUBECONFIG=$HOME/.kube/config) with read on the live secret.
#   - jq.
#   - A signed-in 1Password session with write on vault `k8s-pocharlies`
#     (on x86: skill op-via-mac; on the Mac: eval $(op signin)).
#
# USAGE
#   export KUBECONFIG=$HOME/.kube/config
#   ./seed-ui-secrets-to-1password.sh           # seeds (create or edit) + verifies
#   ./seed-ui-secrets-to-1password.sh --verify  # verify only (item vs live)
# =============================================================================
set -euo pipefail

NS=skirmshop
SRC_SECRET=skirmbooks-ui-secrets
OP_VAULT=k8s-pocharlies
ITEM=skirmshop-skirmbooks-ui
KEYS=(SESSION_SECRET LITELLM_API_KEY SYNAPSE_AMQP_URL TINK_CLIENT_ID TINK_CLIENT_SECRET)

: "${KUBECONFIG:=$HOME/.kube/config}"; export KUBECONFIG

die() { echo "ERROR: $*" >&2; exit 1; }
command -v op >/dev/null 2>&1 || die "op CLI not found (on x86: skill op-via-mac)"
op whoami >/dev/null 2>&1 || die "no 1Password session (eval \$(op signin))"
command -v jq >/dev/null 2>&1 || die "jq not found"

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
  echo "== verify: 1Password item $ITEM vs live $NS/$SRC_SECRET =="
  local ok=1 v isha
  for k in "${KEYS[@]}"; do
    # command substitution strips the trailing newline op read appends, so the
    # sha256 is over the bare value (same assumption as the live fingerprints).
    v=$(op read "op://$OP_VAULT/$ITEM/$k" 2>/dev/null) || v=""
    if [ -z "$v" ]; then
      isha="<read-failed>"
    else
      isha=$(printf '%s' "$v" | sha256sum | cut -d' ' -f1)
    fi
    if [ "$isha" = "${LIVE_SHA[$k]}" ]; then
      echo "  [OK]   $k  sha256:${isha:0:16}"
    else
      echo "  [FAIL] $k  live:${LIVE_SHA[$k]:0:16}  item:${isha:0:16}"
      ok=0
    fi
  done
  [ "$ok" = 1 ] && echo "ALL 5 KEYS MATCH." || { echo "MISMATCH — do NOT apply the ExternalSecret."; return 1; }
}

if [ "${1:-}" = "--verify" ]; then verify; exit $?; fi

# --- 3. export values as env vars (off argv) and build the JSON template -----
#     $ENV lookups keep every value out of the jq/op argv.
export OP_ITEM="$ITEM"
for k in "${KEYS[@]}"; do export "$k=${VAL[$k]}"; done

if op item get "$ITEM" --vault "$OP_VAULT" >/dev/null 2>&1; then
  # edit: round-trip the item's own JSON, replacing/adding only the 5 fields —
  # any other field (e.g. SESSION_SECRET_PREVIOUS) is preserved verbatim.
  echo "== editing item $ITEM in vault $OP_VAULT (5 fields; values via stdin, not argv) =="
  TEMPLATE=$(op item get "$ITEM" --vault "$OP_VAULT" --format json | jq '
    def setf(k):
      if (map(.label == k) | any)
      then map(if .label == k then .value = env[k] else . end)
      else . + [{id: k, label: k, type: "CONCEALED", value: env[k]}] end;
    .fields |= (reduce ["SESSION_SECRET","LITELLM_API_KEY","SYNAPSE_AMQP_URL",
                        "TINK_CLIENT_ID","TINK_CLIENT_SECRET"][] as $k (.; setf($k)))')
  printf '%s' "$TEMPLATE" | op item edit "$ITEM" --vault "$OP_VAULT"
else
  echo "== creating item $ITEM in vault $OP_VAULT (values via stdin, not argv) =="
  TEMPLATE=$(jq -n '{
      title: env.OP_ITEM,
      fields: ["SESSION_SECRET","LITELLM_API_KEY","SYNAPSE_AMQP_URL",
               "TINK_CLIENT_ID","TINK_CLIENT_SECRET"]
              | map({id: ., label: ., type: "CONCEALED", value: env[.]})
    }')
  printf '%s' "$TEMPLATE" | op item create --vault "$OP_VAULT" -
fi

echo
verify
echo
echo "NEXT: apply k8s/ui-secrets-external.yaml (see ui-secrets-vault-runbook.md)."
