# Authorization

SafeRPC has two runtime authorization layers on the server side.

## Capabilities

A capability is a token plus an operation scope:

```elixir
cap = SafeRPC.Capability.new(token: "secret", ops: [{MyApp.AdminRPC, :status}])

{:ok, _pid} =
  MyApp.AdminRPCServer.start_link(
    socket: "/run/my-app/rpc.sock",
    capability: cap
  )
```

The client sends the token per request:

```elixir
SafeRPC.call(socket, {MyApp.AdminRPC, :status}, %{}, cap: "secret")
```

Use `ops: :all` to allow every operation for that token.

Built-in operations such as `:safe_rpc_atoms` and `:safe_rpc_describe` are checked the same way. Include them explicitly if a restricted capability should allow discovery or atom preparation.

## Authorizers

An authorizer can inspect the full decoded request:

```elixir
defmodule MyApp.RPCAuthorizer do
  @behaviour SafeRPC.Authorizer

  def authorize(%{op: {MyApp.AdminRPC, :status}}, _context), do: :ok
  def authorize(_request, _context), do: {:error, :forbidden}
end
```

Configure it on the server:

```elixir
MyApp.AdminRPCServer.start_link(
  socket: "/run/my-app/rpc.sock",
  authorizer: MyApp.RPCAuthorizer,
  auth_context: %{service: :my_app}
)
```

SafeRPC intentionally does not define users, tenants, roles, sessions, or resource semantics. Those belong in the application authorizer.
