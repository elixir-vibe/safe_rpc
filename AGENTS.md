# SafeRPC Agent Guidelines

## Development

```sh
mix ci
```

## Scope

- Keep SafeRPC generic and reusable outside HostKit.
- Prefer explicit operation APIs over client-controlled remote MFA.
- Decode untrusted wire terms with `:erlang.binary_to_term(binary, [:safe])`.
- Keep capability checks first-class and auditable.
- Preserve Unix socket support as the initial transport.
