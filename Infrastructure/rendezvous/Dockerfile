FROM golang:1.25.14-alpine3.24 AS build

WORKDIR /src
COPY Services/rendezvous/go.mod Services/rendezvous/go.sum ./
RUN go mod download
COPY Services/rendezvous/ ./
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/rendezvous ./cmd/server

FROM alpine:3.23.5

RUN apk add --no-cache ca-certificates \
    && addgroup -S -g 65532 macchannel \
    && adduser -S -D -H -u 65532 -G macchannel macchannel
COPY --from=build /out/rendezvous /usr/local/bin/rendezvous

USER 65532:65532
EXPOSE 8080 8443
ENTRYPOINT ["/usr/local/bin/rendezvous"]
