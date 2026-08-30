# Production service inputs

This directory is intentionally fail-closed. Copy `env.example` outside the repository, replace every placeholder, and use only digest-pinned images.

The host secret directory must be mode `0700` and contain:

- `postgres-password`: the managed PostgreSQL user's password, one line, mode `0600`.
- `turn-shared-secret`: at least 32 random bytes shared only by rendezvous and coturn, mode `0600`.
- `tls/localhost.pem` and `tls/localhost-key.pem`: the public certificate chain and key for the rendezvous hostname, mode `0600`.

The coturn image currently reads the same certificate paths. When rendezvous and TURN use different hostnames, provision one SAN certificate covering both names. PostgreSQL must be private and TLS-verified; it is not included or published by this compose file.

Apply `Services/migrations/*.sql` in lexical order through the managed database migration job before replacing the rendezvous image. Then run the public health, WSS authentication, TURN allocation and forced-relay canaries from a network outside the server.
