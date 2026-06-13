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
- one-shot and client-process `call` / `cast`
- `use SafeRPC.Server` callback wrapper
- per-request capability checks

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
```

## Capability checks

```elixir
cap = SafeRPC.Capability.new(token: "secret", ops: [:echo])
{:ok, pid} = EchoServer.start_link(socket: "/tmp/echo.sock", capability: cap)

{:ok, :allowed} = SafeRPC.call("/tmp/echo.sock", :echo, :allowed, cap: "secret")
{:error, :unauthorized} = SafeRPC.call("/tmp/echo.sock", :count, %{}, cap: "secret")
```

## Design direction

SafeRPC should borrow scalability patterns from `priestjim/gen_rpc` without adopting its public remote-MFA trust model:

- persistent client connections
- acceptor/connection/request-worker supervision
- per-key sharded client pools
- async call/yield
- multicall/fanout
- transport behaviour for Unix/TCP/TLS/stdio

The wire API should remain explicit operation dispatch, with MFA only as an internal routing implementation detail.
