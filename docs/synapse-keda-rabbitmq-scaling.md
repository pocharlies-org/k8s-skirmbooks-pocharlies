# Synapse KEDA RabbitMQ Scaling Runbook

Date: 2026-06-08

## Purpose

Skirmbooks Synapse worker profiles are scaled by KEDA using RabbitMQ queue length from the production Synapse broker on `sauvage`.
Workers consume AMQP through:

- `amqp://...@synapse-rmq.databases.svc.cluster.local:5672/%2Fsynapse`

KEDA must read the same broker through RabbitMQ management HTTP:

- `http://synapse-rmq.databases.svc.cluster.local:15672/%2Fsynapse`

## Live Components

Kubernetes resources in `skirmshop`:

- `Secret/skirmbooks-keda-rabbitmq`: non-sensitive host only, managed in `k8s/backend-keda.yaml`.
- `Secret/skirmbooks-keda-rabbitmq-auth`: live credential secret, not committed. Contains `username` and `password` for RabbitMQ user `synapse_keda_monitor`.
- `TriggerAuthentication/skirmbooks-rabbitmq-http`: points KEDA to the two secrets above.
- 34 `ScaledObject` resources, one per non-legacy worker profile.

RabbitMQ on `sauvage`:

- RabbitMQ container: `shared-rabbitmq`.
- KEDA user: `synapse_keda_monitor` with `monitoring` tag and read-only permissions on `/synapse`.
- Management proxy container: `rabbitmq-management-proxy`.

The proxy is needed because Docker publishes RabbitMQ management on `127.0.0.1:15672`, while Kubernetes reaches `sauvage` via `100.109.183.9`.

Current proxy command:

```bash
docker run -d --name rabbitmq-management-proxy --restart unless-stopped --network host \
  --label synapse.role=rabbitmq-management-proxy \
  alpine/socat:latest -d -d \
  TCP-LISTEN:15672,bind=100.109.183.9,fork,reuseaddr \
  TCP:127.0.0.1:15672
```

## Validation

```bash
kubectl -n skirmshop get hpa
kubectl -n skirmshop get scaledobjects.keda.sh -o json | jq '{total:(.items|length), idleReplicaCount0:[.items[] | select(.spec.idleReplicaCount==0) | .metadata.name], readyFalse:[.items[] | select((.status.conditions[]? | select(.type=="Ready") | .status)!="True") | .metadata.name]}'
kubectl -n skirmshop get deploy -l app.kubernetes.io/part-of=synapse
kubectl -n keda logs deploy/keda-operator --since=5m | grep -E 'ERROR|Client.Timeout|401|403|404|shared-rabbitmq' || true
ssh sauvage 'docker ps --filter name=rabbitmq-management-proxy; docker logs --tail 40 rabbitmq-management-proxy'
```

Expected state:

- HPAs show `0/<threshold>` rather than `<unknown>`.
- Batch worker profiles that opted into scale-to-zero sit at `REPLICAS=0` while idle
  and are woken by KEDA from the queue (see "Scale-to-zero" below). Every other
  non-legacy profile keeps `REPLICAS=1`.
- `idleReplicaCount0` is empty — scale-to-zero uses `minReplicaCount: 0`, not
  `idleReplicaCount`.
- KEDA operator has no fresh RabbitMQ errors.

## Rollback

To stop KEDA scaling without stopping workers:

```bash
kubectl -n skirmshop delete scaledobjects.keda.sh -l app.kubernetes.io/part-of=synapse
kubectl -n skirmshop get deploy -l app.kubernetes.io/part-of=synapse -o name | xargs -r kubectl -n skirmshop scale --replicas=1
```

To remove the management proxy:

```bash
ssh sauvage 'docker rm -f rabbitmq-management-proxy'
```

Do not remove the proxy while KEDA RabbitMQ ScaledObjects are active; HPAs will lose external metrics.

## Gotchas

- Scale-to-zero is allowed ONLY for batch profiles, and via `minReplicaCount: 0` —
  never `idleReplicaCount: 0`. Interactive profiles (invoicing-ocr,
  banking-classifier, fiscal-classifier, identity-core) and the two with real load
  (accounting-derived, banking-reconcile) keep one executor warm: a user is waiting
  on them and a cold start is visible.
- It is safe because the `adapter.*` queues survive having zero consumers — verified
  on the live broker: `durable=true`, `auto_delete=false`, NO `x-expires`,
  `x-message-ttl=604800000` (7 days), `x-max-length=100000`, `x-queue-mode=lazy`,
  dead-lettering to `dlx`. KEDA reads the queue over the management API, so it sees
  the backlog with no consumer attached and scales 0 -> 1. If a queue is ever
  redeclared WITH `x-expires`, scale-to-zero on it becomes unsafe: the queue would
  vanish while idle, KEDA's regex would match nothing, and the work would be dropped
  in silence.
