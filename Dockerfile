# Stage 1: Build bombardier
FROM golang:1.22-alpine AS bombardier-builder
RUN apk add --no-cache git
WORKDIR /src
RUN git clone https://github.com/codesenberg/bombardier.git && \
    cd bombardier && go build -o /bin/bombardier .

# Stage 2: Build hey
FROM golang:1.22-alpine AS hey-builder
RUN apk add --no-cache git
RUN go install github.com/rakyll/hey@latest && \
    cp /root/go/bin/hey /bin/hey

# Stage 3: Build vegeta
FROM golang:1.22-alpine AS vegeta-builder
RUN apk add --no-cache git
RUN go install github.com/tsenart/vegeta@latest && \
    cp /root/go/bin/vegeta /bin/vegeta

# Stage 4: Build plow
FROM golang:1.22-alpine AS plow-builder
RUN apk add --no-cache git
RUN go install github.com/six-ddc/plow@latest && \
    cp /root/go/bin/plow /bin/plow

# Stage 5: Build orchestrator
FROM golang:1.22-alpine AS orchestrator-builder
WORKDIR /app
COPY go.mod main.go ./
RUN go build -o /bin/multistress .

# Final image
FROM alpine:latest
RUN apk add --no-cache ca-certificates
COPY --from=bombardier-builder /bin/bombardier /usr/local/bin/bombardier
COPY --from=hey-builder /bin/hey /usr/local/bin/hey
COPY --from=vegeta-builder /bin/vegeta /usr/local/bin/vegeta
COPY --from=plow-builder /bin/plow /usr/local/bin/plow
COPY --from=orchestrator-builder /bin/multistress /usr/local/bin/multistress

CMD ["multistress"]
