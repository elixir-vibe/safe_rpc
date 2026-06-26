# SafeRPC

SafeRPC is a small BEAM-native RPC layer for explicit, capability-scoped APIs over safe Erlang external term format.

Use it when both sides are BEAM applications and you want ordinary Elixir/Erlang terms without exposing Erlang distribution or arbitrary remote MFA.

```elixir
defmodule MyApp.AdminRPC do
  use SafeRPC, service: :my_app, version: "1"

  @rpc true
  @spec status(map(), map(), keyword()) :: {:ok, :ready}
  def status(_payload, _meta, _state), do: {:ok, :ready}
end

defmodule MyApp.AdminRPCServer do
  use SafeRPC.Adapter.Server, service: MyApp.AdminRPC
end
```

```elixir
{:ok, server} = MyApp.AdminRPCServer.start_link(socket: "/tmp/my-app.sock")
{:ok, :ready} = SafeRPC.call("/tmp/my-app.sock", {MyApp.AdminRPC, :status})
```

## What runs where

| Concern | Side | Time |
| --- | --- | --- |
| `use SafeRPC` and `@rpc` collection | service module | compile time |
| atom vocabulary collection from RPC specs/bodies/options | service module | compile time |
| socket listener and operation dispatch | server BEAM | runtime |
| `SafeRPC.call/4`, `cast/4`, `async/4` | client BEAM | runtime |
| `SafeRPC.prepare/2` atom preflight | client BEAM calling server | runtime before atom-rich calls |
| capability and authorizer checks | server BEAM | runtime per request |

## Why not Erlang distribution?

Erlang distribution is designed for trusted clusters. Once nodes are connected, the trust boundary is broad. SafeRPC keeps the surface narrow: only operations explicitly marked with `@rpc` or explicitly implemented by an adapter service are callable.

## Installation

```elixir
def deps do
  [{:safe_rpc, "~> 0.1"}]
end
```

## Guides

- [Service modules](guides/service-modules.md)
- [Clients](guides/clients.md)
- [Atom vocabularies and safe ETF](guides/atom-vocabularies.md)
- [Authorization](guides/authorization.md)
- [Protocol](guides/protocol.md)
- [Local bindings](guides/local-bindings.md)

## License

MIT
