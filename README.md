# JevClient

[![Build Status](https://github.com/terasakisatoshi/JevClient.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/terasakisatoshi/JevClient.jl/actions/workflows/CI.yml?query=branch%3Amain)

Unofficial Julia client for TypeSafe AI.

The client uses a versioned model by default in production examples and validates
questions, request content, credentials, and model responses locally. Request
and response bodies, API keys, and question contents are not written to logs.

```julia
using JevClient

client = Client(
    model = PinnedModel("jev-1.13.0"),
    credential = EnvCredential("TYPESAFE_API_KEY"),
)

questions = QuestionSet(
    "urgent" => Noul(
        "Does this ticket request immediate action?";
        criteria = NoulCriteria(
            yes = "It asks for immediate action",
            no = "It does not ask for immediate action",
        ),
    ),
)

try
    response = system_one(client; state = "Please resolve this today.", questions = questions)
    probability = answer(response, "urgent").noul
finally
    close(client)
end
```

Jev results are untrusted data. Map Choice values through an application-owned
allowlist before taking an action, and do not use model output as shell, SQL,
file paths, URLs, code, authorization decisions, or high-impact decisions.

The regular API must not be assumed to provide zero data retention. Review
TypeSafe's current privacy policy, DPA, and data residency terms before sending
sensitive data. Minimize or pseudonymize state before transmission.

This package retries only HTTP 429 and 529 responses. Redirects, implicit proxy
environment variables, arbitrary base URLs, and raw HTTP response escape hatches
are intentionally not part of the stable 0.1 API.