- A profile that scales to zero needs `activationQueueLength` set explicitly (1 for
  batch) and a `cooldownPeriod` short enough to matter — the historical 21600 (6 h)
  means it would never actually reach zero.
- KEDA points at `synapse-rmq`, which is a HEADLESS ALIAS for the same cluster as
  `shared-rabbitmq` (both resolve to shared-rabbitmq-0/1/2 in ns `databases`) —
  verified 2026-08-04. They are not two brokers. There is no separate `sauvage`
  broker any more.
- Single-action queue triggers should also use `useRegex: "true"` and exact regex queue names. This avoids RabbitMQ exact queue endpoint mismatches and keeps behavior consistent across single and multi-action profiles.
- **The DLQ prefix in this vhost is `dlq.`, NOT `dead.`.** A check written against
  `dead.adapter.*` matches nothing and reports a clean DLQ no matter what is in it.
  This produced a false "nothing was dead-lettered" reading during the 2026-08-04
  verification. Use `rabbitmqctl list_queues -p /synapse name messages | grep '^dlq\.'`.
- **A worker's queue name is not derivable from its Deployment name.**
  `skirmbooks-shopify-sii-bridge-poll` consumes `adapter.sii_emitted.invoice.poll`,
  not `adapter.shopify_sii_bridge.*`. Read `spec.triggers[0].metadata.queueName` off
  the ScaledObject; publishing to a guessed name returns "published but NOT routed"
  and the message is silently dropped (the default exchange has no alternate-exchange).
- To confirm a profile can wake from zero without running real business work, publish
  `{"__keda_probe__":true}` to its queue. The worker wakes, finds the envelope malformed,
  dead-letters it to that queue's `dlq.` and stays up. Purge the probe afterwards —
  verify it is yours (`count=1`, payload contains `__keda_probe__`) before `purge_queue`.
  Measured: 0 -> 1 and consumed in **46-89 s** for 7 profiles published concurrently,
  62-166 s for 9 (that spread was image-pull contention, not latency — see the cold-start
  breakdown below).
  **This is only safe from `unify-20260805-2` onward.** In `unify-20260805` exactly, the
  vendored `synapse-shared` did `command["workflow_instance_id"]` unguarded in
  `adapter.py::_dispatch`, so the probe raised `KeyError` and **killed the whole adapter
  process** (exit 1, container restart) instead of dead-lettering one message — on a
  profile at `minReplicaCount: 1` the redelivered message could have crash-looped it.
  Upstream had fixed this in synapse `b0fe996e` on 10 July, but `release.yml` vendors
  synapse-shared with `cp -rn` so as not to clobber this repo's committed queue-split
  patches, and `adapter.py` is one of those — upstream fixes to it never arrive. It was
  ported by hand into `_vendor/synapse-shared` (skirmbooks-gestoria-src `881f663`).
  Verified after the rebuild: same payload, message dead-lettered, **pod restarts 0**.
  If you ever bump `synapse_ref`, re-check the patched files under `_vendor/` by hand;
  the vendoring will not do it for you.
- **Cold start, broken down** (single worker, measured 2026-08-05): up to **60 s** is
  just `pollingInterval` — KEDA only looks at the queue every 60 s. A further **~43 s**
  is pulling the 583 MB image when the node does not have it cached. The application
  itself takes **~6 s** from pod start to consuming. So a warm node costs ~52 s end to
  end and a cold one ~109 s. Do not lower `pollingInterval` to chase this: 60 is the
  value that fixed the scaler timeouts, and these are batch profiles by construction —
  nobody is waiting.

## Verification script for a scale-to-zero profile

Six points, in order, with command output kept:

1. **Reaches 0**: `kubectl -n skirmshop get deploy skirmbooks-<w>` shows `0/0` after
   the cooldown.
2. **The queue survives with no consumer**: `list_queues name durable auto_delete
   consumers messages` shows `durable=true auto_delete=false consumers=0`.
3. **Wakes up**: the probe above; record the cold-start time.
4. **Sleeps again** after `cooldownPeriod`.
5. **Nothing lost**: `messages_unacknowledged=0`, `dlq.` (see prefix gotcha above) with
   no unexpected entries, `synapse.unroutable` flat.
6. **No scaler errors**: `kubectl -n keda logs deploy/keda-operator --since=25m`.

A cheaper per-profile pre-check that needs no publish at all:
`kubectl -n skirmshop get scaledobject keda-skirmbooks-<w> -o json` — `Ready=True`
with `Active=False(ScalerNotActive)` means KEDA is successfully reading that queue and
it is genuinely empty. `Ready=False`, or a metric of `<unknown>`, means the metrics
path is broken and `minReplicaCount: 0` on that profile would deadlock.
