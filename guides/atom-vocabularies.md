# Atom vocabularies and safe ETF

SafeRPC decodes frames with:

```elixir
:erlang.binary_to_term(binary, [:safe])
```

The `:safe` option refuses to create new atoms. This protects the VM atom table, but it means a client must already have any atoms that appear in a reply.

## Server compile time

SafeRPC builds a service atom vocabulary at compile time. For `use SafeRPC` services it includes:

- the service atom from `service: ...`;
- operation module and function atoms;
- literal atoms from `@rpc` specs;
- literal atoms from `@rpc` function bodies;
- literal atoms from `@rpc` options;
- optional explicit atoms from `use SafeRPC, atoms: ...`.

SafeRPC only inspects RPC boundaries. It does not collect atoms from unrelated helper functions.

Example:

```elixir
defmodule MyApp.AdminRPC do
  use SafeRPC, service: :my_app

  @rpc true
  @spec status(map(), map(), term()) :: {:ok, :ready | :degraded}
  def status(_payload, _meta, _state), do: {:ok, :ready}
end
```

The vocabulary contains `:my_app`, `MyApp.AdminRPC`, `:status`, `:ok`, `:ready`, and `:degraded`.

Frameworks that generate SafeRPC services should put compile-time metadata that crosses the RPC boundary in the generated `@rpc` body. SafeRPC will see literal maps, structs, tuples, and keyword lists there and collect their atoms without framework-specific hooks.

## Client runtime

The client asks for the vocabulary at runtime:

```elixir
{:ok, atoms} = SafeRPC.atoms(client)
```

Then it can validate and intern it:

```elixir
:ok =
  SafeRPC.prepare(client,
    max_atoms: 1_000,
    max_atom_length: 128,
    allow: [~r/^[a-z][a-z0-9_]*$/, ~r/^Elixir\.MyApp\./]
  )
```

`prepare/2` never decodes arbitrary atom-rich replies. It receives atom names as strings, applies the client policy, and only then calls `String.to_atom/1` for accepted names.

## Dynamic atoms

SafeRPC cannot infer atoms created only at runtime, for example atoms coming from a database row or user input. Prefer strings for unbounded values. If a runtime atom set is finite and intentional, declare it explicitly:

```elixir
use SafeRPC, service: :my_app, atoms: [:queued, :running, :failed]
```

## What this does not guarantee

Safe ETF protects the Erlang runtime from creating unbounded atoms while decoding. It does not validate application semantics. Servers should still authorize requests, and clients should still validate replies according to application rules.
