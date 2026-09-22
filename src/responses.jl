abstract type AbstractAnswer end

"""
    NoulAnswer

Answer to a [`Noul`](@ref) question. The field `noul` is the probability in
`[0, 1]` that the criteria hold.
"""
struct NoulAnswer <: AbstractAnswer
    noul::Float64
end

"""
    ChoiceAnswer

Answer to a [`Choice`](@ref) question. `choice` is the selected candidate ID,
`probabilities` maps every candidate ID to its probability, and `confidence`
describes the model's confidence in the selection.
"""
struct ChoiceAnswer <: AbstractAnswer
    choice::String
    probabilities::Vector{Pair{String,Float64}}
    confidence::Float64
end

"""
    ScoreAnswer

Answer to a [`Score`](@ref) question. `score` is the chosen level, `legend`
lists the labels in ascending order, `probabilities` gives the probability of
each level, and `confidence` describes the model's confidence.
"""
struct ScoreAnswer <: AbstractAnswer
    score::Float64
    legend::Vector{String}
    probabilities::Vector{Float64}
    confidence::Float64
end

"""
    Usage

Token accounting for a System One request: `input_tokens` and `output_tokens`.
"""
struct Usage
    input_tokens::Int
    output_tokens::Int
end

"""
    SystemOneResponse

Result of [`system_one`](@ref). Access answers by question ID with
[`answer`](@ref) or `response[id]`. `model` is the resolved model ID, `usage`
holds token counts, and `request_id` is the upstream request ID when present.
"""
struct SystemOneResponse
    model::String
    answers::Vector{Pair{String,AbstractAnswer}}
    usage::Usage
    request_id::Union{Nothing,String}
end

function Base.getindex(response::SystemOneResponse, id::AbstractString)
    for pair in response.answers
        pair.first == id && return pair.second
    end
    throw(LocalValidationError("unknown answer ID"; field_path=[String(id)]))
end

"""
    answer(response::SystemOneResponse, id::AbstractString)::AbstractAnswer

Return the answer for the question `id`. Throws
`JevClient.LocalValidationError` when the ID is unknown. Equivalent to
`response[id]`.
"""
answer(response::SystemOneResponse, id::AbstractString) = response[id]

"""
    request_id(response::SystemOneResponse)::Union{Nothing,String}

Return the upstream request ID carried by `response`, or `nothing` when absent.
"""
request_id(response::SystemOneResponse) = response.request_id

function Base.show(io::IO, response::SystemOneResponse)
    print(io, "SystemOneResponse(model=\"", response.model,
          "\", answers=", length(response.answers),
          ", usage=(input_tokens=", response.usage.input_tokens,
          ", output_tokens=", response.usage.output_tokens,
          "), request_id=", isnothing(response.request_id) ? "none" : "present", ")")
end

mutable struct _JSONScanner
    bytes::Vector{UInt8}
    pos::Int
    limits::ResourceLimits
end

_scan_done(scanner::_JSONScanner) = scanner.pos > length(scanner.bytes)

function _scan_byte(scanner::_JSONScanner)
    return _scan_done(scanner) ? nothing : scanner.bytes[scanner.pos]
end

function _scan_whitespace!(scanner::_JSONScanner)
    while !_scan_done(scanner) && scanner.bytes[scanner.pos] in (0x20, 0x09, 0x0a, 0x0d)
        scanner.pos += 1
    end
end

function _scan_error(message="malformed JSON")
    throw(MalformedJSONError(message))
end

