# k8s-skirmbooks-pocharlies

GitOps manifests for `skirmbooks-ui`, migrated from the Sauvage Docker container.

- Public host: `skirmbooks.e-dani.com`
- Namespace: `skirmshop`
- Image: `harbor.e-dani.com/homelab/skirmbooks-ui:k8s-20260523-legacy`
- Database: `postgres-shared-rw.databases.svc.cluster.local/skirmbooks`
- Secret: `skirmbooks-ui-secrets` in namespace `skirmshop` for Tink credentials.

The app's legacy Docker database `shared-postgres/gestoria` was dumped and restored into the definitive k8s shared PostgreSQL database `skirmbooks`.

## Migraciones

Las migraciones de `skirmbooks-gestoria-src` (`migrations/*.sql`, registro en
`public.schema_migrations`) se aplican **en cada sync de la app `skirmbooks`** mediante un
hook PreSync de ArgoCD (`k8s/migrations-presync-hook.yaml`, SKIRM-17): un Job en el ns
`skirmshop` que clona `main` del repo de código (initContainer `alpine/git`, token de solo
lectura publicado por `k8s/git-token-external.yaml` desde 1Password) y corre
`scripts/apply-migrations.sh` contra la base `skirmbooks` de `postgres-shared-rw` como
superuser (`shared-postgres-superuser`). El hook corre **antes** de que arranque el pod
nuevo: el esquema siempre va por delante del código. El runner es idempotente (salta lo ya
registrado por filename+hash).

**Consecuencia operativa:** a partir de aquí, CUALQUIER migración mergeada en `main` de
`skirmbooks-gestoria-src` se aplica sola en el siguiente sync de esta app, y un runner que
falle **bloquea el despliegue entero** (el sync no avanza; se ve en ArgoCD como hook Failed
con el log del Job). Es deliberado: es competencia del despliegue. El Job no interpreta
códigos de salida: 0 = éxito, cualquier otro = fallo (D11). Los bump de imagen del backend
o de la UI NO mueven las migraciones: estas viajan con `main` de `skirmbooks-gestoria-src`,
no con las imágenes.

- Ver el log de la última ejecución: `kubectl logs -n skirmshop job/skirmbooks-migrations`
- Re-ejecutar: lanzar un nuevo sync (el hook se recrea con `BeforeHookCreation`).
- Estado del esquema: `kubectl exec -n databases postgres-shared-3 -- psql -U postgres -d skirmbooks -c "select filename, applied_at from public.schema_migrations order by filename desc limit 5"`
