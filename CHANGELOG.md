# Changelog

## v0.1.3

- Treat `:einval` socket close notifications as normal shutdowns during server-side connection teardown.

## v0.1.2

- Treat closed server reply sockets as normal connection shutdowns to avoid noisy crash reports during client disconnects or upstream restarts.

## v0.1.1

- Fixed persistent clients so pending calls receive errors when the server closes the connection.

## v0.1.0

Initial package release.

- Added Unix socket transport and packet-framed ETF requests.
- Added safe term decoding with `:erlang.binary_to_term(binary, [:safe])`.
- Added one-shot and persistent client `call` / `cast` APIs.
- Added server-side persistent connections and request id tracking for multiple in-flight requests.
- Added sharded client pools.
- Added Task-like async requests with `async`, `await`, `yield`, and `shutdown`.
- Added `use SafeRPC.Server` callback wrapper.
- Added per-request capability checks and optional authorizer callbacks.
- Added request cancellation.
- Added framework-agnostic adapter behaviours and HTTP envelopes.
- Added Plug adapter support.
