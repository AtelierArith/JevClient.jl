# API Reference

## Client

```@docs
Client
with_client
system_one
list_models
```

## Credentials

```@docs
EnvCredential
StaticCredential
CredentialCallback
```

## Models

```@docs
PinnedModel
MovingAlias
ModelInfo
ModelList
```

## Questions

```@docs
QuestionSet
Noul
NoulCriteria
Choice
Score
Box
```

## Images (experimental)

```@docs
Image
```

## Responses

```@docs
SystemOneResponse
NoulAnswer
ChoiceAnswer
ScoreAnswer
BoxAnswer
Usage
answer
request_id
```

## Policies and limits

```@docs
RetryPolicy
TimeoutPolicy
ResourceLimits
```

## Errors

```@docs
JevError
```

Concrete error types include `JevClient.LocalValidationError`,
`JevClient.CredentialError`, `JevClient.ClosedClientError`,
`JevClient.TimeoutError`, and the API error types. Catch [`JevError`](@ref) to
handle failures without depending on the specific subtype.
