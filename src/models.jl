abstract type AbstractModelRef end

function _validate_model_id(id::AbstractString)
    value = String(id)
    isempty(value) && throw(LocalValidationError("model ID must not be empty"; field_path=["model"]))
    isascii(value) || throw(LocalValidationError("model ID must be ASCII"; field_path=["model"]))
    ncodeunits(value) <= 128 || throw(LocalValidationError("model ID is too long"; field_path=["model"]))
    _invalid_text(value) && throw(LocalValidationError("model ID contains a control character";
                                                      field_path=["model"]))
    any(isspace, value) && throw(LocalValidationError("model ID must not contain whitespace";
                                                     field_path=["model"]))
    value
end

struct PinnedModel <: AbstractModelRef
    id::String
    function PinnedModel(id::String)
        value = _validate_model_id(id)
        value in ("latest", "preview", "jev-latest", "jev-preview") &&
            throw(LocalValidationError("moving model aliases require MovingAlias"; field_path=["model"]))
        new(value)
    end
end

struct MovingAlias <: AbstractModelRef
    id::String
    function MovingAlias(id::String)
        value = _validate_model_id(id)
        value in ("jev-latest", "jev-preview", "latest", "preview") ||
            throw(LocalValidationError("unknown moving model alias"; field_path=["model"]))
        new(value)
    end
end

function PinnedModel(id::AbstractString)
    PinnedModel(String(id))
end

function MovingAlias(id::AbstractString)
    MovingAlias(String(id))
end

model_id(model::AbstractModelRef) = model.id

Base.show(io::IO, model::PinnedModel) = print(io, "PinnedModel(\"", model.id, "\")")
Base.show(io::IO, model::MovingAlias) = print(io, "MovingAlias(\"", model.id, "\")")

struct ModelInfo
    name::String
    description::String
    release_date::Date
end

struct ModelList
    models::Vector{ModelInfo}
end
