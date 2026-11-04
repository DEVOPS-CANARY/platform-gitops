# The secrets register

Every secret the platform holds, where it lives, who owns it, how it was made, how it is
rotated, and what happened to it. Updated in the same PR as any change to a secret. The point
is practice: this is how a production platform keeps track, and the habit has to exist before
the first real RSSB application arrives.

## Rules

1. **No plaintext in Git, chat, tickets, logs or screenshots.** Not even "just for a second".
   A value that was printed is treated as exposed and replaced (see the log).
2. **Values go from a command straight into the sealing tool**, never through a command line
   argument, a shell variable someone can `echo`, or a file on disk: `openssl rand … |
   seal-secret.sh`, `read -rsp … | seal-secret.sh`, `sops --set` reading stdin.
3. **One secret per purpose, per environment, per cluster.** UAT's JWT secret is not staging's;
   the lab's sealed files do not open on rssb-build. Blast radius stays small.
4. **Least privilege, shortest life.** A registry token can only read packages; a deploy key is
   read-only and per cluster; a join token lives ten minutes; an Argo CD token one hour.
5. **Generated where possible, never seen by a person.** Database and Kafka passwords come from
   Crossplane's providers into Secrets the pods read (golden path layer 6). Humans only handle
   what a machine cannot make: registry tokens, keys to other people's systems.
6. **Every secret has an owner and a rotation.** Written below. "Nobody" and "never" are not
   accepted entries.
7. **Backups of keys that unlock other secrets are mandatory** and live outside this repo.
   Losing the sealing key loses every sealed file for that cluster.
8. **Revoke before you investigate.** If something may have leaked, rotate first, ask later.

## Inventory

### Cluster keys and credentials, rssb-build

| Secret | Lives in | Made by | Owner | Rotation | Backup |
|---|---|---|---|---|---|
| Sealed Secrets private key (`sealed-secrets-key*`, `kube-system`) | the cluster only | the controller at first start (bootstrap) | platform team | the controller adds a new key every 30 days and keeps the old ones; the backup must include all of them | `platform-secrets/secrets/rssb-build-sealed-secrets-key.yaml` (SOPS) until RSSB backups hold it (plan, D25); written by `make backup-sealing-key` in `platform-infra`, re-run after every key rotation. ✅ 4 Nov 2026, PR #11 there; encrypted for two age keys only, a third recipient is needed |
| GitHub App `rssb-argocd-reader` private key (App ID 5594965; Contents: read, installed on `platform-gitops` only), as Argo CD's repository credential Secret (`argocd` namespace) | the cluster; the `.pem` on Babou's WSL only until deleted | GitHub (generated 3 Nov 2026), streamed into the cluster by `make bootstrap` | platform team | yearly, or at once if a node or laptop is compromised: generate a new key in the App settings, re-run `make bootstrap`, revoke the old one | none needed (GitHub mints a new one) |
| Argo CD `admin` password (`argocd-initial-admin-secret`) | the cluster | Argo CD at install | platform team | read once at bootstrap through `ssh node-1`, then the initial Secret is deleted (Argo CD's own advice); SSO replaces it (plan, Q9) | none needed |
| `postgres-admin` (`platform-services`): the `crossplane` role of the build-phase PostgreSQL, read by CloudNativePG and by provider-sql (`platform-postgres`) | the cluster; sealed in `clusters/rssb-build/services/` | `scripts/seal-build-services.sh` (openssl, never shown) | platform team | re-run the script (regenerates every service credential); RSSB's DBA-issued admin replaces it (D36) | none needed (regenerated) |
| `kafka-admin` (`platform-services`): the `crossplane` super user of the build-phase Kafka, read by Strimzi and by provider-kafka (`platform-kafka`) | same | same | platform team | same | none needed |
| `redis-users` (`platform-services`): Redis ACL file (hashes only) and each app environment's `REDIS_URL` (sealed into the app's `backend-secrets`) | same, plus `apps/*/envs/*/secrets/rssb-build/` | same | platform team | same | none needed |
| Node sudo passwords, personal SSH keys | each person's head and laptop | each person | each person | on first login; on any doubt | none, by design |

### Sealed secrets, per app and environment (rssb-build)

