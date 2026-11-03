# platform-gitops (DEVOPS-CANARY)

What runs in our Kubernetes clusters, as files. Argo CD watches this repository and makes
each cluster match its folder; nobody runs `kubectl apply` for apps or platform components.
Two clusters read it today: **rssb-build**, the three RSSB nodes built by
[`platform-infra`](https://github.com/DEVOPS-CANARY/platform-infra) (3 Nov 2026), and
**lab**, the laptop minikube the platform was proven on.

```
bootstrap/                 applied once per cluster, by a person
  argocd/                  Argo CD, pinned release (single replica: the lab)
  argocd-ha/               the same release in its high-availability form (3+ nodes: rssb-build)
  sealed-secrets/          the Sealed Secrets controller
platform/
  argocd-apps/base/        what Argo CD manages everywhere: the "apps" and "platform" projects,
                           the ApplicationSet (app folders -> Applications), the platform
                           Applications (Gateway API, Traefik, KEDA, Kyverno, policies, Crossplane)
  argocd-apps/per-cluster/ fills the three per-cluster blanks in the base from clusters/<name>/
  traefik/ keda/ kyverno/  settings of each platform component, the same on every cluster
  crossplane/providers/    provider-sql, provider-kafka and how their pods run
  policies/                Kyverno: walls, quota and limits per app namespace, images by digest
clusters/<name>/           one folder per cluster, holding only what differs
  kustomization.yaml       base + per-cluster, with this cluster's three values
  values/traefik.yaml      how the entry point is exposed (NodePort, LoadBalancer + MetalLB)
  crossplane/              this cluster's database and Kafka connections (sealed admins)
  sealed-secrets/pub-cert.pem   this cluster's sealing certificate
  root.yaml                (rssb-build) the one Application a person applies; Argo CD does the rest
  services/                (lab) databases in Docker next to the laptop cluster
apps/<product>/
  values.yaml              what is the same in every environment (rssb-app chart)
  envs/<env>/              uat, staging, prod
    values.yaml            chart version, image digests, host, per-env settings
    secrets/<cluster>/     sealed secrets, per cluster: a file only opens where it was sealed
SECRETS.md                 the secrets register: rules, inventory, handling log
scripts/                   lab helpers: bootstrap-lab.sh, lab-services.sh, seal-secret.sh, wall-test.sh
```

## How a cluster is made of this repo

The ApplicationSet turns every `apps/<product>/envs/<env>/values.yaml` into an Argo CD
Application `<product>-<env>` in its own namespace. Apps are rendered by the platform chart
[`rssb-app`](https://github.com/DEVOPS-CANARY/platform-charts) at the version the env pins,
from the product's shared values and the env's own on top, so a setting cannot be changed
in UAT and forgotten in prod. The platform components are Applications of their own, from
pinned upstream charts with our values file.

**What differs per cluster, and only that**, lives in `clusters/<name>/`:

| Blank in the base | lab | rssb-build |
|---|---|---|
| Entry point exposure (`values/traefik.yaml`) | NodePort 30080 | NodePort 30080 until MetalLB has an address range (plan, Q22), then LoadBalancer behind FortiADC |
| Database and Kafka connections (`crossplane/`) | the laptop's Docker services | empty until the build-phase PostgreSQL and Kafka run in the cluster (plan, D36) |
| Sealed secrets (`apps/*/envs/*/secrets/<name>/`) | sealed with the lab's shared key | sealed with the cluster's own key, generated at bootstrap and backed up outside Git |

Everything else (which components, their versions and settings, the policies, the apps) is
identical, by construction: the cluster folders cannot add Applications, only fill blanks.
CI renders every cluster folder and fails on an unfilled blank.

**Apps never name a cluster.** They attach `HTTPRoute`s to the shared Gateway `gateway/public`,
declare their database and Kafka user (Crossplane) by referring to a connection name, and read
credentials from Secrets the platform generates. Moving an app between clusters is moving a
sealed secret.

## The RSSB build cluster

Bootstrapped once from node-1 by `platform-infra` (`make bootstrap`): the Sealed Secrets
controller (which generates this cluster's key), Argo CD in HA form, Argo CD's read-only
GitHub App credential for this repository (HTTPS; no SSH, no deploy keys), and
`clusters/rssb-build/root.yaml`. From then on Argo CD manages its own
projects, ApplicationSet and platform Applications from this folder: **a merged PR is a change
in the cluster**, including changes to Argo CD's own configuration.

Only SSH reaches the nodes from the VPN (3 Nov 2026), so there is no `kubectl` from laptops
yet. To look: `ssh node-1 'sudo microk8s kubectl get applications -n argocd'` (sudo is logged).
Apps answer on any node's port 30080 with the right `Host:` header until MetalLB exists.

## The laptop lab

Everyone can still run their own minikube from this repo (`scripts/bootstrap-lab.sh`; it
applies `clusters/lab`, can follow a `sandbox/<you>` branch, and starts the Docker services
with the passwords from `platform-secrets`). The lab is where a risky change is tried before
it reaches a PR. It needs `kubectl`, `docker`, `git`, `openssl`, `sops` and membership of
`platform-secrets`; `minikube start -p devops-lab --cpus 4 --memory 6144 --cni calico`
(Calico, or the network walls silently do not exist).

**Changing the lab's Argo CD config:** the lab does not run a root Application, so after a
PR that touches `platform/argocd-apps` or `clusters/lab`, re-run the bootstrap or
`kubectl apply -k clusters/lab`. rssb-build picks such changes up by itself.

## Deploying
- **UAT:** CI commits the new image digest to `apps/<product>/envs/uat/values.yaml` on
  every merge to the app's `develop` branch.
- **Staging:** on every merge to the app's `staging` branch, CI finds the image already built
  for UAT (same content, same `tree-` tag) and commits its digest to `envs/staging/values.yaml`.
- **Prod:** the app's approved *Release* workflow, run on `main`, commits the digest that
  Staging runs to `envs/prod/values.yaml`.
- **Rollback:** `git revert` the commit that changed the digest.

## Secrets
The rules, the inventory and the handling log are in [SECRETS.md](SECRETS.md). The short
version: never a plain Secret in Git, values go from a command straight into the sealing tool,
one sealed file per cluster. Pipe `KEY=VALUE` lines into `scripts/seal-secret.sh` with the
cluster whose certificate must seal it:
```sh
printf 'JWT_SECRET=%s\n' "$(openssl rand -hex 32)" \
  | CLUSTER=rssb-build ./scripts/seal-secret.sh <product> <env> backend-secrets
```
It writes `apps/<product>/envs/<env>/secrets/rssb-build/backend-secrets.sealed.yaml`, which
only that cluster's controller can open, and only as that name in namespace `<product>-<env>`.
Database and Kafka credentials are never sealed: Crossplane generates them (golden path
layer 6). What still needs sealing per environment: the registry pull secret, JWT and API keys.
