# Local bindings

Deployers can describe local SafeRPC sockets with a plain ETF term. SafeRPC does not require a binding loader; the file is just operational metadata.

Example binding term:

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

Only `:socket` is required by SafeRPC. Other keys are for deploy tools, supervisors, diagnostics, and application-specific discovery.

A trusted local deployer can write the term:

```elixir
File.write!(path, :erlang.term_to_binary(bindings))
```

A consumer can read it and call the socket:

```elixir
bindings =
  System.fetch_env!("HOSTKIT_RPC_BINDINGS")
  |> File.read!()
  |> :erlang.binary_to_term([:safe])

SafeRPC.call(bindings.catalog.socket, {Catalog.API, :status})
```

If binding metadata itself contains atoms unknown to the consumer VM, the application may decode trusted local binding files with normal ETF. That trust decision belongs to the application/deployer boundary, not the SafeRPC wire protocol.