function _scan_string!(scanner::_JSONScanner)
    scanner.bytes[scanner.pos] == UInt8('"') || _scan_error()
    start = scanner.pos
    scanner.pos += 1
    while !_scan_done(scanner)
        byte = scanner.bytes[scanner.pos]
        if byte == UInt8('"')
            scanner.pos += 1
            raw = String(scanner.bytes[start:scanner.pos - 1])
            decoded = try
                JSON3.read(raw)
            catch
                _scan_error()
            end
            decoded isa String || _scan_error()
            return decoded
        elseif byte < 0x20
            _scan_error()
        elseif byte == UInt8('\\')
            scanner.pos += 1
            _scan_done(scanner) && _scan_error()
            escaped = scanner.bytes[scanner.pos]
            if escaped == UInt8('u')
                scanner.pos += 1
                scanner.pos + 3 <= length(scanner.bytes) || _scan_error()
                for _ in 1:4
                    c = scanner.bytes[scanner.pos]
                    (c in UInt8('0'):UInt8('9') || c in UInt8('a'):UInt8('f') ||
                     c in UInt8('A'):UInt8('F')) || _scan_error()
                    scanner.pos += 1
                end
            elseif escaped in (UInt8('"'), UInt8('\\'), UInt8('/'), UInt8('b'),
                               UInt8('f'), UInt8('n'), UInt8('r'), UInt8('t'))
                scanner.pos += 1
            else
                _scan_error()
            end
        else
            scanner.pos += 1
        end
    end
    _scan_error()
end

function _scan_number!(scanner::_JSONScanner)
    start = scanner.pos
    if _scan_byte(scanner) == UInt8('-')
        scanner.pos += 1
        _scan_done(scanner) && _scan_error()
    end
    if _scan_byte(scanner) == UInt8('0')
        scanner.pos += 1
        !_scan_done(scanner) && scanner.bytes[scanner.pos] in UInt8('0'):UInt8('9') && _scan_error()
    elseif !_scan_done(scanner) && scanner.bytes[scanner.pos] in UInt8('1'):UInt8('9')
        scanner.pos += 1
        while !_scan_done(scanner) && scanner.bytes[scanner.pos] in UInt8('0'):UInt8('9')
            scanner.pos += 1
        end
    else
        _scan_error()
    end
    if !_scan_done(scanner) && scanner.bytes[scanner.pos] == UInt8('.')
        scanner.pos += 1
        (_scan_done(scanner) || !(scanner.bytes[scanner.pos] in UInt8('0'):UInt8('9'))) && _scan_error()
        while !_scan_done(scanner) && scanner.bytes[scanner.pos] in UInt8('0'):UInt8('9')
            scanner.pos += 1
        end
    end
    if !_scan_done(scanner) && scanner.bytes[scanner.pos] in (UInt8('e'), UInt8('E'))
        scanner.pos += 1
        !_scan_done(scanner) && scanner.bytes[scanner.pos] in (UInt8('+'), UInt8('-')) && (scanner.pos += 1)
        (_scan_done(scanner) || !(scanner.bytes[scanner.pos] in UInt8('0'):UInt8('9'))) && _scan_error()
        while !_scan_done(scanner) && scanner.bytes[scanner.pos] in UInt8('0'):UInt8('9')
            scanner.pos += 1
        end
    end
    if !_scan_done(scanner)
        scanner.bytes[scanner.pos] in (0x20, 0x09, 0x0a, 0x0d, UInt8(','), UInt8(']'), UInt8('}')) ||
            _scan_error()
    end
    scanner.pos > start || _scan_error()
    nothing
end

