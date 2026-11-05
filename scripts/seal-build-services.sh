#!/usr/bin/env bash
# Generates and seals the credentials of a cluster's build-phase services (PostgreSQL,
# Kafka, Redis; clusters/<cluster>/services/) so that the operators and the platform's
# Crossplane providers share each value without anyone ever seeing it. Each value is made
# by openssl inside this script and goes to kubeseal from memory: nothing is printed and
# nothing unencrypted is written to disk.
#
# Usage (from the root of platform-gitops):
#   CLUSTER=rssb-build ./scripts/seal-build-services.sh [<product>-<env> ...]
#
# Writes, sealed with clusters/<cluster>/sealed-secrets/pub-cert.pem:
#   clusters/<cluster>/services/postgres-admin.sealed.yaml   role `crossplane` for CloudNativePG and provider-sql
#   clusters/<cluster>/services/kafka-admin.sealed.yaml      user `crossplane` for Strimzi and provider-kafka
#   clusters/<cluster>/services/redis-users.sealed.yaml      Redis ACL file (key users-acl): the admin and one user per app environment
# and, for every <product>-<env> given, REDIS_URL into
#   apps/<product>/envs/<env>/secrets/<cluster>/backend-secrets.sealed.yaml (merged if it exists)
#
# Sealed values cannot be read back, so a run regenerates EVERY password: run it once per
# cluster, or on purpose to rotate everything. The operators and providers follow the new
# Secrets by themselves; the apps roll when their sealed file changes.
set -euo pipefail

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

CLUSTER="${CLUSTER:-}"
[ -n "$CLUSTER" ] || die "set CLUSTER (lab, rssb-build): CLUSTER=rssb-build $0 logistics-uat"
[ -f clusters/lab/kustomization.yaml ] || die "run this from the root of platform-gitops"
cert="clusters/$CLUSTER/sealed-secrets/pub-cert.pem"
[ -f "$cert" ] || die "$cert not found: unknown cluster, or not bootstrapped yet"
out="clusters/$CLUSTER/services"
[ -d "$out" ] || die "$out not found: this cluster has no build-phase services"
for p in "$@"; do
  [[ $p =~ ^[a-z0-9]+-[a-z0-9]+$ ]] || die "not a <product>-<env>: $p"
  [ -f "apps/${p%-*}/envs/${p##*-}/values.yaml" ] || die "apps/${p%-*}/envs/${p##*-}/values.yaml not found"
done
KUBESEAL="${KUBESEAL:-$(command -v kubeseal || echo "$HOME/bin/kubeseal.exe")}"
[ -x "$KUBESEAL" ] || command -v "$KUBESEAL" >/dev/null || die "kubeseal not found (set KUBESEAL)"
command -v openssl >/dev/null || die "openssl not found"
ns=platform-services

# A fresh value: letters and digits only, so it survives JSON and URLs unquoted.
newpw() { openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 40; }
sha256() { openssl dgst -sha256 | sed -E 's/^.*= //'; }

# Seals the Secret read on stdin into $1, applied before the services (sync wave -1).
# kubeseal needs only the public certificate; no cluster access.
seal() {
  local file=$1
  "$KUBESEAL" --cert "$cert" --format yaml \
    | tr -d '\r' \
    | grep -v 'creationTimestamp: null' \
    | awk '{ print } !done && /^  namespace: / {
        print "  annotations:"
        print "    argocd.argoproj.io/sync-wave: \"-1\" # before the operators read it"
        done = 1 }' >"$file"
  echo "wrote $file (Secret $(awk '/^  name: /{print $2; exit}' "$file") in $ns, keys: $(grep -cE '^    [^ ]+: Ag' "$file"))"
}

# ---- PostgreSQL: the `crossplane` role, one Secret for CloudNativePG and provider-sql ----
pg_pw=$(newpw)
kubectl create secret generic postgres-admin -n "$ns" --dry-run=client -o yaml \
  --type kubernetes.io/basic-auth \
  --from-literal=username=crossplane \
  --from-literal=password="$pg_pw" \
  --from-literal=endpoint="postgres-rw.$ns.svc" \
  --from-literal=port=5432 \
  | sed '/^metadata:/a\  labels:\n    cnpg.io/reload: "true"' \
  | seal "$out/postgres-admin.sealed.yaml"
unset pg_pw

# ---- Kafka: the `crossplane` super user, one Secret for Strimzi and provider-kafka ----
kafka_pw=$(newpw)
kubectl create secret generic kafka-admin -n "$ns" --dry-run=client -o yaml \
  --from-literal=password="$kafka_pw" \
  --from-literal=credentials="{\"brokers\":[\"kafka-kafka-bootstrap.$ns.svc:9092\"],\"sasl\":{\"mechanism\":\"SCRAM-SHA-512\",\"username\":\"crossplane\",\"password\":\"$kafka_pw\"}}" \
  | seal "$out/kafka-admin.sealed.yaml"
unset kafka_pw

# ---- Redis: the ACL file (hashes only) and each app environment's REDIS_URL ----
# Same shape as the lab's lab-services.sh: a user per <product>_<env>, fenced to the keys
# and channels under <product>:<env>:, no dangerous commands; the admin keeps everything.
acl="user default on #$(newpw | sha256) ~* &* +@all"
for p in "$@"; do
  product=${p%-*} env=${p##*-}
  user="${product}_${env}" prefix="${product}:${env}:"
  pw=$(newpw)
  acl+=$'\n'"user $user on #$(printf '%s' "$pw" | sha256) resetkeys ~$prefix* resetchannels &$prefix* &${prefix}socket.io#/#* +@all -@dangerous"
  target="apps/$product/envs/$env/secrets/$CLUSTER/backend-secrets.sealed.yaml"
  if [ -f "$target" ]; then
    printf 'REDIS_URL=redis://%s:%s@redis.%s.svc:6379\n' "$user" "$pw" "$ns" \
      | CLUSTER="$CLUSTER" MERGE=1 ./scripts/seal-secret.sh "$product" "$env" backend-secrets
  else
    printf 'REDIS_URL=redis://%s:%s@redis.%s.svc:6379\n' "$user" "$pw" "$ns" \
      | CLUSTER="$CLUSTER" ./scripts/seal-secret.sh "$product" "$env" backend-secrets
    echo "  add the app's other keys with: printf 'KEY=value\\n' | CLUSTER=$CLUSTER MERGE=1 ./scripts/seal-secret.sh $product $env backend-secrets"
  fi
  unset pw
done
# Built by hand: kubectl's --from-file cannot read stdin on every platform.
printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: redis-users\n  namespace: %s\ntype: Opaque\ndata:\n  users-acl: %s\n' \
  "$ns" "$(printf '%s\n' "$acl" | base64 | tr -d '\r\n')" \
  | seal "$out/redis-users.sealed.yaml"
unset acl

echo "done: commit $out/*.sealed.yaml by PR (and log it in SECRETS.md)"
