# RFC 0001: SafeRPC protocol v2

- **Status:** Proposed; initial design decisions recorded 2026-07-26
- **Audience:** SafeRPC maintainers, service authors, and transport/adapter authors
- **Target:** SafeRPC 0.2 development line
- **Supersedes:** Nothing. Protocol v1 remains documented and supported during migration.

## Summary

SafeRPC v2 defines a negotiated, bounded RPC session for explicit BEAM-to-BEAM service contracts. It keeps ETF and ordinary Elixir/Erlang values, but adds the lifecycle semantics expected from a production RPC boundary:

- a mandatory version and feature handshake;
- transport-derived peer identity and connection authentication;
- bounded concurrent execution under OTP supervisors;
- cancellation and relative deadlines;
- reconnecting clients without unsafe automatic replay;
- stable telemetry;
- bidirectional streaming with byte-credit flow control;
- dual-stack migration and cross-version conformance tests.

SafeRPC remains intentionally narrower than protobuf/gRPC. It is for systems where both peers run on the BEAM and can share term conventions. It does not define a polyglot schema language, code generator, public-Internet transport, service mesh, or arbitrary remote MFA.

## Motivation

Protocol v1 proves the basic model: framed ETF over a Unix socket, explicit operations, capabilities, and safe decoding. Its wire format is small and useful, but its runtime semantics are incomplete for a general service boundary:

- requests on one listener are dispatched through one mutable server process and therefore execute serially;
- cancelling the per-connection forwarding task does not necessarily stop service work;
- client timeouts are local and are not communicated as server deadlines;
- persistent clients stop when a connection closes and pools do not rebuild them;
- peers do not negotiate versions, features, or limits;
- request metadata cannot be treated as authenticated identity;
- streaming and flow control are absent;
- resource and telemetry contracts are not standardized.

Adding these concerns incrementally to the v1 tuple would make behavior depend on implicit client and server knowledge. V2 starts each connection with an explicit session contract instead.

## Design principles

1. **Explicit operations, never arbitrary MFA.** A wire operation identifies a declared service operation. Module/function dispatch is an implementation detail.
2. **OTP owns lifecycle.** Listeners, connections, calls, and stream producers run under supervisors with explicit shutdown behavior.
3. **Bound work before dispatch.** Frames, connections, in-flight calls, queued writes, stream windows, and lifetimes all have limits.
4. **Identity comes from authentication.** Client-supplied metadata is context, not proof of identity.
5. **No invisible retries.** A disconnected call may have run. SafeRPC does not replay it unless the contract and caller explicitly make replay safe.
6. **Backpressure crosses the socket.** A producer may not outrun the remote consumer.
7. **Protocol control terms are atom-safe.** All control atoms are fixed by the SafeRPC version. Unbounded identifiers and user values use binaries.
8. **Failure is data, process corruption is not.** Application failures become terminal statuses. Protocol violations close the affected connection, not the listener.
9. **Local transport first.** Unix sockets remain the reference transport. A network transport must provide authenticated encryption.
10. **Migration is deliberate.** V2 can share a listener with v1, but downgrade is never automatic.

## Non-goals

V2 does not attempt to provide:

- cross-language schemas or generated clients;
- transparent distributed processes;
- exactly-once execution;
- distributed transactions or rollback after cancellation;
- automatic atom creation from remote input;
- transparent load balancing across hosts;
- an Internet-facing ETF endpoint;
- compatibility with the gRPC wire protocol.

## Terminology

- **Transport connection:** A framed, ordered, reliable byte channel such as a Unix stream socket using four-byte packet framing.
- **Session:** The negotiated v2 state attached to one transport connection.
- **Principal:** Server-derived authenticated identity for a session.
- **Call:** One logical RPC identified by a connection-local request ID.
- **Direction:** `:request` or `:response` within a call.
- **Terminal frame:** The one frame that completes a call: `:complete` or `:cancelled`.
- **Contract ID:** A stable binary service name plus operation name, independent of BEAM module names.

## Encoding and framing

V2 uses uncompressed ETF with `ETF_VERSION = 131`. The Unix reference transport continues to use `packet: 4`, so the four-byte transport prefix is not part of the ETF payload.

Every frame has this outer shape:

```elixir
{:safe_rpc, 2, frame_type, frame_body}
```

