# JevClient

[![Build Status](https://github.com/AtelierArith/JevClient.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/AtelierArith/JevClient.jl/actions/workflows/CI.yml?query=branch%3Amain)
[![Docs](https://img.shields.io/badge/docs-stable-blue.svg)](https://AtelierArith.github.io/JevClient.jl/)

Unofficial Julia client for TypeSafe AI.

The client uses a versioned model by default in production examples and validates
questions, request content, credentials, and model responses locally. Request
and response bodies, API keys, and question contents are not written to logs.

```julia
using JevClient

questions = QuestionSet(
    "julia_related" => Noul(
        "Is this question about Julia?";
        criteria = NoulCriteria(
            yes = "It concerns the Julia programming language",
            no = "It does not concern the Julia programming language",
        ),
    ),
    "category" => Choice(
        "Which category does this Julia question belong to?";
        criteria = [
            "language"    => "Syntax, semantics, types, standard library",
            "packages"    => "Package management, registries, versions",
            "performance" => "Benchmarks, allocations, profiling",
        ],
    ),
    "difficulty" => Score(
        "How difficult is this Julia question?";
        criteria = ["Beginner", "Intermediate", "Advanced"],
    ),
)

result = with_client(
    model = PinnedModel("jev-1.13.0"),
    credential = EnvCredential("TYPESAFE_API_KEY"),
) do client
    state = "How do I make a Julia function type-stable when benchmarking allocations with @allocated?"
    response = system_one(client; state = state, questions = questions)

    julia_related = answer(response, "julia_related")::NoulAnswer
    category = answer(response, "category")::ChoiceAnswer
    difficulty = answer(response, "difficulty")::ScoreAnswer

    (
        julia_related = julia_related.noul,
        category = category.choice,
        category_probabilities = category.probabilities,
        category_confidence = category.confidence,
        difficulty = difficulty.score,
        difficulty_probabilities = difficulty.probabilities,
        difficulty_confidence = difficulty.confidence,
    )
end
```

`with_client` builds a `Client`, passes it to the block, and closes it in a
`finally` block whether the block succeeds or throws, mirroring Python's
`with` statement. If you need explicit ownership, build a `Client` and call
`close(client)` yourself.

Jev results are untrusted data. Map Choice values through an application-owned
allowlist before taking an action, and do not use model output as shell, SQL,
file paths, URLs, code, authorization decisions, or high-impact decisions.

The regular API must not be assumed to provide zero data retention. Review
TypeSafe's current privacy policy, DPA, and data residency terms before sending
sensitive data. Minimize or pseudonymize state before transmission.

This package retries only HTTP 429 and 529 responses. Redirects, implicit proxy
environment variables, arbitrary base URLs, and raw HTTP response escape hatches
are intentionally not part of the stable 0.1 API.
