# Service modules

A service module is compiled on the server side. It declares the service name and marks callable functions with `@rpc`.

```elixir
defmodule MyApp.AdminRPC do
  use SafeRPC, service: :my_app, version: "1"

  @rpc true
  @doc "Return service status."
  @spec status(map(), map(), keyword()) :: {:ok, :ready | :degraded}
  def status(_payload, _meta, state) do
    {:ok, Keyword.get(state, :status, :ready)}
  end

  def helper, do: :not_exposed
end
```

Only public functions marked with `@rpc true` are exposed. `@rpc` functions must have arity 3:

```elixir
(payload, meta, state)
```

- `payload` is the request term.
- `meta` is per-request metadata sent by the client.
- `state` is the state returned by the service `init/1` callback.

Operation identity is native BEAM data:

```elixir
{MyApp.AdminRPC, :status}
```

Serve the service through the adapter server:

```elixir
defmodule MyApp.AdminRPCServer do
  use SafeRPC.Adapter.Server, service: MyApp.AdminRPC
end

{:ok, _pid} = MyApp.AdminRPCServer.start_link(socket: "/run/my-app/rpc.sock")
```

`use SafeRPC` also implements `SafeRPC.Adapter.Service`. Override `init/1` if the service needs runtime state:

```elixir
def init(opts), do: {:ok, Keyword.fetch!(opts, :repo)}
```

## Compile-time metadata

At compile time SafeRPC records:

- service name and version;
- exposed operation modules/functions;
- docs and specs for descriptors;
- atoms visible at RPC boundaries for safe ETF clients.

See [Atom vocabularies and safe ETF](atom-vocabularies.md).
