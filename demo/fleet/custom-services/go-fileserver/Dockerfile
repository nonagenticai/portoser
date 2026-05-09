FROM golang:1.23-alpine AS build
WORKDIR /src
COPY go.mod main.go ./
RUN CGO_ENABLED=0 go build -o /go-fileserver ./...

FROM alpine:3.20
RUN apk add --no-cache ca-certificates wget
COPY --from=build /go-fileserver /usr/local/bin/go-fileserver
EXPOSE 9000
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
    CMD wget -q --spider http://127.0.0.1:9000/health || exit 1
ENTRYPOINT ["/usr/local/bin/go-fileserver"]
