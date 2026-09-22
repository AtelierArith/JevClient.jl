# Repository Guidelines

## Project Structure & Module Organization

This is a Julia 1.10+ package for the TypeSafe AI System One API.

- `src/JevClient.jl` defines the module, imports, includes, and public exports.
- `src/` contains focused implementation files for credentials, transport, request
  serialization, question types, response validation, errors, and client policy.
- `test/runtests.jl` contains unit and mock-transport tests.
- `docs/agents/spec.md` is the wire and behavior specification; update it when
  changing public behavior.
- `docs/agents/SECURITY.md` documents security expectations.

## Build, Test, and Development Commands

Run the package test suite from the repository root:

```sh
julia --project=. -e 'using Pkg; Pkg.test()'
```

Install dependencies first when using a fresh environment:

```sh
julia --project=. -e 'using Pkg; Pkg.instantiate()'
```

Run the focused test file directly with `julia --project=. test/runtests.jl`.
For static review, run JuliaCheck against `src/` using the locally installed
JuliaCheck environment.

## Coding Style & Naming Conventions

Use four-space indentation and standard Julia formatting. Keep only the stable
API listed in `docs/agents/spec.md` exported from `src/JevClient.jl`; leave
helpers, parser internals, transport types, and concrete error subtypes
module-qualified or unexported. Use `UpperCamelCase` for public types and
`lower_snake_case` for ordinary functions. Preserve validation, bounded
resource usage, and explicit request/response wire formats when refactoring.
Test-only helpers such as `MockTransport`, `TransportResponse`, and internal
error types must remain unexported; tests should access them as
`JevClient.MockTransport` or `JevClient.LocalValidationError`.

## Testing Guidelines

Add behavior-focused `@testset` blocks to `test/runtests.jl`. Cover successful
serialization and parsing as well as malformed input, lifecycle failures,
credential handling, retries, and mock transport behavior. Do not put API keys
or live response bodies in tests or logs.

## Commit & Pull Request Guidelines

Use a short, imperative commit subject, for example `Validate response payloads`.
Pull requests should explain the behavior change, identify specification updates,
and report `Pkg.test()` and any JuliaCheck results. Include live API test details
only in redacted form.

## Security & Configuration

Keep `TYPESAFE_API_KEY` in a local `.env` or environment variable; `.env` is
ignored by Git. Load it with DotEnv.jl only for local API checks, never print the
key, and use a pinned model for reproducible production examples.
