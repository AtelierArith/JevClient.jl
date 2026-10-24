function _question_wire(question::Noul)
    pairs = Pair{String,Any}[
        Pair{String,Any}("type", "noul"),
        Pair{String,Any}("instructions", question.instructions),
    ]
    if !isnothing(question.criteria)
        criteria_pairs = [pair for pair in (
            Pair{String,Any}("true", question.criteria.yes),
            Pair{String,Any}("false", question.criteria.no),
        ) if !isnothing(pair.second)]
        return OrderedObject([pairs...,
                              Pair{String,Any}("criteria", OrderedObject(criteria_pairs))])
    end
    return OrderedObject(pairs)
end

function _question_wire(question::Choice)
    criteria = OrderedObject([Pair{String,Any}(id, description)
                              for (id, description) in question.criteria])
    OrderedObject(Pair{String,Any}[
        Pair{String,Any}("type", "choice"),
        Pair{String,Any}("instructions", question.instructions),
        Pair{String,Any}("criteria", criteria),
    ])
end

function _question_wire(question::Score)
    OrderedObject(Pair{String,Any}[
        Pair{String,Any}("type", "score"),
        Pair{String,Any}("instructions", question.instructions),
        Pair{String,Any}("criteria", Any[question.criteria...]),
    ])
end

function _question_wire(question::Box)
    OrderedObject(Pair{String,Any}[
        Pair{String,Any}("type", "box"),
        Pair{String,Any}("instructions", question.instructions),
    ])
end

function _question_wire(question::AbstractQuestion)
    throw(LocalValidationError("unsupported question type"))
end

function _request_value(state, model::AbstractModelRef, questions::QuestionSet;
                        limits::ResourceLimits=ResourceLimits())
    state_value = _normalize_json(state; limits=limits, path=["state"])
    (state_value isa String || state_value isa OrderedObject || state_value isa Vector{Any}) ||
        throw(LocalValidationError("state must be a string, object, or array";
                                   field_path=["state"]))

    model_value = model_id(model)
    isascii(model_value) || throw(LocalValidationError("model ID must be ASCII";
                                                       field_path=["model"]))
    ncodeunits(model_value) <= limits.max_model_id_bytes ||
        throw(LocalValidationError("model ID is too long"; field_path=["model"]))
    _invalid_text(model_value) &&
        throw(LocalValidationError("model ID contains a control character"; field_path=["model"]))
    any(isspace, model_value) &&
        throw(LocalValidationError("model ID must not contain whitespace"; field_path=["model"]))
    length(questions) <= limits.max_questions ||
        throw(LocalValidationError("QuestionSet exceeds configured limit"; field_path=["questions"]))

    question_pairs = Vector{Pair{String,Any}}(undef, length(questions.questions))
    for (index, pair) in enumerate(questions.questions)
        id = pair.first
        ncodeunits(id) <= limits.max_string_bytes ||
            throw(LocalValidationError("question ID is too long"; field_path=["questions", id]))
        length(id) <= limits.max_question_id_chars ||
            throw(LocalValidationError("question ID is too long"; field_path=["questions", id]))
        question = pair.second
        wire = _question_wire(question)
        _validate_normalized(wire; limits=limits, path=["questions", id])
        question_pairs[index] = Pair{String,Any}(id, wire)
    end
    OrderedObject(Pair{String,Any}[
        Pair{String,Any}("state", state_value),
        Pair{String,Any}("model", model_value),
        Pair{String,Any}("questions", OrderedObject(question_pairs)),
    ])
end

struct _EncodedRequest
    body::Vector{UInt8}
    content_type::String
    multimodal::Bool
end

struct _ImageRegistry
    images::Vector{Image}
    references::Vector{String}
    uses::Vector{Int}
    index::IdDict{Vector{UInt8},Int}
end

_ImageRegistry() = _ImageRegistry(Image[], String[], Int[], IdDict{Vector{UInt8},Int}())

_random_token() = bytes2hex(rand(Random.RandomDevice(), UInt8, 16))

function _collect_strings!(strings::Vector{String}, value)
    if value isa String
        push!(strings, value)
    elseif value isa Vector{Any}
        foreach(child -> _collect_strings!(strings, child), value)
    elseif value isa OrderedObject
        foreach(pair -> _collect_strings!(strings, pair.second), value.pairs)
    end
    strings
end

