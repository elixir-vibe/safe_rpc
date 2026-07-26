# Security model

SafeRPC narrows the authority of BEAM-to-BEAM RPC. It is not a sandbox for arbitrary Internet clients.

## Intended boundary

The default Unix socket transport is intended for services on one trusted host. Restrict access with filesystem ownership and `socket_mode`, normally `0o660`, and grant access only to the operating-system accounts that should call the service.

A client that can connect may still send hostile or malformed bytes. SafeRPC therefore applies protocol-level defenses before dispatch:

- frames are decoded with `:erlang.binary_to_term/2` using `:safe`;
- executable terms such as anonymous functions are rejected;
- compressed ETF is rejected before decompression;
- encoded frames are limited to 16 MiB by default;
- request identifiers and metadata have constrained wire shapes;
- handler exceptions become an internal request error instead of terminating the listener.

Set a smaller limit where the service contract permits it:

```elixir
{MyApp.RPCServer,
 socket: "/run/my_app/rpc.sock",
 socket_mode: 0o660,
 max_frame_size: 1_048_576}
```

Clients should use the same limit:

```elixir
SafeRPC.call(socket, op, payload, max_frame_size: 1_048_576)
```

The frame limit bounds encoded bytes. Application handlers must still validate payload shape, collection sizes, binary sizes, identifiers, and domain values before doing expensive work.

## Authorization

An explicit operation surface is not the same as caller authentication. SafeRPC only dispatches declared operations, but capability checks are optional and the default authorizer allows requests.

Use all applicable layers:

1. Unix socket ownership and mode for the connection boundary.
2. A `SafeRPC.Capability` when a shared socket needs a token and operation scope.
3. An application authorizer for tenant, actor, resource, or policy decisions.
4. Validation inside every operation.

Do not trust identity, roles, or tenant data merely because the client placed them in request metadata. Derive identity from an authenticated deployment boundary or verify signed claims in the authorizer.

## Network exposure

SafeRPC 0.1 ships only the Unix socket transport. Do not expose ETF frames directly to the public Internet or tunnel an unauthenticated Unix listener through a public TCP port.

A future network transport must authenticate peers and encrypt traffic, normally with mutually authenticated TLS, before accepting application frames. Erlang distribution cookies are not a substitute for a capability-scoped SafeRPC boundary.

## Atom vocabularies

Safe ETF refuses to create unknown atoms. `SafeRPC.prepare/2` lets an authenticated client deliberately intern a bounded service vocabulary. Keep `max_atoms`, `max_atom_length`, and `allow` policies narrow for independently deployed services.

Prefer binaries for unbounded or user-controlled values. Never create dynamic atoms from request data.

## Remaining limits

SafeRPC's transport checks do not validate application semantics and do not make remote code trusted. Resource limits, deadlines, peer identity, transport encryption, and compatibility policy must be chosen for the deployment. See the protocol and authorization guides for the current wire behavior.
