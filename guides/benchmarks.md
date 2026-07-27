# Benchmarks and stress testing

SafeRPC keeps performance checks reproducible and separate from correctness tests. Benchmark results depend on the host, scheduler count, OTP version, power state, and competing workloads; compare revisions on the same otherwise-idle machine instead of treating one run as a universal number.

## Serial compatibility benchmark

`bench/safe_rpc_bench.exs` measures one-shot calls, a persistent client, and a sharded client pool with multiple payload sizes and parallelism levels. It reports throughput, latency including the 99th percentile, and caller-process allocations.

Run the current checkout with fixed scheduler count:

```bash
ELIXIR_ERL_OPTIONS="+S 8:8" mix run bench/safe_rpc_bench.exs
```

Compare the current checkout with the last release using the same benchmark script and VM settings:

```bash
scripts/benchmark_compare.sh v0.1.16 /tmp/safe-rpc-benchmark-results
```

The comparison script creates a temporary detached worktree, runs the common benchmark against both revisions, and stores Benchee suites plus console output in the selected results directory. It does not modify either revision.

## Runtime-foundation benchmark

`bench/runtime_foundations_bench.exs` compares serialized and concurrent dispatch with a 5 ms handler at parallelism 1, 4, 16, and 64. It also compares an echo call with no telemetry handlers against the same call with a no-op request telemetry handler attached.

```bash
ELIXIR_ERL_OPTIONS="+S 8:8" mix run bench/runtime_foundations_bench.exs
```

At parallelism greater than one, interpret Benchee's per-invocation latency together with the configured parallelism. Serialized dispatch queues the calls; concurrent dispatch should keep latency close to one handler duration until a configured in-flight bound is reached.

## Configuration

Both scripts accept environment overrides:

| Variable | Default | Purpose |
| --- | ---: | --- |
| `SAFERPC_BENCH_WARMUP` | `1` | Warmup seconds per scenario |
| `SAFERPC_BENCH_TIME` | `3` | Measurement seconds per scenario |
| `SAFERPC_BENCH_MEMORY_TIME` | `1` | Caller-allocation measurement seconds |
| `SAFERPC_BENCH_PARALLEL` | `1,4,16` | Parallelism for the serial compatibility suite |
| `SAFERPC_BENCH_PAYLOADS` | `small,1kb,64kb` | Payloads for the serial compatibility suite |
| `SAFERPC_BENCH_DELAY_MS` | `5` | Simulated handler time in the runtime suite |
| `SAFERPC_BENCH_TELEMETRY` | `true` | Run the telemetry comparison |

The runtime suite defaults to parallelism `1,4,16,64` when `SAFERPC_BENCH_PARALLEL` is unset.

Benchee's memory figure covers allocations attributed to the benchmark caller. Use the stress suite to validate server-side bounds and mailbox behavior rather than interpreting that figure as total system memory.

## Stress suite

Run the opt-in stress tests with:

```bash
SAFERPC_STRESS=1 mix test --include stress
```

Increase the request count when validating a release candidate:

```bash
SAFERPC_STRESS=1 SAFERPC_STRESS_COUNT=10000 mix test --include stress
```

The suite covers persistent-client floods, asynchronous requests, concurrent cancellation and slot recovery, bounded serialized connection mailboxes, and sharded client pools.
