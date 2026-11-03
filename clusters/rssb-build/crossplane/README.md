# Crossplane connections, RSSB build cluster

Empty on purpose until the build-phase PostgreSQL and Kafka run in the cluster (plan, D36).
Then this folder holds one `ClusterProviderConfig` per service plus its sealed admin
credentials, exactly like `clusters/lab/crossplane/` does for the lab's Docker services.
Apps never change: they reference the provider config by name.