`frame_type` is one of the fixed atoms defined in this RFC. `frame_body` is a tuple or map whose structural atoms are also fixed by the protocol implementation. Service names, operation names, feature names, status details, trace identifiers, and other open-ended values are binaries.

Decoders must:

1. enforce the negotiated frame limit before allocating or decoding the payload;
2. reject compressed ETF;
3. decode with non-executable safe ETF semantics;
4. validate the complete frame shape before dispatch;
5. reject unknown control frame types;
6. close the connection on a malformed control frame.

User payloads remain ordinary terms. Independently deployed peers should prefer binary map keys and binary enum values. Atom-rich contracts may use the bounded vocabulary mechanism after authentication, but vocabulary preparation is not part of the handshake and must not weaken safe decoding.

## Handshake

The first client frame on a v2 connection must be `:hello`. No application request may precede it.

Illustrative shape:

```elixir
{:safe_rpc, 2, :hello,
 %{
   nonce: client_nonce,
   versions: [2],
   required_features: ["deadlines"],
   optional_features: ["streaming", "atom-vocabulary"],
   limits: %{frame_bytes: 1_048_576, in_flight: 32, stream_window_bytes: 262_144},
   authentication: authentication_data,
   client: %{name: "incant", version: "0.2.0"}
 }}
```

The server must answer with either `:welcome` or `:reject` before processing other frames.

```elixir
{:safe_rpc, 2, :welcome,
 %{
   nonce: client_nonce,
   session_id: session_id,
   version: 2,
   features: ["deadlines", "streaming"],
   limits: %{frame_bytes: 1_048_576, in_flight: 16, stream_window_bytes: 131_072},
   server: %{name: "llm_proxy", version: "0.1.1"}
 }}
```

```elixir
{:safe_rpc, 2, :reject,
 %{code: :unsupported_version, message: "no mutually supported protocol version"}}
```

The negotiated numeric limit is the lower of the client request and server policy. The server may lower a limit but may not raise it above the client request. A missing required feature rejects the handshake. Optional features are the intersection of both peers.

The server applies a short handshake deadline, 5 seconds by default. Pre-handshake connections count against a separate low limit so idle clients cannot consume the normal connection budget.

The `client` and `server` maps are diagnostic metadata. They are not identity and must not affect authorization.

### Feature names

Initial feature names are:

- `"deadlines"`
- `"cancellation"`
- `"streaming"`
- `"atom-vocabulary"`
- `"descriptors"`

Feature names are binaries so adding one does not require interning a new atom. An implementation must not send frames belonging to a feature that was not negotiated.

## Service and operation identity

V2 operations are identified on the wire by two UTF-8 binaries:

```elixir
%{service: "llm_proxy.admin.v1", operation: "list_provider_tokens"}
```

The pair is stable API identity. A server registry maps it to a local adapter and function. V2 does not accept a client-selected module/function tuple.

A v2 service must declare its binary service ID explicitly. IDs are 1 to 128 bytes and use lowercase ASCII segments matching `[a-z][a-z0-9_.-]*`. This makes ownership and versioning visible in source rather than coupling the contract to a module name. Existing atom service names remain valid on the v1 path only.

An operation ID defaults to the exposed Elixir function name converted to a binary and may be overridden with `@rpc name: "..."`. It has the same 128-byte bound and may use a final `?` or `!`. Renaming a module does not change the wire contract. Renaming a function is breaking unless the previous operation ID is retained explicitly or registered as an alias.

A service version belongs in the service ID or an explicit descriptor version. Payload evolution follows application policy; SafeRPC does not infer compatibility from Elixir typespecs.

## Session identity and authorization

Authentication occurs once during the handshake and produces a server-owned principal. Request authorization receives that principal, transport facts, negotiated session information, and untrusted request metadata as separate values.

Conceptually:

```elixir
%SafeRPC.Context{
  principal: %{id: "toys-incant-admin", mechanism: :unix_peer},
  peer: %{transport: :unix, uid: 991, gid: 991},
  session_id: session_id,
  metadata: request_metadata
}
```

The exact principal shape is application-defined. SafeRPC must preserve the distinction between authenticated fields and client metadata.

### Unix sockets

Filesystem ownership and mode remain the first connection boundary. The transport exposes an optional `peer_identity/1` callback whose result is server-owned context, never client metadata.

