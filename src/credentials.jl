abstract type AbstractCredentialProvider end

_ascii_whitespace(byte::UInt8) = byte in (0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x20)

function _credential_bytes(value)
    value isa AbstractString || throw(CredentialError("credential callback must return a string"))
    text = String(value)
    raw = Vector{UInt8}(codeunits(text))
    firstindex(raw) <= lastindex(raw) || throw(CredentialError("API key is missing or empty"))
    left = firstindex(raw)
    right = lastindex(raw)
    while left <= right && _ascii_whitespace(raw[left])
        left += 1
    end
    while right >= left && _ascii_whitespace(raw[right])
        right -= 1
    end
    left <= right || throw(CredentialError("API key is missing or empty"))
    trimmed = raw[left:right]
    length(trimmed) <= 4096 || throw(CredentialError("API key is invalid"))
    any(byte -> byte >= 0x80 || byte < 0x20 || byte == 0x7f || _ascii_whitespace(byte), trimmed) &&
        throw(CredentialError("API key is invalid"))
    copy(trimmed)
end

mutable struct EnvCredential <: AbstractCredentialProvider
    name::String
    closed::Bool
end

function EnvCredential(name::AbstractString)
    value = String(name)
    isempty(value) && throw(CredentialError("environment variable name is invalid"))
    isascii(value) && !_invalid_text(value) ||
        throw(CredentialError("environment variable name is invalid"))
    EnvCredential(value, false)
end

mutable struct StaticCredential <: AbstractCredentialProvider
    bytes::Vector{UInt8}
    closed::Bool
end

function StaticCredential(secret::AbstractString)
    StaticCredential(_credential_bytes(secret), false)
end

mutable struct CredentialCallback{F} <: AbstractCredentialProvider
    callback::F
    closed::Bool
end

CredentialCallback(callback) = CredentialCallback{typeof(callback)}(callback, false)

function _credential(provider::EnvCredential)
    provider.closed && throw(CredentialError("credential provider is closed"))
    value = get(ENV, provider.name, nothing)
    isnothing(value) && throw(CredentialError("API key is missing or empty"))
    _credential_bytes(value)
end

function _credential(provider::StaticCredential)
    provider.closed && throw(CredentialError("credential provider is closed"))
    isempty(provider.bytes) && throw(CredentialError("credential provider is closed"))
    copy(provider.bytes)
end

function _credential(provider::CredentialCallback)
    provider.closed && throw(CredentialError("credential provider is closed"))
    value = try
        provider.callback()
    catch
        throw(CredentialError("credential callback failed"))
    end
    _credential_bytes(value)
end

function Base.close(provider::EnvCredential)
    provider.closed = true
    nothing
end

function Base.close(provider::StaticCredential)
    fill!(provider.bytes, 0x00)
    empty!(provider.bytes)
    provider.closed = true
    nothing
end

function Base.close(provider::CredentialCallback)
    provider.closed = true
    nothing
end

Base.isopen(provider::EnvCredential) = !provider.closed
Base.isopen(provider::StaticCredential) = !provider.closed
Base.isopen(provider::CredentialCallback) = !provider.closed

function Base.show(io::IO, ::AbstractCredentialProvider)
    print(io, "<redacted>")
end
