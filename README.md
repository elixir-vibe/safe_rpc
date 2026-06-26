# SafeRPC

SafeRPC is a GenServer-like RPC protocol for explicit, capability-scoped APIs over Erlang external term format.

It is intended for boundaries where both sides want BEAM-native terms without HTTP overhead, but where regular Erlang distribution or raw remote MFA would expose too much authority.

## Current status

Early prototype.

Implemented:

- Unix socket transport
- transport behaviour
- packet-framed ETF requests
- `:erlang.binary_to_term(binary, [:safe])` decoding
- one-shot and persistent client-process `call` / `cast`
- persistent server-side connections
- request id tracking for multiple in-flight client requests
- sharded client pools
- Task-like async requests with `async`, `await`, `yield`, and `shutdown`
- `use SafeRPC.Server` callback wrapper
- per-request capability checks
- optional generic authorizer hook
- request cancellation
- framework-agnostic adapter behaviours and HTTP envelopes
- optional bounded atom vocabulary preparation for independent safe ETF clients

## Example

```elixir
defmodule EchoServer do
  use SafeRPC.Server

  def init(opts), do: {:ok, %{count: Keyword.get(opts, :count, 0)}}

  def handle_call(:echo, payload, state), do: {:reply, {:ok, payload}, state}
  def handle_call(:count, _payload, state), do: {:reply, {:ok, state.count}, state}

  def handle_cast(:inc, amount, state), do: {:noreply, %{state | count: state.count + amount}}
end

{:ok, server} = EchoServer.start_link(socket: "/tmp/echo.sock")
{:ok, client} = SafeRPC.Client.start_link(socket: "/tmp/echo.sock")

{:ok, %{hello: :world}} = SafeRPC.call(client, :echo, %{hello: :world})
{:ok, :noreply} = SafeRPC.cast(client, :inc, 1)
{:ok, 1} = SafeRPC.call(client, :count)

request = SafeRPC.async(client, :echo, %{hello: :async})
{:ok, %{hello: :async}} = SafeRPC.await(request, 5_000)

long_request = SafeRPC.async(client, :long_operation, %{}, timeout: 30_000)
:ok = SafeRPC.cancel(long_request)

{:ok, pool} = SafeRPC.ClientPool.start_link(socket: "/tmp/echo.sock", shards: 4)
{:ok, 1} = SafeRPC.ClientPool.call(pool, {:tenant, :alice}, :count)
```

## Authorization

SafeRPC has two generic authorization layers:

1. token/operation capability checks with `SafeRPC.Capability`
2. an optional authorizer callback


```elixir
cap = SafeRPC.Capability.new(token: "secret", ops: [:echo])
{:ok, pid} = EchoServer.start_link(socket: "/tmp/echo.sock", capability: cap)

{:ok, :allowed} = SafeRPC.call("/tmp/echo.sock", :echo, :allowed, cap: "secret")
{:error, :unauthorized} = SafeRPC.call("/tmp/echo.sock", :count, %{}, cap: "secret")
```

For app-specific policy, pass an authorizer module:

```elixir
defmodule MyAuthorizer do
  @behaviour SafeRPC.Authorizer

  def authorize(%{op: :status}, _context), do: :ok
  def authorize(_request, _context), do: {:error, :forbidden}
end

{:ok, server} = EchoServer.start_link(socket: "/tmp/echo.sock", authorizer: MyAuthorizer)
```

SafeRPC does not define users, tenants, roles, sessions, or resource semantics. Those belong in the application authorizer.

## Comparison with existing options

### Erlang distribution / `:rpc` / `:erpc`

Erlang distribution is the most native way to talk between BEAM nodes, but it is designed for trusted clusters. Once nodes are connected, the trust boundary is broad: remote process interaction, code loading assumptions, global names, and cookie-based node authentication are intentionally powerful.

SafeRPC is narrower. It uses Erlang terms, but exposes only explicit operations handled by a server callback module.

