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

function _serialize_request(state, model::AbstractModelRef, questions::QuestionSet;
                            limits::ResourceLimits=ResourceLimits())
    value = _request_value(state, model, questions; limits=limits)
    bytes = _json_bytes(value)
    length(bytes) <= limits.max_request_bytes ||
        throw(LocalValidationError("request exceeds configured byte limit";
                                   field_path=["request"]))
    return bytes
end
