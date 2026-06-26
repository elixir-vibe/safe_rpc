# Clients

Clients run in the calling BEAM at runtime.

## One-shot calls

A one-shot call opens a socket, sends one request, waits for one reply, and closes the socket.

```elixir
{:ok, status} = SafeRPC.call("/run/my-app/rpc.sock", {MyApp.AdminRPC, :status})
```

Pass a payload and metadata when needed:

```elixir
SafeRPC.call(socket, {MyApp.AdminRPC, :lookup}, %{id: "123"}, meta: %{trace_id: "abc"})
```

## Persistent clients

Use a persistent client process when making multiple calls:

```elixir
{:ok, client} = SafeRPC.Client.start_link(socket: "/run/my-app/rpc.sock")

{:ok, status} = SafeRPC.call(client, {MyApp.AdminRPC, :status})
{:ok, item} = SafeRPC.call(client, {MyApp.AdminRPC, :lookup}, %{id: "123"})
```

## Casts

Casts send a request and return the server acknowledgement:

```elixir
{:ok, :noreply} = SafeRPC.cast(client, {MyApp.AdminRPC, :refresh}, %{scope: :all})
```

## Async requests

```elixir
task = SafeRPC.async(client, {MyApp.AdminRPC, :slow_report}, %{range: "24h"})
{:ok, report} = SafeRPC.await(task, 10_000)
```

Use `yield/2` and `cancel/1` for non-blocking waits and cancellation.

## Atom preparation

If replies can contain atoms not yet present in the client VM, prepare the client before the first atom-rich call:

```elixir
:ok = SafeRPC.prepare(client, max_atoms: 1_000, max_atom_length: 128)
```

Preparation asks the server for its compile-time vocabulary as strings, validates it on the client, and interns accepted atoms so later replies can be decoded with safe ETF.

See [Atom vocabularies and safe ETF](atom-vocabularies.md).
