# k8s-skirmbooks-pocharlies

GitOps manifests for `skirmbooks-ui`, migrated from the Sauvage Docker container.

- Public host: `skirmbooks.e-dani.com`
- Namespace: `skirmshop`
- Image: `harbor.e-dani.com/homelab/skirmbooks-ui:k8s-20260523-legacy`
- Database: `postgres-shared-rw.databases.svc.cluster.local/skirmbooks`
- Secret: `skirmbooks-ui-secrets` in namespace `skirmshop` for Tink credentials.

The app's legacy Docker database `shared-postgres/gestoria` was dumped and restored into the definitive k8s shared PostgreSQL database `skirmbooks`.
