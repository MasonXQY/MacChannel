FROM golang:1.25.14-alpine3.24@sha256:1ae0735f00daffa3aaf1363a5184c0d2dc55c78e3db4ec70241cdac97bf84b59 AS build

WORKDIR /src
COPY Services/rendezvous/go.mod Services/rendezvous/go.sum ./
RUN go mod download
COPY Services/rendezvous/ ./
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/rendezvous ./cmd/server \
    && CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/secret-launcher ./cmd/secret-launcher

FROM alpine:3.23.5@sha256:fd791d74b68913cbb027c6546007b3f0d3bc45125f797758156952bc2d6daf40

COPY --from=build /out/rendezvous /usr/local/bin/rendezvous
COPY --from=build /out/secret-launcher /usr/local/bin/secret-launcher

USER 0:0
EXPOSE 8080 8443
ENTRYPOINT ["/usr/local/bin/secret-launcher", "--uid", "65532", "--gid", "65532", "--copy", "/run/secrets/postgres_password=/run/macchannel/postgres-password", "--copy", "/run/secrets/turn_shared_secret=/run/macchannel/turn-shared-secret", "--copy", "/run/secrets/localhost_cert=/run/macchannel/localhost.pem", "--copy", "/run/secrets/localhost_key=/run/macchannel/localhost-key.pem", "--", "/usr/local/bin/rendezvous"]
