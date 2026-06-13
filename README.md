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

SafeRPC intentionally does not expose client-selected MFA on the wire. Clients call named operations:

```elixir
SafeRPC.call(client, :status, %{})
```

Internally, SafeRPC may route an operation to MFA later, but authorization remains operation/resource-oriented rather than module-oriented.

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