function _scan_value!(scanner::_JSONScanner, depth::Int)
    depth <= scanner.limits.max_json_depth || _scan_error("JSON value exceeds maximum depth")
    _scan_whitespace!(scanner)
    _scan_done(scanner) && _scan_error()
    byte = scanner.bytes[scanner.pos]
    if byte == UInt8('{')
        scanner.pos += 1
        _scan_whitespace!(scanner)
        keys_seen = Dict{String,Nothing}()
        count = 0
        if !_scan_done(scanner) && scanner.bytes[scanner.pos] != UInt8('}')
            while !_scan_done(scanner)
                count += 1
                count <= scanner.limits.max_container_items || _scan_error("JSON object is too large")
                _scan_whitespace!(scanner)
                key = _scan_string!(scanner)
                haskey(keys_seen, key) && _scan_error("duplicate JSON object key")
                keys_seen[key] = nothing
                _scan_whitespace!(scanner)
                (!_scan_done(scanner) && scanner.bytes[scanner.pos] == UInt8(':')) || _scan_error()
                scanner.pos += 1
                _scan_value!(scanner, depth + 1)
                _scan_whitespace!(scanner)
                _scan_done(scanner) && _scan_error()
                separator = scanner.bytes[scanner.pos]
                separator == UInt8('}') && break
                separator == UInt8(',') || _scan_error()
                scanner.pos += 1
            end
        end
        _scan_done(scanner) && _scan_error()
        scanner.bytes[scanner.pos] == UInt8('}') || _scan_error()
        scanner.pos += 1
    elseif byte == UInt8('[')
        scanner.pos += 1
        _scan_whitespace!(scanner)
        count = 0
        if !_scan_done(scanner) && scanner.bytes[scanner.pos] != UInt8(']')
            while !_scan_done(scanner)
                count += 1
                count <= scanner.limits.max_container_items || _scan_error("JSON array is too large")
                _scan_value!(scanner, depth + 1)
                _scan_whitespace!(scanner)
                _scan_done(scanner) && _scan_error()
                separator = scanner.bytes[scanner.pos]
                separator == UInt8(']') && break
                separator == UInt8(',') || _scan_error()
                scanner.pos += 1
                _scan_whitespace!(scanner)
            end
        end
        _scan_done(scanner) && _scan_error()
        scanner.bytes[scanner.pos] == UInt8(']') || _scan_error()
        scanner.pos += 1
    elseif byte == UInt8('"')
        _scan_string!(scanner)
    elseif byte == UInt8('t') && scanner.pos + 3 <= length(scanner.bytes) &&
           String(scanner.bytes[scanner.pos:scanner.pos + 3]) == "true"
        scanner.pos += 4
    elseif byte == UInt8('f') && scanner.pos + 4 <= length(scanner.bytes) &&
           String(scanner.bytes[scanner.pos:scanner.pos + 4]) == "false"
        scanner.pos += 5
    elseif byte == UInt8('n') && scanner.pos + 3 <= length(scanner.bytes) &&
           String(scanner.bytes[scanner.pos:scanner.pos + 3]) == "null"
        scanner.pos += 4
    elseif byte == UInt8('-') || byte in UInt8('0'):UInt8('9')
        _scan_number!(scanner)
    else
        _scan_error()
    end
end

function _parse_json(bytes::Vector{UInt8}; limits::ResourceLimits=ResourceLimits())
    length(bytes) <= limits.max_response_bytes || throw(ResponseTooLargeError("response exceeds configured byte limit"))
    text = try
        # String(::Vector{UInt8}) takes ownership of the vector in Julia and
        # empties it. Keep the bounded response bytes available to the scanner.
        String(copy(bytes))
    catch
        throw(MalformedJSONError("response is not valid UTF-8"))
    end
    isvalid(text) || throw(MalformedJSONError("response is not valid UTF-8"))
    scanner = _JSONScanner(bytes, 1, limits)
    _scan_value!(scanner, 0)
    _scan_whitespace!(scanner)
    scanner.pos == length(bytes) + 1 || throw(MalformedJSONError("trailing JSON data"))
    try
        JSON3.read(text)
    catch
        throw(MalformedJSONError("response contains malformed JSON"))
    end
end

function _has_field(object, key::String)
    haskey(object, key)
end

function _field(object, key::String, path::Vector{String})
    object isa JSON3.Object || throw(ResponseValidationError("response field must be an object";
                                                            field_path=path))
    _has_field(object, key) || throw(ResponseValidationError("response field is missing"; field_path=[path; key]))
    object[key]
end

function _as_string(value, path::Vector{String}; nonempty::Bool=true)
    value isa AbstractString || throw(ResponseValidationError("response field must be a string"; field_path=path))
    text = String(value)
    nonempty && isempty(text) && throw(ResponseValidationError("response string must not be empty"; field_path=path))
    isvalid(text) || throw(ResponseValidationError("response string is not valid UTF-8"; field_path=path))
    text
end

function _as_number(value, path::Vector{String})
    value isa Bool && throw(ResponseValidationError("response field must be numeric"; field_path=path))
    number = try
        Float64(value)
    catch
        throw(ResponseValidationError("response field must be numeric"; field_path=path))
    end
    isfinite(number) || throw(ResponseValidationError("response number is not finite"; field_path=path))
    number
