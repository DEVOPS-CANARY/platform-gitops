# Sealing certificate, RSSB build cluster

`pub-cert.pem` lands here after the first bootstrap: the controller in the cluster generates its
own key pair (never the lab's), and the bootstrap playbook fetches the public half. Seal with
`CLUSTER=rssb-build scripts/seal-secret.sh …`. The private key is backed up by the platform
team outside this repository (plan, D25); without it a rebuilt cluster cannot read any
`*.sealed.yaml` under `secrets/rssb-build/`.