On Linux, the reference Unix transport reads `SO_PEERCRED` from the accepted socket and records the kernel-supplied PID, UID, and GID. Erlang's [`:socket`](https://www.erlang.org/docs/29/apps/kernel/socket) API exposes `peercred` only when the OTP build reports that option as supported. The supported production OTP 29 build does not, while the existing `:gen_tcp` socket can read Linux `struct ucred` through a raw `getsockopt`. The implementation must therefore be explicitly Linux-specific, check the operating system and returned structure size, and fail closed when `peer_identity: :required` cannot be satisfied.

The portable fallback is a connection token in `:hello`, protected by Unix socket permissions. There is no silent fallback when configuration requires kernel peer identity. `:optional` mode may expose `%{mechanism: :unix_socket}` without UID/GID and leave authentication to the token hook.

Capability tokens presented during the handshake are bound to the resulting session and compared in constant time. They are not copied into every request or telemetry event. A service may still require a narrower per-call authorization value, but that value is application data and must be verified by the authorizer.

### Future network transports

A TCP transport is not conforming unless it authenticates and encrypts peers, normally with mutual TLS. The transport supplies the certificate identity to the same authentication hook. Erlang distribution cookies are not a SafeRPC authentication mechanism.

Authentication failures return a generic `:unauthenticated` rejection and close the connection. Logs may record a local diagnostic reason but must not include credentials.

## Request lifecycle

A unary request uses `:open` followed by one terminal `:complete` frame.

```elixir
{:safe_rpc, 2, :open,
 %{
   id: 42,
   service: "inventory.v1",
   operation: "lookup",
   mode: :unary,
   payload: %{"id" => "123"},
   metadata: %{"traceparent" => traceparent},
   timeout_ms: 2_000
 }}
```

```elixir
{:safe_rpc, 2, :complete,
 %{id: 42, status: :ok, payload: %{"name" => "keyboard"}, trailers: %{}}}
```

Request IDs are non-negative integers unique among active calls on one connection. Reusing an active ID is a protocol violation and closes the connection. IDs may be reused only after a terminal frame has been processed by both sides.

V2 has no separate cast primitive. A command that only needs acknowledgement is a unary call returning an empty or small result. This gives overload, authorization, and failure a deterministic response. A future negotiated `"oneway"` feature may add lossy fire-and-forget semantics, but it is not part of this RFC.

## Execution model

The listener owns no application request execution. The recommended supervision tree is:

```text
SafeRPC.Server.Supervisor
├── listener
├── connection supervisor
├── request Task.Supervisor
└── optional stream producer supervisor
```

After validation and authorization, a connection starts request work under the request supervisor. Connections monitor request workers; request workers do not link directly to the listener. Validation and authorization happen after acquiring an in-flight slot so expensive authorization cannot bypass global concurrency limits.

The receive path must also apply backpressure. A receiver may hand off at most one unprocessed frame at a time, or use an explicitly bounded queue; it may not continuously copy socket frames into an unbounded connection-process mailbox.

### Stateless dispatch boundary

Concurrent v2 adapters receive immutable startup context and return a result. They do not return a replacement server state. Mutable domain state belongs in normal OTP processes, repositories, registries, or application supervisors.

This keeps request concurrency explicit and avoids copying or racing hidden listener state. The existing state-returning v1 callback remains serialized on the v1 compatibility path. A service must opt into the concurrent v2 adapter contract before advertising v2.

### Bounds and overload

Servers define at least:

- maximum connections;
- maximum pre-handshake connections;
- maximum in-flight calls per connection;
- maximum in-flight calls across the listener;
- maximum frame bytes;
- maximum metadata bytes;
- handshake and idle timeouts;
- maximum stream lifetime;
- maximum queued inbound and outbound bytes per connection.

V2 does not require an unbounded request queue. When an in-flight limit is reached, the server returns `:resource_exhausted` without starting application work. Implementations may provide a small bounded queue as an explicit option with queue-time telemetry.

Connection scheduling should prevent one connection from monopolizing the global worker budget.

## Deadlines

Deadlines are relative budgets, not wall-clock timestamps. `timeout_ms` is the remaining client budget when the `:open` frame is sent. Relative time avoids assuming synchronized monotonic clocks across VMs.

