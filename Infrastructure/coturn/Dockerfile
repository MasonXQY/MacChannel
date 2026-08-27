FROM golang:1.25.14-alpine3.24@sha256:1ae0735f00daffa3aaf1363a5184c0d2dc55c78e3db4ec70241cdac97bf84b59 AS launcher-build

WORKDIR /src
COPY Services/rendezvous/go.mod Services/rendezvous/go.sum ./
RUN go mod download
COPY Services/rendezvous/ ./
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/secret-launcher ./cmd/secret-launcher

FROM coturn/coturn:4.17.2-r0-alpine@sha256:771a95d04cb97bbc5bfc672e5fdf455591c7d2b2a15f02bb9ceda3e27561695f

USER 0:0
# The upstream binary carries cap_net_bind_service. MacChannel uses only
# unprivileged ports, and no-new-privileges correctly rejects executing a file
# that would acquire a capability outside the container bounding set. A plain
# copy deliberately drops that file capability.
RUN cp /usr/bin/turnserver /usr/local/bin/turnserver-unprivileged \
    && chmod 0755 /usr/local/bin/turnserver-unprivileged
COPY --from=launcher-build /out/secret-launcher /usr/local/bin/secret-launcher
COPY Infrastructure/coturn/start-coturn.sh /usr/local/bin/start-coturn.sh
COPY Infrastructure/coturn/turnserver.conf /etc/coturn/turnserver.conf

ENTRYPOINT ["/usr/local/bin/secret-launcher", "--uid", "65534", "--gid", "65534", "--copy", "/stack-secrets/turn-shared-secret=/run/coturn/secrets/turn-shared-secret", "--copy", "/stack-secrets/tls/localhost.pem=/run/coturn/secrets/localhost.pem", "--copy", "/stack-secrets/tls/localhost-key.pem=/run/coturn/secrets/localhost-key.pem", "--", "/usr/local/bin/start-coturn.sh"]