end

function _as_nonnegative_int(value, path::Vector{String})
    value isa Bool && throw(ResponseValidationError("usage value must be an integer"; field_path=path))
    number = try
        Int(value)
    catch
        throw(ResponseValidationError("usage value must be an integer"; field_path=path))
    end
    Float64(value) == number && number >= 0 ||
        throw(ResponseValidationError("usage value must be a non-negative integer"; field_path=path))
    number
end

function _object_pairs(object, path::Vector{String})
    object isa JSON3.Object || throw(ResponseValidationError("response field must be an object"; field_path=path))
    Pair{String,Any}[Pair{String,Any}(String(key), value) for (key, value) in object]
end

function _validate_noul(value, path)
    probability = _as_number(_field(value, "noul", path), [path; "noul"])
    0.0 <= probability <= 1.0 ||
        throw(ResponseValidationError("noul probability is outside [0, 1]"; field_path=[path; "noul"]))
    NoulAnswer(probability)
end

function _validate_choice(value, question::Choice, path)
    choice = _as_string(_field(value, "choice", path), [path; "choice"])
    candidate_ids = Set(first.(question.criteria))
    choice in candidate_ids || throw(ResponseValidationError("choice is not a known candidate";
                                                            field_path=[path; "choice"]))
    probabilities_value = _field(value, "probabilities", path)
    pairs = _object_pairs(probabilities_value, [path; "probabilities"])
    keys_seen = Dict{String,Nothing}()
    probabilities = Vector{Pair{String,Float64}}(undef, length(pairs))
    total = 0.0
    max_probability = 0.0
    for (index, pair) in enumerate(pairs)
        haskey(keys_seen, pair.first) &&
            throw(ResponseValidationError("duplicate probability key";
                                          field_path=[path; "probabilities"]))
        keys_seen[pair.first] = nothing
        pair.first in candidate_ids || throw(ResponseValidationError("unknown probability key";
                                                                     field_path=[path; "probabilities"; pair.first]))
        probability = _as_number(pair.second, [path; "probabilities"; pair.first])
        0.0 <= probability <= 1.0 || throw(ResponseValidationError("probability is outside [0, 1]";
                                                                    field_path=[path; "probabilities"; pair.first]))
        total += probability
        max_probability = max(max_probability, probability)
        probabilities[index] = Pair{String,Float64}(pair.first, probability)
    end
    Set(keys(keys_seen)) == candidate_ids || throw(ResponseValidationError("probability keys do not match candidates";
                                                                field_path=[path; "probabilities"]))
    abs(total - 1.0) <= 1e-4 || throw(ResponseValidationError("probabilities do not sum to one";
                                                              field_path=[path; "probabilities"]))
    chosen_probability = only(pair.second for pair in probabilities if pair.first == choice)
    abs(chosen_probability - max_probability) <= 1e-6 ||
        throw(ResponseValidationError("choice is not a maximum probability candidate";
                                      field_path=[path; "choice"]))
    confidence = _as_number(_field(value, "confidence", path), [path; "confidence"])
    0.0 <= confidence <= 1.0 || throw(ResponseValidationError("confidence is outside [0, 1]";
                                                              field_path=[path; "confidence"]))
    ChoiceAnswer(choice, probabilities, confidence)
end