Use Erlang distribution when all nodes are trusted peers. Use SafeRPC when the remote side should only get a small, auditable API surface.

### `priestjim/gen_rpc`

[`gen_rpc`](https://github.com/priestjim/gen_rpc) is a scalable replacement-style library for Erlang `rpc`. It provides TCP/SSL transports, async calls, multicall, per-key sharding, and module allow/deny lists.

Its public API is remote MFA:

```erlang
gen_rpc:call(Node, Module, Function, Args).
```

SafeRPC intentionally does not expose arbitrary client-selected MFA on the wire. Services built with `use SafeRPC` expose explicitly marked module/function pairs:

```elixir
SafeRPC.call(client, {MyApp, :status}, %{})
```

Adapter services may still define their own operation terms, but `use SafeRPC` keeps operation identity aligned with Elixir modules and functions.

SafeRPC borrows ideas from `gen_rpc`—persistent connections, acceptor/connection supervision, async requests, sharding, and fanout—but keeps the protocol smaller and capability-scoped.

### HTTP / JSON APIs

HTTP is the best default for public APIs, browser clients, proxies, and language-neutral integrations. It has excellent tooling and operational visibility.

SafeRPC is for BEAM-native or local control-plane APIs where HTTP routing, JSON encoding, headers, and text parsing are unnecessary overhead. Payloads are Erlang external terms, decoded with:

```elixir
:erlang.binary_to_term(binary, [:safe])
```

### gRPC

gRPC is a strong choice for polyglot service APIs with schema-first contracts, streaming, and mature client generation.

SafeRPC is smaller and BEAM-focused. It does not require protobuf schemas and preserves Elixir/Erlang terms, but it is not intended as a universal cross-language RPC layer.

## Local binding terms

Local service discovery metadata is a plain Erlang term encoded as ETF:

```elixir
binary = :erlang.term_to_binary(bindings)
bindings = :erlang.binary_to_term(binary, [:safe])
```

The standard binding term is a map from service name to connection metadata:

```elixir
%{
  catalog: %{
    socket: "/run/apps/catalog/rpc.sock",
    modules: [Catalog.API, Catalog.Admin],
    listener: :rpc,
    upstream: "unix:/run/apps/catalog/rpc.sock",
    unit: "app-catalog.service"
  }
}
```

Only `:socket` is required by SafeRPC. `:modules` is the module-level capability metadata exposed by the deployer; exact callable functions still come from `SafeRPC.describe/2`. Other keys are operational metadata for supervisors, deploy tools, and diagnostics.

A consumer should get the ETF path from its runtime environment or convention and then call SafeRPC directly:

```elixir
bindings =
  System.fetch_env!("HOSTKIT_RPC_BINDINGS")
  |> File.read!()
  |> :erlang.binary_to_term([:safe])

SafeRPC.call(bindings.catalog.socket, {Catalog.API, :status})
```

SafeRPC does not require a binding-file loader module; the file is just an ETF-encoded `SafeRPC.local_bindings()` term.

## Elixir-native services

Use `SafeRPC` directly in an application module when you want a small Erlang-distribution-like API without exposing arbitrary remote MFA. Only functions marked with `@rpc` are callable; operation identity is `{Module, function}`.

```elixir
defmodule MyApp do
  use SafeRPC, service: :my_app

  @rpc true
  @doc "Return available models."
  @spec models(map(), map(), term()) :: {:ok, [map()]} | {:error, term()}
  def models(_payload, _meta, _state), do: {:ok, [%{id: "small"}]}

  @rpc true
  @doc "Return service status."
  @spec status(map(), map(), term()) :: {:ok, map()}
  def status(_payload, _meta, state), do: {:ok, %{state: state}}

  def local_helper, do: :not_exposed
end
```

Serve it with the normal adapter server wrapper:

```elixir
defmodule MyApp.RPCServer do
  use SafeRPC.Adapter.Server, service: MyApp
end
```

Call operations normally:

```elixir
{:ok, models} = SafeRPC.call(socket, {MyApp, :models})
```

Discover the exposed service descriptor:

```elixir
{:ok, descriptor} = SafeRPC.describe(socket)
descriptor.modules[MyApp].ops.models.docs
```

Descriptors include exposed modules, operation names, docs from `@doc`, and typespec metadata from `@spec`. SafeRPC does not define a separate schema language; adapters can translate Elixir typespec metadata to other protocols if needed.

Independent clients that decode replies with safe ETF may need service-specific atoms to exist before calling operations that return atom-rich terms. Declare a bounded vocabulary on the service:

```elixir
defmodule MyApp do
  use SafeRPC, service: :my_app, atoms: [:small, :large, :ready]

  @rpc true
  @spec status(map(), map(), term()) :: {:ok, :ready}
  def status(_payload, _meta, _state), do: {:ok, :ready}
end
```

Prepare the client with validation limits before those calls:

```elixir
:ok =
  SafeRPC.prepare(socket,
    max_atoms: 1_000,
    max_atom_length: 128,
    allow: [~r/^[a-z][a-z0-9_]*$/]
  )
```

`SafeRPC.prepare/2` first asks the service for atom names as strings, validates the count, length, and optional allow policy, then interns accepted atoms. SafeRPC also includes operation module/function atoms and best-effort literal atoms from RPC typespecs, but dynamic/domain atoms should be declared explicitly with `:atoms`.

For HTTP forwarding, expose an operation such as `:http_request` with `@rpc` the same way as any other operation.

## Adapter layer

SafeRPC includes a small framework-agnostic adapter namespace. The core adapter layer does not depend on Phoenix, Ash, Livery, or any web framework.

Use `SafeRPC.Adapter.Service` to expose application operations:

```elixir
defmodule MyService do
  @behaviour SafeRPC.Adapter.Service

  def init(_opts), do: {:ok, %{}}

  def call(:status, _payload, meta, state) do
    {:ok, %{status: :ok, meta: meta, state: state}}
  end
end

defmodule MyRPCServer do
  use SafeRPC.Adapter.Server, service: MyService
end

{:ok, server} = MyRPCServer.start_link(socket: "/tmp/my.sock")
{:ok, %{status: :ok}} = SafeRPC.call("/tmp/my.sock", :status, %{}, meta: %{trace_id: "..."})
```

For route tables, use `SafeRPC.Adapter.Dispatcher` with explicit op-to-MFA mappings:

```elixir
routes = %{
  status: {MyAPI, :status, 3},
  user_by_id: {MyAPI, :user_by_id, 3}
}

SafeRPC.Adapter.Dispatcher.call(routes, :status, payload, meta, state)
```

For HTTP bridges, use the neutral envelopes:

```elixir
%SafeRPC.Adapter.HTTP.Request{}
%SafeRPC.Adapter.HTTP.Response{}
```

Framework-specific code should mostly live outside SafeRPC:

- xamal_proxy: Livery request/response <-> SafeRPC adapter HTTP envelopes
- Plug/Phoenix: adapter HTTP envelope <-> Plug endpoint via `SafeRPC.Adapter.Plug`
- Ash: adapter service operation <-> Ash action

The Plug adapter is included because Phoenix endpoints are Plug endpoints and the dependency boundary remains generic Plug, not Phoenix-specific.

## Design direction

SafeRPC should borrow scalability patterns from `priestjim/gen_rpc` without adopting its public remote-MFA trust model:

- persistent client connections
- acceptor/connection supervision
- request-worker supervision for long-running handlers
- per-key sharded client pools
- async call/yield
- multicall/fanout
- transport behaviour for Unix/TCP/TLS/stdio

The wire API should remain explicit operation dispatch, with MFA only as an internal routing implementation detail.
