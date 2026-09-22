import HTTP

abstract type AbstractTransport end

struct TransportResponse
    status::Int
    headers::Vector{Pair{String,String}}
    body::Vector{UInt8}
end

struct HTTPTransport <: AbstractTransport end

mutable struct MockTransport <: AbstractTransport
    handler::Function
end

struct MockRequest
    method::String
    path::String
    headers::Vector{Pair{String,String}}
    body::Vector{UInt8}
    deadline::Float64
end

function _transport_request(transport::MockTransport, method::String, path::String,
                            headers, body::Vector{UInt8}, deadline::Float64;
                            limits::ResourceLimits=ResourceLimits(), timeout::TimeoutPolicy=TimeoutPolicy())
    result = try
        transport.handler(MockRequest(method, path, copy(headers), copy(body), deadline))
    catch error
        error isa JevError && rethrow()
        throw(ConnectError("mock transport failed"))
    end
    result isa TransportResponse || throw(ConnectError("mock transport returned an invalid response"))
    result
end

function _header_value(headers, name::AbstractString)
    lowercase_name = lowercase(String(name))
    for pair in headers
        lowercase(pair.first) == lowercase_name && return pair.second
    end
    nothing
end

function _read_http_body(stream, max_bytes::Int)
    buffer = IOBuffer()
    total = 0
    while !eof(stream)
        chunk = readavailable(stream)
        if isempty(chunk)
            yield()
            continue
        end
        total += length(chunk)
        total <= max_bytes || throw(ResponseTooLargeError("response exceeds configured byte limit"))
        write(buffer, chunk)
    end
    return Vector{UInt8}(take!(buffer))
end

function _transport_request(::HTTPTransport, method::String, path::String,
                            headers::Vector{Pair{String,String}}, body::Vector{UInt8}, deadline::Float64;
                            limits::ResourceLimits=ResourceLimits(), timeout::TimeoutPolicy=TimeoutPolicy())
    path in ("/v1/systemone", "/v1/models") || throw(EndpointPolicyError("unsupported endpoint"))
    url = "https://api.typesafe.ai" * path
    response_status = Ref{Int}(0)
    response_headers = Ref{Vector{Pair{String,String}}}(Pair{String,String}[])
    response_body = Ref{Vector{UInt8}}(UInt8[])
    stream = nothing
    try
        stream = HTTP.open(method, url, headers;
                           redirect=false,
                           retry=false,
                           proxy=nothing,
                           cookies=false,
                           decompress=false,
                           require_ssl_verification=true,
                           connect_timeout=timeout.connect,
                           request_timeout=min(timeout.attempt, max(0.001, deadline - time())),
                           response_header_timeout=timeout.first_byte,
                           read_idle_timeout=timeout.first_byte,
                           logerrors=false,
                           protocol=:auto)
        write(stream, body)
        HTTP.closewrite(stream)
        metadata = HTTP.startread(stream)
        response_status[] = metadata.status
        response_headers[] = Pair{String,String}[String(pair.first) => String(pair.second)
                                                  for pair in metadata.headers]
        declared = _header_value(response_headers[], "content-length")
        if !isnothing(declared)
            parsed = try
                parse(Int, strip(declared))
            catch
                -1
            end
            parsed < 0 && throw(UnexpectedStatusError("invalid response content length";
                                                       status=metadata.status))
            parsed <= limits.max_response_bytes ||
                throw(ResponseTooLargeError("response exceeds configured byte limit";
                                            status=metadata.status))
        end
        response_body[] = _read_http_body(stream, limits.max_response_bytes)
    finally
        if !isnothing(stream)
            try
                close(stream)
            catch
            end
        end
    end
    TransportResponse(response_status[], response_headers[], response_body[])
end
