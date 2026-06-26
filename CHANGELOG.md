# Changelog

## v0.1.10 - 2026-06-26

- Add bounded atom vocabulary preparation for safe ETF clients.
- Add `use SafeRPC, atoms: [...]` declarations and a `SafeRPC.prepare/2` client helper.

## v0.1.9 - 2026-06-25

- Load the SafeRPC application metadata before descriptor calls so safe ETF can decode SafeRPC struct atoms.

## v0.1.8 - 2026-06-25

- Use integer request identifiers so one-shot replies decode with safe ETF.

## v0.1.7 - 2026-06-25

- Serialize RPC operation specs as strings so descriptors remain safe ETF across clients.

## v0.1.6 - 2026-06-25

- Fix server connection cleanup after sending replies.

## v0.1.5 - 2026-06-25

- Add `:socket_mode` support for Unix socket listeners.

## v0.1.4 - 2026-06-25

- Add `child_spec/1` to `use SafeRPC.Server` modules so SafeRPC servers and adapter servers can be supervised directly.

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
