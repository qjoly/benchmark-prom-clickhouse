# Build the TSBS (Time Series Benchmark Suite) binaries from source.
FROM golang:1.26-bookworm AS build

ARG TSBS_REF=master
WORKDIR /src
RUN git clone https://github.com/timescale/tsbs.git . \
    && git checkout "${TSBS_REF}"

# Install all available binaries (generate_data, generate_queries,
# load_clickhouse, load_prometheus, run_queries_*, etc.) into /go/bin.
# GOFLAGS=-mod=mod: lets Go fill in the go.sum entries missing from TSBS master.
RUN CGO_ENABLED=0 GOFLAGS=-mod=mod go install ./cmd/...

FROM debian:bookworm-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl bash coreutils gzip jq \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /go/bin/ /usr/local/bin/
WORKDIR /workspace
CMD ["bash"]