| Secret | Keys | Namespace | Owner of the values | Rotation | Status |
|---|---|---|---|---|---|
| `ghcr-pull` | `.dockerconfigjson` (registry read token) | every app namespace | platform team | token expiry (classic tokens: set 90 days); the App-issued token replaces it (plan, layer 4) | ⏳ to seal after bootstrap; the current token is personal and expires 12 Nov 2026 |
| `logistics` `backend-secrets` | `JWT_SECRET`, `REDIS_URL` | `logistics-<env>` | platform team (sample app) | per environment, on demand | ⏳ |
| `logistics` `notifications-secrets` | `DATABASE_URL` (until the worker reads the managed Secret) | `logistics-<env>` | platform team | with the backend's | ⏳ |
| `todo` `backend-secrets` | `JWT_SECRET` | `todo-uat` | platform team (sample app) | on demand | ⏳ |

Generated, never handled by a person: each app's database role and password (`<component>-db`
Secret, Crossplane provider-sql) and Kafka user (`<component>-kafka`, provider-kafka).

### Lab (laptop clusters)

| Secret | Lives in | Notes |
|---|---|---|
| Lab sealing key | `platform-secrets/secrets/sealed-secrets-key.yaml` (SOPS) | shared by every teammate's cluster; lab only, never reused for rssb-build |
| Lab service passwords (Postgres, Redis, Kafka admin) | `platform-secrets/secrets/lab-services.yaml` (SOPS) | read by `scripts/lab-services.sh`; `sops --set` only, never edited by hand (log, 28 Oct) |
| Lab sealed files | `apps/*/envs/*/secrets/lab/` | sealed with the lab key |
| Per-teammate Argo CD deploy keys | each laptop, public half in GitHub | one per cluster, revoked one by one |

### Outside the clusters

| Secret | Lives in | Owner | Notes |
|---|---|---|---|
| `goldenpath-bot` GitHub App private key | GitHub secret in `platform-golden-path` | platform team | issues one-hour tokens; the App has no admin rights (plan, G72) |
| GHCR pull token (personal, classic, read:packages) | sealed as `ghcr-pull` per env | Babou | expires 12 Nov 2026; to be replaced by an App-issued or org-level token |
| Teammates' age keys | each laptop | each person | unlock `platform-secrets`; a lost laptop = re-encrypt the files for the remaining keys |

## Log

Dated, newest first. Creation, rotation, exposure, revocation. Never the value.

| Date | What | Outcome |
|---|---|---|
| 2026-11-04 | Build-phase service credentials for rssb-build generated and sealed by `scripts/seal-build-services.sh` (PostgreSQL admin role, Kafka super user, Redis ACL + logistics UAT `REDIS_URL`) | Never displayed; one Secret per pair of readers, so operator and provider cannot disagree |
| 2026-11-04 | The rssb-build sealing key backed up: `make backup-sealing-key` streams it from the cluster into `sops` (never printed, never plain on disk), committed to `platform-secrets` (PR #11) | Encrypted for the two age keys in its `.sops.yaml`; add a third teammate's key, then re-encrypt |
| 2026-11-04 | Git inside WSL on Babou's laptop set to use the Windows credential store for GitHub | No token written in WSL; same login as before |
| 2026-11-03 | GitHub App `rssb-argocd-reader` created (read-only); its private key downloaded, moved into WSL (mode 600), streamed into the `argocd` namespace by `make bootstrap`; to be deleted from the laptop | Replaces SSH deploy keys for Argo CD: no outbound SSH, no key on nodes |
| 2026-11-03 | The RSSB cluster's Sealed Secrets key pair generated by the controller at bootstrap; public certificate committed (`clusters/rssb-build/sealed-secrets/pub-cert.pem`, PR #46) | Private key backup into `platform-secrets` pending |
| 2026-11-03 | Secrets became per cluster (`secrets/<cluster>/`); register created | The lab's sealed files moved under `secrets/lab/`; rssb-build has none yet |
| 2026-11-03 | Join tokens for node-2 and node-3 (MicroK8s) | Generated by the playbook, ten-minute life, never logged; expired |
| 2026-11-02 | Node SSH key and config copied into WSL on Babou's laptop (mode 600) | Same machine, same person; noted for completeness |
| 2026-10-28 | A lab service password was typed in plaintext into `lab-services.yaml`; `sops` printed it in its error | Treated as exposed: not committed, file restored, value replaced (plan, G80) |
| 2026-10-28 | `TODO_UAT_DB_PASSWORD` and `LOGISTICS_UAT_KAFKA_PASSWORD` removed from `platform-secrets` | Replaced by Crossplane-generated credentials (layer 6); hand-made database role and Kafka user deleted on the lab services |
| 2026-10-26 | Deploy keys and personal tokens removed from CI; `goldenpath-bot` App introduced | One-hour scoped tokens (plan, layer 4) |
