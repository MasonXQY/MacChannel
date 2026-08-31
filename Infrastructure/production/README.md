# Production service inputs

This directory is intentionally fail-closed. Copy `env.example` outside the repository, replace every placeholder, and use only digest-pinned images.

The example already pins the public multi-architecture rendezvous and coturn images built from the
accepted source revision. Refresh those two digests only after the repository image workflow passes;
never deploy a mutable tag such as `edge` or `latest`.

The host secret directory must be mode `0700` and contain:

- `postgres-password`: the managed PostgreSQL user's password, one line, mode `0600`.
- `postgres-root-ca.pem`: the CA certificate that verifies the managed PostgreSQL host, mode `0600`.
- `turn-shared-secret`: at least 32 random bytes shared only by rendezvous and coturn, mode `0600`.
- `tls/localhost.pem` and `tls/localhost-key.pem`: the public certificate chain and key for the rendezvous hostname, mode `0600`.

For the official single-server deployment, combine `docker-compose.yml` with
`docker-compose.single-host.yml`. The overlay adds a TLS-enabled PostgreSQL 17 container on an
internal-only Docker network; port 5432 is never published. Its persistent volume is backed up every
day by the units in `host/`, with seven days of local retention. The base file remains suitable for a
managed private PostgreSQL service.

The coturn image currently reads the same certificate paths. When rendezvous and TURN use different hostnames, provision one SAN certificate covering both names. PostgreSQL must be private and TLS-verified; it is not included or published by this compose file.

For a new database, apply `Services/migrations/*.sql` in lexical order once. To upgrade an existing v1.0 database, run `docker compose run --rm migrate-v1-1` before replacing the rendezvous image. The migration is idempotent and the normal compose startup also requires it to complete successfully. Then run the public health, WSS authentication, TURN allocation and forced-relay canaries from a network outside the server.

The official host keeps `/etc/macchannel/production.env` and `/etc/macchannel/secrets` outside the
repository. `host/macchannel.service` starts only digest-pinned images. The certificate deploy hook
copies the renewed public certificate into the protected secret directory and reloads the stack;
the Docker daemon uses bounded local logs and live restore, and SSH accepts keys only.