function _validate_score(value, question::Score, path)
    score = _as_number(_field(value, "score", path), [path; "score"])
    legend_value = _field(value, "legend", path)
    legend_value isa JSON3.Array || throw(ResponseValidationError("legend must be an array";
                                                                  field_path=[path; "legend"]))
    legend = [_as_string(label, [path; "legend"; string(index)])
              for (index, label) in enumerate(legend_value)]
    probabilities_value = _field(value, "probabilities", path)
    probabilities_value isa JSON3.Array || throw(ResponseValidationError("probabilities must be an array";
                                                                         field_path=[path; "probabilities"]))
    probabilities = Float64[_as_number(item, [path; "probabilities"; string(index)])
                           for (index, item) in enumerate(probabilities_value)]
    length(legend) == length(question.criteria) == length(probabilities) ||
        throw(ResponseValidationError("score legend/probabilities length is invalid"; field_path=path))
    legend == question.criteria || throw(ResponseValidationError("score legend does not match criteria";
                                                                 field_path=[path; "legend"]))
    all(p -> 0.0 <= p <= 1.0, probabilities) ||
        throw(ResponseValidationError("score probability is outside [0, 1]"; field_path=[path; "probabilities"]))
    abs(sum(probabilities) - 1.0) <= 1e-4 ||
        throw(ResponseValidationError("score probabilities do not sum to one"; field_path=[path; "probabilities"]))
    0.0 <= score <= length(probabilities) - 1 ||
        throw(ResponseValidationError("score is outside the level range"; field_path=[path; "score"]))
    expected = sum(index * probabilities[index + 1] for index in 0:length(probabilities)-1)
    abs(score - expected) <= 1e-4 || throw(ResponseValidationError("score is inconsistent with probabilities";
                                                                   field_path=[path; "score"]))
    confidence = _as_number(_field(value, "confidence", path), [path; "confidence"])
    0.0 <= confidence <= 1.0 || throw(ResponseValidationError("confidence is outside [0, 1]";
                                                              field_path=[path; "confidence"]))
    ScoreAnswer(score, legend, probabilities, confidence)
end

function _parse_response(bytes::Vector{UInt8}, questions::QuestionSet;
                         limits::ResourceLimits=ResourceLimits(),
                         request_id::Union{Nothing,AbstractString}=nothing)
    object = _parse_json(bytes; limits=limits)
    object isa JSON3.Object || throw(ResponseValidationError("response top-level must be an object"))
    model = _as_string(_field(object, "model", String[]), ["model"])
    usage_value = _field(object, "usage", String[])
    usage_value isa JSON3.Object || throw(ResponseValidationError("usage must be an object"; field_path=["usage"]))
    usage = Usage(_as_nonnegative_int(_field(usage_value, "input_tokens", ["usage"]),
                                      ["usage", "input_tokens"]),
                  _as_nonnegative_int(_field(usage_value, "output_tokens", ["usage"]),
                                      ["usage", "output_tokens"]))
    answers_value = _field(object, "answers", String[])
    answers_value isa JSON3.Object || throw(ResponseValidationError("answers must be an object";
                                                                   field_path=["answers"]))
    answer_pairs = _object_pairs(answers_value, ["answers"])
    expected_ids = Set(first.(questions.questions))
    actual_ids = Set(first.(answer_pairs))
    actual_ids == expected_ids || throw(ResponseValidationError("answer IDs do not match questions";
                                                               field_path=["answers"]))
    answers = Vector{Pair{String,AbstractAnswer}}(undef, length(answer_pairs))
    for (index, pair) in enumerate(answer_pairs)
        question = questions[pair.first]
        value = pair.second
        answer_type = _as_string(_field(value, "type", ["answers"; pair.first]),
                                 ["answers"; pair.first; "type"])
        result = if question isa Noul
            answer_type == "noul" || throw(ResponseValidationError("answer type does not match question";
                                                                    field_path=["answers"; pair.first; "type"]))
            _validate_noul(value, ["answers"; pair.first])
        elseif question isa Choice
            answer_type == "choice" || throw(ResponseValidationError("answer type does not match question";
                                                                      field_path=["answers"; pair.first; "type"]))
            _validate_choice(value, question, ["answers"; pair.first])
        elseif question isa Score
            answer_type == "score" || throw(ResponseValidationError("answer type does not match question";
                                                                     field_path=["answers"; pair.first; "type"]))
            _validate_score(value, question, ["answers"; pair.first])
        else
            throw(ResponseValidationError("unknown question type"; field_path=["answers"; pair.first]))
        end
        answers[index] = Pair{String,AbstractAnswer}(pair.first, result)
    end
    SystemOneResponse(model, answers, usage,
                      isnothing(request_id) ? nothing : String(request_id))
end
