# JevClient.jl

Unofficial Julia client for the [TypeSafe AI](https://typesafe.ai) System One
API. JevClient validates questions, request content, credentials, and model
responses locally. Request and response bodies, API keys, and question contents
are not written to logs.

## Installation

The package is not registered. Add it from its repository:

```julia
using Pkg
Pkg.add(url = "https://github.com/AtelierArith/JevClient.jl")
```

## Quick start

Set the API key in the environment and build a scoped client with
[`with_client`](@ref). The client is closed automatically when the block exits,
matching Python's `with` statement.

```julia
using JevClient

questions = QuestionSet(
    "urgent" => Noul(
        "Does this ticket request immediate action?";
        criteria = NoulCriteria(
            yes = "It asks for immediate action",
            no = "It does not ask for immediate action",
        ),
    ),
)

probability = with_client(
    model = PinnedModel("jev-1.13.0"),
    credential = EnvCredential("TYPESAFE_API_KEY"),
) do client
    response = system_one(client; state = "Please resolve this today.", questions = questions)
    answer(response, "urgent").noul
end
```

If you need explicit ownership, construct a [`Client`](@ref) and call
`close(client)` yourself.

```julia
client = Client(
    model = PinnedModel("jev-1.13.0"),
    credential = EnvCredential("TYPESAFE_API_KEY"),
)
try
    response = system_one(client; state = "Please resolve this today.", questions = questions)
    probability = answer(response, "urgent").noul
finally
    close(client)
end
```

## Question types

| Type | Answer | Use for |
| --- | --- | --- |
| [`Noul`](@ref) | [`NoulAnswer`](@ref) | yes/no probabilities |
| [`Choice`](@ref) | [`ChoiceAnswer`](@ref) | picking one of 2–255 candidates |
| [`Score`](@ref) | [`ScoreAnswer`](@ref) | ordered scores across 2–10 levels |

## Safety

Jev results are untrusted data. Map [`Choice`](@ref) values through an
application-owned allowlist before taking an action, and do not use model output
as shell, SQL, file paths, URLs, code, authorization decisions, or high-impact
decisions. See the [Security](@ref) page for details.
