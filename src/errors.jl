"""
    JevError

Abstract supertype of every error thrown by JevClient. Catch `JevError` to
handle client failures without exposing request bodies or credentials. Concrete
subtypes include `JevClient.LocalValidationError`, `JevClient.CredentialError`,
`JevClient.ClosedClientError`, `JevClient.TimeoutError`, and the API error types.
"""
abstract type JevError <: Exception end

struct ErrorContext
    message::String
    status::Union{Nothing,Int}
    request_id::Union{Nothing,String}
    retry_after::Union{Nothing,Float64}
    field_path::Union{Nothing,Vector{String}}
    attempt_count::Int
end

function ErrorContext(message::AbstractString;
                      status::Union{Nothing,Integer}=nothing,
                      request_id::Union{Nothing,AbstractString}=nothing,
                      retry_after::Union{Nothing,Real}=nothing,
                      field_path::Union{Nothing,AbstractVector{<:AbstractString}}=nothing,
                      attempt_count::Integer=0)
    attempt_count < 0 && throw(ArgumentError("attempt_count must be non-negative"))
    retry = isnothing(retry_after) ? nothing : Float64(retry_after)
    ErrorContext(String(message), isnothing(status) ? nothing : Int(status),
                 isnothing(request_id) ? nothing : String(request_id), retry,
                 isnothing(field_path) ? nothing : String.(field_path), Int(attempt_count))
end

function _error_context(message::AbstractString; kwargs...)
    ErrorContext(message; kwargs...)
end

macro _define_error(name, parent)
    quote
        struct $(esc(name)) <: $(esc(parent))
            context::ErrorContext
        end
        $(esc(name))(message::AbstractString; kwargs...) =
            $(esc(name))(_error_context(message; kwargs...))
    end
end

abstract type ConfigurationError <: JevError end
abstract type TransportError <: JevError end
abstract type ProtocolError <: JevError end
abstract type APIError <: JevError end

@_define_error CredentialError ConfigurationError
@_define_error EndpointPolicyError ConfigurationError
@_define_error LocalValidationError ConfigurationError
@_define_error ClosedClientError ConfigurationError

@_define_error ConnectError TransportError
@_define_error TimeoutError TransportError
@_define_error TLSVerificationError TransportError
@_define_error RedirectError TransportError
@_define_error ResponseTooLargeError TransportError

@_define_error UnexpectedContentTypeError ProtocolError
@_define_error MalformedJSONError ProtocolError
@_define_error ResponseValidationError ProtocolError

@_define_error AuthenticationError APIError
@_define_error PermissionDeniedError APIError
@_define_error NotFoundError APIError
@_define_error RemoteValidationError APIError
@_define_error RateLimitError APIError
@_define_error OverloadedError APIError
@_define_error ServerError APIError
@_define_error UnexpectedStatusError APIError

@_define_error RetryBudgetExceededError JevError
@_define_error ConcurrencyLimitError JevError

function Base.showerror(io::IO, error::JevError)
    context = error.context
    print(io, context.message)
    !isnothing(context.status) && print(io, " (status=", context.status, ")")
    !isnothing(context.request_id) && print(io, " (request_id=", context.request_id, ")")
    !isnothing(context.retry_after) && print(io, " (retry_after=", context.retry_after, ")")
    !isnothing(context.field_path) && print(io, " (field=", join(context.field_path, "."), ")")
    context.attempt_count > 0 && print(io, " (attempt=", context.attempt_count, ")")
end
