# skirmbooks-billing — Deploy plan & runbook (modo TEST, claves pendientes)

> DevOps lane (harness RHO). Manifests preparados, **NO aplicados / NO commiteados**.
> El servicio billing (FastAPI/uvicorn, `services/billing` en la lane backend) AÚN
> NO existe en CI → la imagen es un placeholder. Este doc es el runbook de
> activación (orden de pasos + break-glass) cuando llegue el código y las claves.

## Manifests (este repo, `k8s/`)
| Archivo | Objeto | Estado |
|---|---|---|
| `k8s/billing-deployment.yaml` | Deployment + Service `skirmbooks-billing` (ns `skirmshop`) | dry-run server OK; imagen=PLACEHOLDER |
| `k8s/billing-secrets-external.yaml` | ExternalSecret `skirmbooks-billing-secrets` ← Vault | dry-run server OK; path Vault NO existe aún |
| `k8s/billing-webhook-ingress.yaml` | IngressRoute público SOLO `/billing/webhook` (traefik-edge) | dry-run server OK |

Contrato HTTP del servicio (lane backend): `GET /healthz`, `POST /billing/checkout`,
`POST /billing/webhook`, puerto **8590**. DNS interno:
`skirmbooks-billing.skirmshop.svc.cluster.local:8590`.

## 1. Role + credencial DB (`gestoria_billing_app`)
**Evidencia:** la migración `0054_billing.sql` (worktree) crea el role en-DB:
```sql
CREATE ROLE gestoria_billing_app LOGIN;   -- línea 53, SIN password
GRANT USAGE, CREATE ON SCHEMA gestoria_billing TO gestoria_billing_app;
GRANT USAGE ON SCHEMA gestoria_identity   TO gestoria_billing_app;
```
El role queda `LOGIN` pero **sin password** → no puede autenticar hasta sembrarlo.
Aislamiento (§6 diseño): NO tiene GRANT sobre `gestoria_banking` → cumple la
separación de dominios. NO reutilizar `shared-postgres-app` (credencial general de
la UI) para billing.

**CNPG declarative roles:** el cluster `databases/postgres-shared` gestiona roles
vía `spec.managed.roles` pero esa spec vive en OTRO repo
(`argocd tracking-id postgres-shared:...:databases/postgres-shared`), NO en este.
Como 0054 YA crea el role en-DB, la vía mínima y coherente con el patrón de seed de
claves es break-glass `ALTER ROLE ... PASSWORD`, no editar la cluster spec.

**Pasos (break-glass, primary `postgres-shared-3`):**
1. Aplicar 0054 contra la DB `skirmbooks` (lo hace la lane backend / migración):
   verifica el role:
   ```sh
   kubectl -n databases exec -ti postgres-shared-3 -- \
     psql -d skirmbooks -c "\du gestoria_billing_app"
   ```
2. Generar password fuerte y setearlo (break-glass, no GitOps):
   ```sh
   PW=$(openssl rand -base64 32 | tr -d '/+=' | head -c 40)
   kubectl -n databases exec -ti postgres-shared-3 -- \
     psql -d skirmbooks -c "ALTER ROLE gestoria_billing_app PASSWORD '$PW';"
   ```
3. Componer el DSN y meterlo en el Vault path de billing (paso 2 de §2):
   `postgresql://gestoria_billing_app:$PW@postgres-shared-rw.databases.svc.cluster.local:5432/skirmbooks`
   (clave `GESTORIA_DB_URL` del secret de billing).

> Durabilidad opcional (recomendado tras validar): añadir `gestoria_billing_app` al
> `spec.managed.roles` del repo `postgres-shared` con `passwordSecret` apuntando a un
> Secret k8s, para que CNPG lo reconcilie declarativamente. Coordinar con el owner de
> ese repo. No bloquea el modo test.

## 2. Sembrar claves Stripe (break-glass Vault → ESO)
Path: `secret/skirmshop/skirmbooks-billing` (KV v2). El role ESO `vault-backend`
puede LEERLO pero NO escribirlo (403, probado) → el seed es break-glass con un token
con write, igual que `secret/skirmshop/skirmbooks-ui` (project_vault_break_glass_eso).

Claves a sembrar (cuenta Stripe **SaaS**, modo **test** — DISTINTAS del Stripe bancario):
```sh
vault kv put secret/skirmshop/skirmbooks-billing \
  STRIPE_SECRET_KEY="sk_test_..." \
  STRIPE_PUBLISHABLE_KEY="pk_test_..." \
  STRIPE_WEBHOOK_SIGNING_SECRET="whsec_..." \
  STRIPE_PRICE_TRIAL="price_..." \
  STRIPE_PRICE_STARTER="price_..." \
  STRIPE_PRICE_STANDARD="price_..." \
  STRIPE_PRICE_PRO="price_..." \
  GESTORIA_DB_URL="postgresql://gestoria_billing_app:<pw>@postgres-shared-rw.databases.svc.cluster.local:5432/skirmbooks"
```
Tras sembrar, forzar reconcile del ES y reiniciar el pod (envFrom se lee al
arrancar el contenedor):
```sh
kubectl -n skirmshop annotate externalsecret skirmbooks-billing-secrets \
  force-sync=$(date +%s) --overwrite
kubectl -n skirmshop rollout restart deploy/skirmbooks-billing
```

## 3. Webhook público (análisis del ingress)
- **traefik-lan** (LB 192.168.50.240): solo LAN/Tailscale (`*.lan.e-dani.com`). NO internet.
- **traefik-edge** (ns `traefik-edge`, `ingressClassName=traefik-edge`): INTERNET-facing,
  sirve `sauvage.e-dani.com`, `track.skirmshop.es`, `harbor.e-dani.com`, etc.
