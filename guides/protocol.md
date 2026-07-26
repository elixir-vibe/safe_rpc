# Protocol

SafeRPC transports Erlang external term format (ETF) frames over a packet-oriented transport. The default transport is a Unix domain socket.

## Term shapes

SafeRPC currently uses four protocol terms.

Call request:

```elixir
{:safe_rpc, 1, id, cap, :call, op, payload, meta}
```

Cast request:

```elixir
{:safe_rpc, 1, id, cap, :cast, op, payload, meta}
```

Cancel request:

```elixir
{:safe_rpc_cancel, 1, id}
```

Reply:

```elixir
{:safe_rpc_reply, 1, id, result}
```

Each term is encoded with `:erlang.term_to_binary/1`. Decoding uses `Plug.Crypto.non_executable_binary_to_term(binary, [:safe])` so unknown atoms and executable terms are rejected.

## Fields

- `id` correlates requests and replies.
- `cap` is an optional capability token checked on the server.
- `kind` is `:call` or `:cast`.
- `op` is an operation atom or `{Module, function}` pair. `use SafeRPC` services use the module/function form.
- `payload` is the request term.
- `meta` is a map of per-request metadata.
- `result` is normally `{:ok, term}` or `{:error, reason}`, but SafeRPC does not enforce an application result schema.

## Built-in operations

SafeRPC reserves two operation atoms:

```elixir
:safe_rpc_describe
:safe_rpc_atoms
```

`:safe_rpc_describe` returns a native descriptor for tooling on compatible code paths.

`:safe_rpc_atoms` returns the service atom vocabulary as strings so independent clients can prepare their VM for safe ETF decoding.

Both operations go through normal server-side capability and authorizer checks.

## Safe decoding and frame limits

SafeRPC does not use unsafe `binary_to_term/1` for protocol frames. Decoding refuses unknown atoms and executable terms such as anonymous functions. Compressed ETF is rejected before decompression.

Encoded frames are limited to 16 MiB by default on both clients and servers. Set `:max_frame_size` to a smaller positive byte count when starting a server or client and when making one-shot calls. Oversized outgoing frames return `{:error, {:frame_too_large, size, limit}}`; oversized inbound frames close only that connection.

For atom-rich cross-release replies, use `SafeRPC.prepare/2` before the call. See [Atom vocabularies and safe ETF](atom-vocabularies.md) and the [security model](security.md).

## Versioning

The protocol term version is currently `1`. Unknown or malformed request/reply terms are rejected by the protocol decoder.
