FROM golang:1.25.14-alpine3.24@sha256:1ae0735f00daffa3aaf1363a5184c0d2dc55c78e3db4ec70241cdac97bf84b59 AS build

WORKDIR /src
COPY Services/rendezvous/go.mod Services/rendezvous/go.sum ./
RUN go mod download
COPY Services/rendezvous/ ./
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/stack-secrets ./cmd/stack-secrets

FROM alpine:3.23.5@sha256:fd791d74b68913cbb027c6546007b3f0d3bc45125f797758156952bc2d6daf40

COPY --from=build /out/stack-secrets /usr/local/bin/stack-secrets
USER 0:0
ENTRYPOINT ["/usr/local/bin/stack-secrets"]
