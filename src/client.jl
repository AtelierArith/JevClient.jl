mutable struct Client
    model::AbstractModelRef
    credential::AbstractCredentialProvider
    retry::RetryPolicy
    timeout::TimeoutPolicy
    limits::ResourceLimits
    max_inflight::Int
    tokens::Channel{Nothing}
    transport::AbstractTransport
    lock::ReentrantLock
    closed::Bool
    active::Int
    alias_warned::Bool
end

const _RATE_LIMIT_STATUS = 429
const _OVERLOADED_STATUS = 529

"""
    Client(; model, credential=EnvCredential("TYPESAFE_API_KEY"),
             retry=RetryPolicy(), timeout=TimeoutPolicy(), limits=ResourceLimits(),
             max_inflight=8)

Thread-safe client for the TypeSafe System One API. `model` is required and
should normally be a versioned [`PinnedModel`](@ref).

The client owns its credential provider, so `close(client)` closes that provider
too. Call `close(client)` when finished, or use [`with_client`](@ref) to close it
automatically. After `close(client)`, any request throws
`JevClient.ClosedClientError`.
"""
function Client(; model::AbstractModelRef,
                credential::AbstractCredentialProvider=EnvCredential("TYPESAFE_API_KEY"),
                retry::RetryPolicy=RetryPolicy(),
                timeout::TimeoutPolicy=TimeoutPolicy(),
                limits::ResourceLimits=ResourceLimits(),
                max_inflight::Integer=8,
                transport::AbstractTransport=HTTPTransport())
    max_inflight > 0 || throw(LocalValidationError("max_inflight must be positive"))
    tokens = Channel{Nothing}(Int(max_inflight))
    for _ in 1:max_inflight
        put!(tokens, nothing)
    end
    client = Client(model, credential, retry, timeout, limits, Int(max_inflight),
                    tokens, transport, ReentrantLock(), false, 0, false)
    finalizer(client) do current
        try
            close(current)
        catch
        end
    end
    client
end

function _ensure_open(client::Client)
    lock(client.lock)
    try
        client.closed && throw(ClosedClientError("client is closed"))
    finally
        unlock(client.lock)
    end
    nothing
end

function _enter_request(client::Client)
    lock(client.lock)
    try
        client.closed && throw(ClosedClientError("client is closed"))
        client.active += 1
    finally
        unlock(client.lock)
    end
end

function _leave_request(client::Client)
    lock(client.lock)
    try
        client.active -= 1
    finally
        unlock(client.lock)
    end
end

function Base.isopen(client::Client)
    lock(client.lock)
    try
        !client.closed
    finally
        unlock(client.lock)
    end
end

function Base.show(io::IO, client::Client)
    state = isopen(client) ? "open" : "closed"
    print(io, "Client(model=", client.model,
          ", credential=<redacted>, state=", state,
          ", max_inflight=", client.max_inflight, ")")
end

function Base.close(client::Client)
    lock(client.lock)
    try
        client.closed = true
    finally
        unlock(client.lock)
    end
    active = 1
    while active != 0
        lock(client.lock)
        active = try client.active finally unlock(client.lock) end
        if active != 0
            yield()
        end
    end
    close(client.credential)
    nothing
end

"""
    with_client(f::Function; kwargs...)

Build a [`Client`](@ref) from `kwargs`, pass it to `f`, and return `f(client)`.
The client is always closed with `Base.close` in a `finally` block, including
when `f` throws. Keyword arguments are forwarded to the `Client` constructor.

This mirrors Python's `with` statement; `Base.close` is never exported.

```julia
probability = with_client(
    model = PinnedModel("jev-1.13.0"),
    credential = EnvCredential("TYPESAFE_API_KEY"),
) do client
    response = system_one(client; state, questions)
    answer(response, "urgent").noul
end
```
"""
function with_client(f::Function; kwargs...)
    client = Client(; kwargs...)
    try
        return f(client)
    finally
        close(client)
    end
end

function _acquire_token(client::Client, deadline::Float64)
    remaining = deadline - time()
    remaining > 0 || throw(TimeoutError("timeout while waiting for an available request slot"))
    result = Base.timedwait(() -> isready(client.tokens), remaining; pollint=0.01)
    result == :ok || throw(TimeoutError("timeout while waiting for an available request slot"))
    take!(client.tokens)
    true
