FROM golang:1.22-alpine AS builder
RUN apk add --no-cache ca-certificates
WORKDIR /build
COPY go.mod ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /build/darkvision-agent .

FROM scratch
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=builder /build/darkvision-agent /darkvision-agent
EXPOSE 2095
ENTRYPOINT ["/darkvision-agent"]
