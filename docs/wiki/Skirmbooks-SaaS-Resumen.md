# Skirmbooks SaaS — Qué tienes montado (resumen de 1 página)

Skirmbooks pasó de ser la contabilidad de **una** empresa a un **SaaS multi-cuenta** que la
gestoría puede vender a clientes externos. **Todo lo de abajo está vivo en producción.**

## Modelo (3 niveles)
- **Cuenta** = un cliente (la gestoría propia, o un cliente externo). Aislada del resto.
- **Empresa** (tenant) = cada cuenta tiene N empresas (skirmshop, moreno, personal…).
- **Usuario** = entra y ve **solo su cuenta**. Dani = **super-admin**: ve/gestiona todas.

## Cómo se usa
| Para | URL |
|---|---|
| Entrar | `https://skirmbooks.lan.e-dani.com/login` (LAN/Tailscale) — `info@e-dani.com`, pw en 1Password |
| Gestionar cuentas/empresas/usuarios/bancos/correos/branding/auditoría | `/admin/cuentas` (super-admin) |
| Cambiar tu contraseña | `/perfil` |
| Ver plan / uso / límites | `/facturacion` (cuando el cobro esté activo) |
| Alta self-service de cliente | `/signup` (apagado hasta activar el cobro) |

## Lo construido (fases P0–P5, todo desplegado)
- **Seguridad**: sesión endurecida (cookie 7d + doble cookie), `SESSION_SECRET` en **Vault/ESO**,
  aislamiento estricto entre cuentas (RLS en BD), auditado en varias rondas adversariales.
- **Self-service**: cambio de contraseña, registro `/signup`, wizard de onboarding.
- **Config por cuenta**: bancos y correos **editables** desde la consola, **branding** (logo/colores),
  **límites por plan** (trial/starter/standard/pro/enterprise) que bloquean altas al excederse.
- **Cumplimiento**: **export** (GDPR Art.20) y **borrado/anonimización** (Art.17) por cuenta.
- **Cobro (billing)**: microservicio Stripe **separado** del Stripe bancario de la tienda —
  construido, probado y **apagado** (no cobra nada) hasta que tú quieras.

## Interruptores del futuro (solo cuando vendas a externos — HOY no hace falta nada)
- **Cobrar de verdad** → darme las *keys* de Stripe (modo test primero). El código ya está; es solo encenderlo.
- **Conectar el banco de un cliente externo (PSD2)** → firmar el callback + contratar *Enable Banking Full Mode*.
- **Credenciales de pago propias por cuenta** (P3a) → si un cliente conecta su PayPal/banco.

## Dónde vive
- **Código**: repo `skirmbooks-gestoria-src` (rama `main`). **Infra/deploy**: `k8s-skirmbooks-pocharlies` (ArgoCD GitOps).
- **Roadmap detallado por fases**: `docs/SAAS_ROADMAP.md` en el repo de código.
- **Base de datos**: migraciones `0044`–`0057` aplicadas (CNPG `postgres-shared`, BD `skirmbooks`).

> Resumen en una frase: **el SaaS está terminado y operativo para la gestoría y sus 3 empresas.**
> Los "pendientes" son interruptores de negocio para cuando captes el primer cliente de pago, no código sin acabar.