end

_release_token(client::Client) = put!(client.tokens, nothing)

function _safe_retry_after(headers)
    value = _header_value(headers, "retry-after")
    isnothing(value) && return nothing
    trimmed = strip(value)
    parsed = try
        parse(Float64, trimmed)
    catch
        nothing
    end
    if !isnothing(parsed)
        isfinite(parsed) && parsed >= 0 ||
            throw(ResponseValidationError("invalid Retry-After header"))
        return parsed
    end
    endswith(trimmed, " GMT") || throw(ResponseValidationError("invalid Retry-After header"))
    timestamp = chop(trimmed; tail=4)
    date = try
        DateTime(timestamp, dateformat"e, dd u yyyy HH:MM:SS")
    catch
        throw(ResponseValidationError("invalid Retry-After header"))
    end
    delay = Dates.value(DateTime(now(UTC)) - date) / 1000
    max(delay, 0.0)
end

function _api_error(status::Int, request_id, retry_after, attempt::Int)
    context = (; status=status, request_id=request_id, retry_after=retry_after,
               attempt_count=attempt)
    status == 401 && return AuthenticationError("authentication failed"; context...)
    status == 403 && return PermissionDeniedError("permission denied"; context...)
    status == 404 && return NotFoundError("endpoint was not found"; context...)
    status == 422 && return RemoteValidationError("remote validation failed"; context...)
    status == _RATE_LIMIT_STATUS && return RateLimitError("rate limit exceeded"; context...)
    status == _OVERLOADED_STATUS && return OverloadedError("upstream is overloaded"; context...)
    500 <= status <= 599 && return ServerError("upstream server error"; context...)
    UnexpectedStatusError("unexpected upstream status"; context...)
end

function _content_type(headers)
    value = _header_value(headers, "content-type")
    isnothing(value) && return nothing
    lowercase(strip(first(split(value, ';'))))
end

function _check_json_content_type(headers)
    content_type = _content_type(headers)
    content_type === "application/json" ||
        (!isnothing(content_type) && startswith(content_type, "application/") && endswith(content_type, "+json")) ||
        throw(UnexpectedContentTypeError("upstream response is not JSON"))
end

function _retry_delay(policy::RetryPolicy, attempt::Int, retry_after, deadline::Float64)
    base = min(policy.max_delay, policy.initial_delay * (2.0 ^ max(attempt - 1, 0)))
    server = isnothing(retry_after) ? 0.0 : retry_after
    delay = max(base * rand(), server)
    remaining = deadline - time()
    delay <= remaining || throw(RetryBudgetExceededError("retry budget exceeded";
                                                        attempt_count=attempt))
    delay
end

function _perform_request(client::Client, method::String, path::String,
                          body::Vector{UInt8}, timeout::TimeoutPolicy, retry::RetryPolicy)
    deadline = time() + min(timeout.total, retry.total_budget)
    attempt = 0
    while attempt <= retry.max_retries + 1
        attempt += 1
        remaining = deadline - time()
        remaining > 0 || throw(TimeoutError("request deadline exceeded"; attempt_count=attempt))
        credential_bytes = UInt8[]
        attempt_body = copy(body)
        try
            credential_bytes = _credential(client.credential)
            headers = Pair{String,String}[
                "Authorization" => "Bearer " * String(credential_bytes),
                "Content-Type" => "application/json; charset=utf-8",
                "Accept" => "application/json",
                "Accept-Encoding" => "identity",
                "User-Agent" => "JevClient.jl/0.1.0 Julia/" * string(VERSION),
            ]
            response = _transport_request(client.transport, method, path, headers,
                                          attempt_body, deadline;
                                          limits=client.limits, timeout=timeout)
            id = _header_value(response.headers, "x-request-id")
            retry_after = _safe_retry_after(response.headers)
            if 300 <= response.status <= 399
                throw(RedirectError("upstream returned a redirect"; status=response.status,
                                    request_id=id, attempt_count=attempt))
            elseif response.status == 200
                return response
            elseif response.status in (_RATE_LIMIT_STATUS, _OVERLOADED_STATUS) && attempt <= retry.max_retries
                delay = _retry_delay(retry, attempt, retry_after, deadline)
                sleep(delay)
                continue
            else
                throw(_api_error(response.status, id, retry_after, attempt))
            end
        catch error
            error isa JevError && rethrow()
            throw(ConnectError("request transport failed"; attempt_count=attempt))
        finally
            fill!(credential_bytes, 0x00)
            fill!(attempt_body, 0x00)
        end
    end
    throw(RetryBudgetExceededError("request attempt limit exceeded"; attempt_count=attempt))
