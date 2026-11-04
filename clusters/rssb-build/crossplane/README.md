# Crossplane connections, RSSB build cluster

One `ClusterProviderConfig` per service the platform administers for the apps:

| Connection | Points at | Signs in as | Credentials (sealed) |
|---|---|---|---|
| `platform-postgres` | `postgres-rw.platform-services.svc:5432` (CloudNativePG, `../services/postgres.yaml`) | role `crossplane` | `postgres-admin` in `platform-services` |
| `platform-kafka` | `kafka-kafka-bootstrap.platform-services.svc:9092` (Strimzi, `../services/kafka.yaml`) | super user `crossplane` | `kafka-admin` in `platform-services` |

The names are the platform's contract with the apps: the `rssb-app` chart names
`platform-postgres` and `platform-kafka` by default, on every cluster. The lab has the
same two names pointing at its Docker services (`clusters/lab/crossplane/`). When RSSB's
own database and Kafka servers take over (plan, D36), only these two files and their
sealed credentials change; no app does.

The sealed credentials live next to the services (`../services/*.sealed.yaml`), written by
`scripts/seal-build-services.sh`, because the operators read the same Secrets.