- Patrón probado: `skirmshop/back-in-stock-public` y `skirmshop/skirmshop-labels-track-public`
  son IngressRoutes EN ns `skirmshop` con `ingressClassName: traefik-edge` → ruta pública
  sin tunnel extra. **No hace falta Cloudflare tunnel ni dominio nuevo: ya hay entrypoint público.**
- `skirmbooks.e-dani.com` ya resuelve público pero gated por `keycloak/sso-chain`
  (`edge-other-legacy-proxies` → skirmbooks-ui). Stripe NO pasa SSO → el manifest
  añade una regla del MISMO host con `PathPrefix(/billing/webhook)`, `priority: 10000`
  (gana al catch-all), SIN sso-chain, → `skirmbooks-billing:8590`. Solo el webhook
  queda público sin auth; el resto del host sigue en la UI SSO.
- AUTHZ del webhook = firma Stripe (HMAC, raw body, tol 5min) en el servicio, no el ingress.

**Alternativa host dedicado** (si se prefiere no compartir host con la UI SSO):
crear DNS público `billing.skirmshop.es` (o `.e-dani.com`) → IP edge, y cambiar el
`match` a `Host(billing.skirmshop.es) && PathPrefix(/billing/webhook)`. El cert lo
cubre el ACME wildcard del store default de traefik-edge (`*.skirmshop.es`/`*.e-dani.com`),
sin cert manual. Requiere 1 registro DNS nuevo.

## 4. Build / CI
La imagen del billing NO se construye hoy (no hay `services/billing`). Cuando la lane
backend lo cree, añadir un job `billing` a `.github/workflows/release.yml` (repo del
worktree), gemelo del job `ui` pero con `services/billing/Dockerfile`:
```yaml
  billing:
    name: Build & push skirmbooks-billing
    if: ${{ inputs.build_billing }}      # nuevo input boolean, default false
    runs-on: arc-k8s
    timeout-minutes: 30
    steps:
      - uses: actions/checkout@v4
      - uses: docker/login-action@v3
        with:
          registry: ${{ env.REGISTRY }}            # harbor.lan.e-dani.com
          username: ${{ secrets.HARBOR_USER }}
          password: ${{ secrets.HARBOR_PASSWORD }}
      - name: Build & push billing
        run: |
          set -euo pipefail
          base="${REGISTRY}/homelab/skirmbooks-billing"
          docker build --network=host \
            --tag "${base}:${{ inputs.version }}" \
            --tag "${base}:sha-${GITHUB_SHA::12}" \
            --label "org.opencontainers.image.revision=${GITHUB_SHA}" \
            -f services/billing/Dockerfile services/billing
          for ref in "${base}:${{ inputs.version }}" "${base}:sha-${GITHUB_SHA::12}"; do
            for a in 1 2 3 4 5; do docker push "$ref" && break || sleep $((a*5)); done
          done
          docker inspect --format '{{ index .RepoDigests 0 }}' "${base}:${{ inputs.version }}"
```
- **Registry:** `harbor.lan.e-dani.com/homelab/skirmbooks-billing` (no `harbor.e-dani.com`):
  el CI runner es in-cluster y pushea a `harbor.lan` para evitar el 413 del proxy externo
  (env REGISTRY del workflow). El `nodeSelector role=edge` puede tirar de `harbor.lan` (mismo
  patrón que skirmbooks-ui). Coordinar el nombre exacto con la lane backend.
- Tras build, copiar el digest impreso al `image:` de `billing-deployment.yaml`
  (pin por @sha256, política del repo) y commitear ese bump (deploy = ArgoCD sync).

## Orden de activación (cuando llegue código + claves)
1. Lane backend: `services/billing` + Dockerfile + fail-safe 503 sin claves.
2. CI: job `billing` → imagen en harbor.lan, anotar digest.
3. Aplicar 0054 a DB `skirmbooks`; setear password del role (break-glass).
4. Sembrar `secret/skirmshop/skirmbooks-billing` (claves test + GESTORIA_DB_URL).
5. Bump `image:` con digest; aplicar los 3 manifests (vía ArgoCD).
6. Crear el endpoint webhook en el dashboard Stripe SaaS apuntando a
   `https://skirmbooks.e-dani.com/billing/webhook`; el `whsec_*` que da Stripe va al
   Vault path (paso 4) → rollout restart.
7. Smoke: `GET /healthz`=200; webhook test desde Stripe CLI → firma verificada.

## Riesgos / blockers operativos residuales
- **[blocker] imagen inexistente**: no hay `services/billing` ni Dockerfile → no se
  puede construir ni desplegar hoy. El manifest lleva tag placeholder.
- **[blocker] path Vault vacío**: `secret/skirmshop/skirmbooks-billing` no existe →
  el ES queda NotReady hasta el seed break-glass del usuario (esperado). El pod
  arranca igual (`secretRef optional: true`).
- **[blocker] password del role**: `gestoria_billing_app` sin password hasta el
  ALTER ROLE break-glass; el DSN no autentica hasta entonces.
- **[dependencia] 0054 aplicada**: confirmar que la migración corrió contra la DB
  `skirmbooks` del primary `postgres-shared-3` (la lane backend / migración lo hace).
- **CNPG declarative roles** en repo aparte (`postgres-shared`): durabilidad del role
  fuera de este repo. No bloquea test.
