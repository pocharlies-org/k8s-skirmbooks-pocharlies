# ARCHITECTURE.md — k8s-skirmbooks-pocharlies

> Manifiestos GitOps de **Skirmbooks** (contabilidad/gestoría de Skirmshop): UI, backend, workers de banca/facturas/clasificación,
> CronJobs, KEDA y navegador AEAT. Solo manifiestos (35 ficheros en `k8s/`); el código vive en `skirmbooks-gestoria-src`.
> Escrito por `architect` (SC-1426).

## 1. Clientes y versiones

| cliente | repositorio / ruta | versión desplegada | cómo se despliega |
|---|---|---|---|
| `skirmbooks-ui` (host `skirmbooks.e-dani.com`) | `k8s/` | `extractos-psd2-20261007` (`@sha256:1df0fff0…`; migraciones PreSync con el mismo tag, D12) | ArgoCD app `skirmbooks` |
| Backend y workers (`skirmbooks-backend`, banca, facturas, clasificador, deh/dehu, aeat-browser) | `backend-deployments.yaml`, `banking-*`, `classifier-*`… | **mezcla de tags**: `ingest-event-20261003-3` (todo el adapter invoicing: deployments fast/ocr/classify/posting/issued + `patterns-cron.yaml`), `audit-ocr-20260807` (demás, ~45 usos), `casillas-12-13-20260814`, `guard-ocr-isp-doctype-20260818` (accounting-derived), `dehu-20260923-2` | ídem |
| CronJobs (accounting-sweep, banking-daily-sync, klarna, paypal, cobros/facturas digest, deh-poll…) | `k8s/*-cron.yaml` | mismas imágenes | ídem |

Clientes del producto: web (UI) y el MCP/tools de Skirmbooks vía `/skirmshop-plugins` del AgentGateway (`skirmbooks_reconcile_*`).

## 2. Dependencias, en ambos sentidos

- **Depende de** — Postgres compartido (`postgres-shared-rw.databases`, bd `skirmbooks`), RabbitMQ de Synapse (KEDA `backend-keda.yaml`,
  `classifier-keda.yaml`; ver `docs/synapse-keda-rabbitmq-scaling.md`), Tink (banca), AEAT/DEHú, 1Password/ExternalSecrets
  (`backend-secrets.yaml`, `skirmbooks-ui-secrets`), SSO por app: chain `sso-skirmbooks-chain` + `oauth2-proxy-skirmbooks` (ns `keycloak`;
  `k8s-infra-pocharlies/docs/sso-por-app.md`).
- **Dependen de él** — gestoría/contabilidad de Skirmshop, Synapse (eventos), el tool `skirmbooks_reconcile_upload_invoice` del gateway.
  Migraciones SQL en `skirmbooks-gestoria-src` (`migrations/*.sql`).
- **ArgoCD** `skirmbooks`: repo `pocharlies-org/k8s-skirmbooks-pocharlies`, path `k8s`, tronco **`main`** (`origin/main` = d7a5bf3), sync automático.

## 3. Stack

| pieza | versión | para qué | no se usa en su lugar |
|---|---|---|---|
| Kustomize (directorio plano) | — | render | Helm |
| KEDA ScaledObjects | — | autoescala por cola | HPA por CPU |
| Imágenes `skirmbooks-backend` / `skirmbooks-ui` (código en otro repo) | ver §1 | app | — |

## 4. Componentes compartidos

| concepto | pieza canónica | ruta | quién la usa |
|---|---|---|---|
| Entry points de digest (`synapse_adapter_banking.facturas_digest` / `cobros_digest`) | CronJobs digest-only | `k8s/facturas-cron.yaml`, `cobros-digest-cron.yaml` | este repo (comentarios: tag y digest se bumpean juntos) |
| Secretos de UI | `docs/p1-vault-eso/` | ídem | UI |
| Billing | `docs/p4-billing/` | ídem | plan de facturación (no aplicado) |

## 5. Cómo se construye aquí

Un worker/cron nuevo = manifiesto en `k8s/` con la misma imagen de backend y su `command` de módulo Python. Un bump de imagen debe
actualizar **todos** los manifiestos que la comparten (los comentarios del repo avisan de que «si se separan, se separan mal»).

## 6. Tests y validaciones

Sin tests propios. `kustomize build k8s` por el CI estándar. Los tests del código están en `skirmbooks-gestoria-src`.

## 7. CI/CD y despliegue

- `ci.yml` → `reusable-ci.yml@ac96743b…`; `pr-review.yml`. Sin `release.yml` (imágenes en el repo de código).
- Despliegue: merge a `main` → ArgoCD. **Validación en producción**: UI tras SSO, `skirmbooks_reconcile_summary` por el gateway, último
  Job de cada CronJob `Complete`, colas KEDA vacías. Synced ≠ funcionando. Pendiente de ejecutar.

## 8. Decisiones y trampas

- `2026-05-23` · migrado desde Docker en sauvage (`shared-postgres/gestoria` → `skirmbooks`).
- Cinco tags de imagen conviviendo: hay deriva entre workers; confirmar cuál debe ser el tag único.
- SSO propio con cookie host-only `_skirmbooks_sso` (independiente de `_edani_sso`); los roles salen de `X-Auth-Request-Groups`.
- Comentario del propio repo: un digest-only de `facturas_digest` NO es `facturas_daily`; no cambiar el entrypoint por error.

Última verificación contra el código: 2026-10-01 · d7a5bf3 (origin/main)