# References are substituted upstream inside any string, so a reference must not
# occur in caller-supplied text.
function _image_reference(strings::Vector{String})
    for _ in 1:8
        reference = "jevclient-image-" * _random_token()
        any(text -> occursin(reference, text), strings) || return reference
    end
    throw(LocalValidationError("could not allocate an unused image reference"))
end

function _substitute_images(value, registry::_ImageRegistry, strings::Vector{String})
    if value isa Image
        index = get(registry.index, value.bytes, 0)
        if index == 0
            push!(registry.images, value)
            push!(registry.references, _image_reference(strings))
            push!(registry.uses, 0)
            index = length(registry.images)
            registry.index[value.bytes] = index
        end
        registry.uses[index] += 1
        return registry.references[index]
    elseif value isa Vector{Any}
        return Any[_substitute_images(child, registry, strings) for child in value]
    elseif value isa OrderedObject
        return OrderedObject(Pair{String,Any}[
            Pair{String,Any}(pair.first, _substitute_images(pair.second, registry, strings))
            for pair in value.pairs])
    end
    value
end

_image_part_name(index::Int) = "image-" * string(index)

function _assets_value(registry::_ImageRegistry)
    OrderedObject(Pair{String,Any}[
        Pair{String,Any}(registry.references[index], OrderedObject(Pair{String,Any}[
            Pair{String,Any}("type", "image"),
            Pair{String,Any}("part", _image_part_name(index)),
            Pair{String,Any}("format", _image_extension(image)),
        ])) for (index, image) in enumerate(registry.images)])
end

function _multipart_body(json::Vector{UInt8}, registry::_ImageRegistry)
    parts = Tuple{String,Vector{UInt8}}[
        ("Content-Disposition: form-data; name=\"request\"\r\n" *
         "Content-Type: application/json\r\n", json)]
    for (index, image) in enumerate(registry.images)
        name = _image_part_name(index)
        push!(parts, ("Content-Disposition: form-data; name=\"" * name * "\"; filename=\"" *
                      name * "." * _image_extension(image) * "\"\r\n" *
                      "Content-Type: " * _image_content_type(image) * "\r\n", image.bytes))
    end
    boundary = ""
    for _ in 1:8
        candidate = "jevclient-" * _random_token()
        needle = Vector{UInt8}(codeunits(candidate))
        if all(part -> isnothing(findfirst(needle, part[2])), parts)
            boundary = candidate
            break
        end
    end
    isempty(boundary) && throw(LocalValidationError("could not allocate a multipart boundary"))
    buffer = IOBuffer()
    for (headers, data) in parts
        write(buffer, "--", boundary, "\r\n", headers, "\r\n")
        write(buffer, data)
        write(buffer, "\r\n")
    end
    write(buffer, "--", boundary, "--\r\n")
    take!(buffer), "multipart/form-data; boundary=" * boundary
end

function _serialize_request(state, model::AbstractModelRef, questions::QuestionSet;
                            limits::ResourceLimits=ResourceLimits())
    value = _request_value(state, model, questions; limits=limits)
    strings = _collect_strings!(String[], value)
    registry = _ImageRegistry()
    value = _substitute_images(value, registry, strings)
    multimodal = !isempty(registry.images) ||
                 any(pair -> pair.second isa Box, questions.questions)
    if !isempty(registry.images)
        value = OrderedObject(Pair{String,Any}[value.pairs...,
                                               Pair{String,Any}("assets", _assets_value(registry))])
    end
    bytes = _json_bytes(value)
    length(bytes) <= limits.max_request_bytes ||
        throw(LocalValidationError("request exceeds configured byte limit";
                                   field_path=["request"]))
    isempty(registry.images) && return _EncodedRequest(bytes, "application/json; charset=utf-8", multimodal)

    expanded = length(bytes)
    for (image, uses) in zip(registry.images, registry.uses)
        length(image.bytes) <= limits.max_image_bytes ||
            throw(LocalValidationError("image exceeds configured byte limit"; field_path=["assets"]))
        expanded += uses * length(image.bytes)
    end
    expanded <= limits.max_image_request_bytes ||
        throw(LocalValidationError("expanded image request exceeds configured byte limit";
                                   field_path=["assets"]))
    body, content_type = _multipart_body(bytes, registry)
    length(body) <= limits.max_image_request_bytes ||
        throw(LocalValidationError("multipart request exceeds configured byte limit";
                                   field_path=["request"]))
    _EncodedRequest(body, content_type, multimodal)
end
