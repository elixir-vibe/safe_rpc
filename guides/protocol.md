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

Each term is encoded with `:erlang.term_to_binary/1` and decoded with `:erlang.binary_to_term(binary, [:safe])`.

## Fields

- `id` correlates requests and replies.
- `cap` is an optional capability token checked on the server.
- `kind` is `:call` or `:cast`.
- `op` is the application operation. `use SafeRPC` services use `{Module, function}`.
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

## Safe decoding

SafeRPC does not use unsafe `binary_to_term/1` for protocol frames. Safe decoding rejects unknown atoms, remote references that would create atoms indirectly, and unsafe external function references.

For atom-rich cross-release replies, use `SafeRPC.prepare/2` before the call. See [Atom vocabularies and safe ETF](atom-vocabularies.md).

## Versioning

The protocol term version is currently `1`. Unknown or malformed request/reply terms are rejected by the protocol decoder.
