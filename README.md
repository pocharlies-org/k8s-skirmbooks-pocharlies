# k8s-skirmbooks-pocharlies

GitOps manifests for `skirmbooks-ui`, migrated from the Sauvage Docker container.

- Public host: `skirmbooks.e-dani.com`
- Namespace: `skirmshop`
- Image: `harbor.e-dani.com/homelab/skirmbooks-ui:k8s-20260523-legacy`
- Database: `postgres-shared-rw.databases.svc.cluster.local/skirmbooks`
- Secret: `skirmbooks-ui-secrets` in namespace `skirmshop` for Tink credentials.

The app's legacy Docker database `shared-postgres/gestoria` was dumped and restored into the definitive k8s shared PostgreSQL database `skirmbooks`.

## SSO

La app va detrás de la chain propia `sso-skirmbooks-chain` (ns `keycloak`), con su
oauth2-proxy dedicado (`oauth2-proxy-skirmbooks`) y cookie **host-only**
`_skirmbooks_sso` (sin `cookie_domains`), independiente de `_edani_sso` del
dashboard. Los grupos (`/skirmbooks-users`, `/skirmbooks-admins`) llegan por la
cabecera `X-Auth-Request-Groups`; la app deriva sus roles de ahí y no consulta
Keycloak. El patrón completo está en
[k8s-infra-pocharlies/docs/sso-por-app.md](https://github.com/pocharlies-org/k8s-infra-pocharlies/blob/main/docs/sso-por-app.md).

## Migraciones

Las migraciones de `skirmbooks-gestoria-src` (`migrations/*.sql`, registro en
`public.schema_migrations`) se aplican **en cada sync de la app `skirmbooks`** mediante un
hook PreSync de ArgoCD (`k8s/migrations-presync-hook.yaml`, SKIRM-17, decisión D12 del CTO):
un Job en el ns `skirmshop` que corre `bash scripts/apply-migrations.sh` desde la imagen
`harbor.lan.e-dani.com/homelab/skirmbooks-migrations` — publicada por el `release.yml` de
`skirmbooks-gestoria-src` con el mismo tag que la UI, base psql 17, contiene `migrations/` y
`scripts/` — contra la base `skirmbooks` de `postgres-shared-rw` como superuser
(`shared-postgres-superuser`). El hook corre **antes** de que arranque el pod nuevo: el
esquema siempre va por delante del código. El runner es idempotente (salta lo ya registrado
por filename+hash). No hay clonado de repo ni credencial: las migraciones viajan dentro de
la imagen.

**Consecuencia operativa:** a partir de aquí, CUALQUIER migración mergeada en `main` de
`skirmbooks-gestoria-src` se aplica sola en el siguiente sync de esta app, y un runner que
falle **bloquea el despliegue entero** (el sync no avanza; se ve en ArgoCD como hook Failed
con el log del Job, legible con `kubectl logs -n skirmshop job/skirmbooks-migrations`). Es
deliberado: es competencia del despliegue. El Job no interpreta códigos de salida: 0 =
éxito, cualquier otro = fallo (D11).

**Invariante del tag:** el tag de `skirmbooks-migrations` y el de `skirmbooks-ui` se mueven
en el mismo commit de bump; si se separan, se separan mal. El `release.yml` publica las dos
imágenes con el mismo tag, y el bump en `k8s/manifest.yaml` (UI) y
`k8s/migrations-presync-hook.yaml` (Job) es **un único commit que toca las dos líneas
`image:`**, cada una con su `tag@digest`.

- Ver el log de la última ejecución: `kubectl logs -n skirmshop job/skirmbooks-migrations`
- Re-ejecutar: lanzar un nuevo sync (el hook se recrea con `BeforeHookCreation`).
- Estado del esquema: `kubectl exec -n databases postgres-shared-3 -- psql -U postgres -d skirmbooks -c "select filename, applied_at from public.schema_migrations order by filename desc limit 5"`