end

function _effective_policy(value, default, type)
    isnothing(value) && return default
    value isa type || throw(LocalValidationError("request policy has an invalid type"))
    value
end

"""
    system_one(client::Client; state, questions::QuestionSet,
               timeout=nothing, retry=nothing)::SystemOneResponse

Evaluate `questions` against `state` with the System One API and return a
[`SystemOneResponse`](@ref). `timeout` and `retry` narrow the client-level
policies for this call; they cannot relax the client's resource limits. Passing
a non-`Client` or a closed client throws `JevClient.ClosedClientError`.
"""
function system_one(client::Client; state, questions::QuestionSet,
                    timeout::Union{Nothing,TimeoutPolicy}=nothing,
                    retry::Union{Nothing,RetryPolicy}=nothing)::SystemOneResponse
    _ensure_open(client)
    _enter_request(client)
    token_acquired = false
    try
        effective_timeout = _effective_policy(timeout, client.timeout, TimeoutPolicy)
        effective_retry = _effective_policy(retry, client.retry, RetryPolicy)
        if client.model isa MovingAlias
            lock(client.lock)
            warn_alias = try
                if client.alias_warned
                    false
                else
                    client.alias_warned = true
                    true
                end
            finally
                unlock(client.lock)
            end
            warn_alias && @warn "MovingAlias is not reproducible; use a versioned PinnedModel for production"
        end
        deadline = time() + effective_timeout.total
        _acquire_token(client, deadline)
        token_acquired = true
        body = _serialize_request(state, client.model, questions; limits=client.limits)
        response = _perform_request(client, "POST", "/v1/systemone", body,
                                    effective_timeout, effective_retry)
        _check_json_content_type(response.headers)
        _parse_response(response.body, questions; limits=client.limits,
                        request_id=_header_value(response.headers, "x-request-id"))
    finally
        token_acquired && _release_token(client)
        _leave_request(client)
    end
end

function _parse_model_list(bytes::Vector{UInt8}; limits::ResourceLimits=ResourceLimits())
    object = _parse_json(bytes; limits=limits)
    object isa JSON3.Object || throw(ResponseValidationError("model list must be an object"))
    models_value = _field(object, "models", String[])
    models_value isa JSON3.Array || throw(ResponseValidationError("models must be an array";
                                                                 field_path=["models"]))
    models = Vector{ModelInfo}(undef, length(models_value))
    for (index, model) in enumerate(models_value)
        path = ["models", string(index)]
        model isa JSON3.Object || throw(ResponseValidationError("model entry must be an object";
                                                                field_path=path))
        name = _as_string(_field(model, "name", path), [path; "name"])
        description = _as_string(_field(model, "description", path), [path; "description"]; nonempty=false)
        release = _as_string(_field(model, "release_date", path), [path; "release_date"])
        date = try
            Date(release)
        catch
            throw(ResponseValidationError("release_date is not an ISO date";
                                          field_path=[path; "release_date"]))
        end
        models[index] = ModelInfo(name, description, date)
    end
    ModelList(models)
end

"""
    list_models(client::Client)::ModelList

Return the models available to the client as a [`ModelList`](@ref). A closed
client throws `JevClient.ClosedClientError`.
"""
function list_models(client::Client)
    _ensure_open(client)
    _enter_request(client)
    token_acquired = false
    try
        deadline = time() + client.timeout.total
        _acquire_token(client, deadline)
        response = _perform_request(client, "GET", "/v1/models", UInt8[],
                                    client.timeout, client.retry)
        _check_json_content_type(response.headers)
        _parse_model_list(response.body; limits=client.limits)
    finally
        token_acquired && _release_token(client)
        _leave_request(client)
    end
end