The server starts its timer after accepting and validating `:open`, clamps the budget to its configured maximum, and passes a monotonic deadline in the request context. A proxy subtracts locally elapsed time before forwarding.

When the deadline expires, the server:

1. marks the call terminal;
2. terminates the supervised request worker;
3. closes any stream producer for that call;
4. sends `:complete` with `:deadline_exceeded` if the connection is writable;
5. discards any later worker result.

The request context exposes the deadline and cancellation signal so adapters can propagate them to downstream work. Terminating the SafeRPC worker cannot retract a message already accepted by another process or stop independently spawned work.

A deadline cannot undo side effects that already happened. Operations that need replay or transactional guarantees must implement them at the application layer.

## Cancellation

A client may cancel an active call:

```elixir
{:safe_rpc, 2, :cancel, %{id: 42, reason: :client_cancelled}}
```

Cancellation is best effort. The server signals cancellation, terminates the supervised worker, closes registered stream producers, and responds exactly once:

```elixir
{:safe_rpc, 2, :cancelled, %{id: 42, status: :cancelled}}
```

If completion wins the race, the normal `:complete` frame is terminal and a later `:cancel` is ignored. If cancellation wins, a later worker result is discarded. The connection state machine, not the worker mailbox, chooses the terminal outcome.

As with deadlines, cancellation does not retract work already accepted by another process. Service adapters should propagate the request context and register owned subprocesses when they need stronger cooperative cancellation.

Closing a connection cancels all of its active work unless an operation was explicitly configured as detached. Detached operations are out of scope for the first v2 implementation.

## Status model

`:complete.status` is one of these fixed atoms:

- `:ok`
- `:cancelled`
- `:unknown_service`
- `:unknown_operation`
- `:invalid_argument`
- `:deadline_exceeded`
- `:unauthenticated`
- `:permission_denied`
- `:resource_exhausted`
- `:failed_precondition`
- `:unavailable`
- `:internal`

Application-specific error information belongs in `payload` and must follow the declared service contract. Internal exceptions map to `:internal`; stacktraces and arbitrary exception text never cross the wire by default.

Protocol-shape errors are connection errors, not application statuses. The server may send a bounded `:protocol_error` control frame when safe to do so, then closes the connection.

## Streaming and flow control

Streaming is negotiated with `"streaming"`. A stream call uses `mode: :stream` and has independently flow-controlled request and response directions. The client's `:open` frame grants an initial `response_window_bytes`; the opening payload is bounded by the normal frame limit and does not consume stream credit. After accepting the call, the server grants request-direction credit with a `:window` frame. A side that will send no more data half-closes its direction immediately.

Data frames are ordered by sequence number:

```elixir
{:safe_rpc, 2, :data,
 %{id: 42, direction: :response, sequence: 0, payload: chunk}}
```

A sender may transmit data only when it has byte credit for that direction:

```elixir
{:safe_rpc, 2, :window,
 %{id: 42, direction: :response, bytes: 65_536}}
```

Credit counts the encoded ETF frame bytes, not the decoded object size. Sending data beyond available credit is a protocol violation. Each window update adds credit to the remaining balance and must itself be rate-limited.

The receiver replenishes credit only when application code consumes data, not when the transport decodes or enqueues it. This makes the negotiated window a real bound when an application stalls. Elixir streaming APIs may grant credit in bounded batches as `Enumerable` demand advances; the runtime may buffer no more than the granted window plus one frame currently being decoded.

Either side half-closes one direction:

```elixir
{:safe_rpc, 2, :half_close, %{id: 42, direction: :request}}
```

The server still ends the call with one `:complete` frame. Cancellation and deadlines apply to the whole call and release all stream resources.

The first implementation may expose unary and server-streaming APIs while retaining the bidirectional wire state machine. Gatehouse's HTTP data plane must not migrate until request-body and response-body streaming, bounded buffering, cancellation, and backpressure have conformance coverage.

A connection has one bounded writer process or equivalent serialized send path. Worker processes never write directly to the socket. Control frames have a small reserved budget so completion, cancellation, and window updates cannot be permanently blocked by data, but control traffic is still bounded.

## Client lifecycle and reconnect

A persistent client is a connection manager with these states:

```text
:disconnected -> :connecting -> :handshaking -> :ready
       ^                                      |
       +---------- :backoff <-----------------+
```

Startup may succeed in `:disconnected` mode when `connect: :async` is configured. Reconnect uses bounded exponential backoff with jitter. Pools supervise logical client slots and replace failed connection processes; pool startup does not pattern-match on every socket being available.

When a connection closes, active calls fail with `:unavailable` and an outcome marker:

- `:not_sent` — the request was never accepted by the local writer;
- `:unknown` — any part of the request may have reached the server.

SafeRPC never retries `:unknown` automatically. An operation descriptor may declare `idempotent: true`, and a caller may opt into retry. Exactly-once behavior would require an application idempotency key and bounded server deduplication; it is not provided by the transport.

One-shot calls perform the same handshake and deadline processing but do not reconnect.

## Telemetry

V2 standardizes these events:

```elixir
[:safe_rpc, :connection, :start]
[:safe_rpc, :connection, :stop]
[:safe_rpc, :handshake, :stop]
[:safe_rpc, :request, :start]
[:safe_rpc, :request, :stop]
[:safe_rpc, :request, :exception]
[:safe_rpc, :stream, :stop]
[:safe_rpc, :reconnect, :attempt]
```

Durations use monotonic native time. Useful measurements include `duration`, `queue_duration`, `bytes_in`, `bytes_out`, and `chunks`. Metadata may include protocol version, transport, service ID, operation ID, status, negotiated features, and a low-cardinality peer classification.

Telemetry must not include payloads, capability tokens, authentication data, raw exception terms, user IDs, or arbitrary request metadata by default. Applications may attach tracing context through a separate explicit hook.

## Descriptors and atom vocabularies

Descriptor discovery is an authenticated built-in service, not a pre-authentication handshake side effect. V2 descriptors use binary service and operation IDs and include:

- service version;
- operation mode (`:unary` or `:stream`);
- idempotency declaration;
- timeout recommendation;
- documentation and opaque application metadata;
- optional atom vocabulary endpoint.

Descriptors are introspection, not an executable schema and not proof of compatibility. A client may cache a descriptor keyed by service version or digest.

Atom vocabulary responses remain bounded lists of strings. The client applies allowlists and size limits before interning. Streaming does not allow atom vocabulary changes midway through a call.

## V1 compatibility and downgrade policy

A dual-stack server distinguishes protocols by the first decoded frame:

- a valid v2 `:hello` enters the v2 handshake;
- a valid v1 request enters the existing v1 connection path;
- anything else closes the connection.

One connection never mixes versions. V1 retains its existing tuple shapes and serialized stateful dispatcher.

A v2 client does not silently retry with v1 after handshake rejection or connection close. Downgrade requires explicit configuration such as `protocols: [2, 1]`, and security-sensitive deployments should use `protocols: [2]` after migration.

The v1 and v2 decoders share frame, ETF, executable-term, and compression defenses.

Every 0.2.x server release remains dual-stack. Early 0.2 clients use v1 by default with explicit v2 opt-in; v2 becomes the default only after Gatehouse, Incant, and llm_proxy have completed production dogfooding. V1 removal may occur no earlier than 0.3.0, 90 days after the first stable v2 release, and after at least two published 0.2 releases with v2 enabled. Removal requires a separately announced breaking release.

## Compatibility rules

Protocol compatibility and service compatibility are separate.

For protocol v2:

- unknown frame types are errors unless introduced behind a negotiated feature;
- map fields documented as optional may be ignored when unknown;
- changing a required field or its type requires a new protocol version;
- fixed status atoms may only be added in a new protocol version or negotiated feature.

For service contracts:

- adding an operation is compatible;
- adding optional binary-keyed payload fields is normally compatible;
- removing or renaming an operation is breaking;
- changing payload meaning, stream mode, or authorization semantics is breaking;
- module refactors are compatible when binary contract IDs remain stable.

Services should use explicit versioned IDs for breaking changes, for example `"inventory.v1"` and `"inventory.v2"`.

## Conformance requirements

V2 is not complete until the repository has a transport-independent conformance suite covering:

1. client and server in separate OS processes and separate BEAM VMs;
2. supported OTP versions;
3. v1 client to dual-stack server;
4. v2 client to dual-stack server;
5. explicit downgrade behavior;
6. malformed, oversized, compressed, executable, and unknown-atom frames;
7. handshake timeout, unsupported version, and missing required feature;
8. authenticated identity separation from metadata;
9. global and per-connection overload;
10. concurrent calls proving no listener-wide serialization;
11. cancellation/completion and deadline/completion races with exactly one terminal outcome;
12. disconnect outcomes and no default replay;
13. stream ordering, half-close, credit exhaustion, and bounded writer queues;
14. listener survival after connection and handler failures;
15. telemetry shape and secret exclusion.

Golden ETF fixtures should be generated from canonical terms and checked into the test suite with readable term representations. At least the previous released minor version and current development version should be tested against each other.

Performance tests should report throughput, tail latency, scheduler utilization, reductions while idle, and memory under slow-consumer streams. They are evidence, not substitutes for semantic tests.

## Implementation sequence

### Phase 1: runtime foundations

- Introduce listener, connection, request, and writer supervisors.
- Add connection/global limits and a stateless concurrent adapter.
- Add telemetry and durable independent-VM tests.
- Keep the v1 wire format.

### Phase 2: negotiated unary v2

- Add `:hello`, `:welcome`, and `:reject`.
- Add binary service/operation registry and v2 descriptors.
- Add authenticated session context.
- Implement unary `:open` and `:complete`.
- Ship a dual-stack server and explicit client protocol policy.

### Phase 3: lifecycle reliability

- Add relative deadlines and supervised cancellation.
- Add reconnecting clients and resilient pools.
- Add overload/fairness tests and disconnect outcome reporting.

### Phase 4: streaming

- Add data, window, half-close, and bounded writer state machines.
- Expose unary, server-streaming, and then bidirectional APIs.
- Add slow-consumer and cancellation conformance tests.

### Phase 5: ecosystem adoption

- Migrate Gatehouse's Erlang-distribution control plane first.
- Keep Gatehouse's HTTP SafeRPC data plane buffered until bidirectional streaming is verified.
- Migrate Incant and llm_proxy with v2-only production policy after dual-stack dogfooding.
- Remove v1 only in a separately announced breaking release.

## Gatehouse role

Gatehouse is the preferred first architectural showcase because its control operations are explicit, low-volume, and naturally capability-scoped. Replacing broad Erlang-distribution control calls demonstrates SafeRPC's value without making streaming a prerequisite.

Gatehouse's HTTP forwarding path is a different workload. It must preserve request and response streaming, disconnect cancellation, headers/trailers, and backpressure. A buffered SafeRPC forwarder is not parity and should not be presented as the final data-plane design.

## Recorded decisions

The initial review resolves the five design questions as follows:

1. **Unix identity:** expose transport peer identity, implement Linux `SO_PEERCRED` with strict platform/shape checks, and use handshake tokens as the portable fallback. Required peer identity fails closed.
2. **Contract names:** require an explicit binary service ID; derive the operation ID from the function name unless `@rpc name:` overrides it. Module names never appear in v2 requests.
3. **Stream credit:** replenish bytes when application code consumes chunks. Transport receipt alone does not grant more credit.
4. **Dependency boundary:** the v2 core targets direct dependencies on `plug_crypto` for non-executable ETF decoding and `telemetry` for events. `SafeRPC.Adapter.Plug` and its HTTP envelope modules move to a separate `safe_rpc_plug` package before 0.2.0. SafeRPC must not copy Plug.Crypto's security-sensitive traversal without an independently reviewed replacement.
5. **V1 window:** all 0.2.x servers are dual-stack. V2 becomes the client default only after first-party production dogfooding, and v1 cannot be removed before the separately announced 0.3.0 conditions described above.

These are protocol decisions, not claims that the current v1 implementation already provides them. A prototype may return a decision to Proposed if platform or interoperability evidence disproves an assumption; the RFC must record that change explicitly.

## Acceptance criteria

This RFC may move from Proposed to Accepted when:

- prototypes validate the recorded peer-identity, naming, flow-control, and package-boundary decisions;
- a prototype proves bounded concurrent unary calls and effective cooperative cancellation;
- Unix peer identity behavior is covered on the supported deployment platform;
- the independent-VM conformance harness runs in CI;
- Gatehouse, Incant, and llm_proxy maintainers confirm the migration path.
