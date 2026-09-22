struct ResourceLimits
    max_request_bytes::Int
    max_response_bytes::Int
    max_error_body_bytes::Int
    max_json_depth::Int
    max_string_bytes::Int
    max_container_items::Int
    max_questions::Int
    max_question_id_chars::Int
    max_model_id_bytes::Int
end

function ResourceLimits(; max_request_bytes::Integer=1 * 1024 * 1024,
                         max_response_bytes::Integer=8 * 1024 * 1024,
                         max_error_body_bytes::Integer=64 * 1024,
                         max_json_depth::Integer=32,
                         max_string_bytes::Integer=1 * 1024 * 1024,
                         max_container_items::Integer=100_000,
                         max_questions::Integer=1024,
                         max_question_id_chars::Integer=128,
                         max_model_id_bytes::Integer=128)
    values = (max_request_bytes, max_response_bytes, max_error_body_bytes,
              max_json_depth, max_string_bytes, max_container_items,
              max_questions, max_question_id_chars, max_model_id_bytes)
    all(x -> x > 0, values) || throw(LocalValidationError("resource limits must be positive"))
    ResourceLimits(Int.(values)...)
end

struct TimeoutPolicy
    connect::Float64
    first_byte::Float64
    attempt::Float64
    total::Float64
end

function TimeoutPolicy(; connect::Real=5.0,
                       first_byte::Real=15.0,
                       attempt::Real=30.0,
                       total::Real=60.0)
    values = (Float64(connect), Float64(first_byte), Float64(attempt), Float64(total))
    all(isfinite, values) && all(>(0), values) ||
        throw(LocalValidationError("timeout values must be finite and positive"))
    values[1] <= values[3] <= values[4] ||
        throw(LocalValidationError("timeout values must satisfy connect <= attempt <= total"))
    values[2] <= values[3] ||
        throw(LocalValidationError("first_byte must not exceed attempt"))
    TimeoutPolicy(values...)
end

struct RetryPolicy
    max_retries::Int
    initial_delay::Float64
    max_delay::Float64
    total_budget::Float64
end

function RetryPolicy(; max_retries::Integer=2,
                     initial_delay::Real=0.5,
                     max_delay::Real=15.0,
                     total_budget::Real=60.0)
    0 <= max_retries <= 5 || throw(LocalValidationError("max_retries must be between 0 and 5"))
    values = (Float64(initial_delay), Float64(max_delay), Float64(total_budget))
    all(isfinite, values) && all(>=(0), values) ||
        throw(LocalValidationError("retry delays and budget must be finite and non-negative"))
    values[1] <= values[2] <= values[3] <= 300.0 ||
        throw(LocalValidationError("retry delays and budget are outside the allowed range"))
    RetryPolicy(Int(max_retries), values...)
end

