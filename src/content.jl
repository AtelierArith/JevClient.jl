struct OrderedObject
    pairs::Vector{Pair{String,Any}}
end

Base.length(object::OrderedObject) = length(object.pairs)
Base.iterate(object::OrderedObject, state...) = iterate(object.pairs, state...)
function Base.getindex(object::OrderedObject, key::AbstractString)
    return first(filter(pair -> pair.first == key, object.pairs)).second
end

# JSON3 must never inspect OrderedObject's implementation field directly.  The
# only values reaching this mapping have already passed _normalize_json.
StructTypes.StructType(::Type{OrderedObject}) = StructTypes.CustomStruct()
function StructTypes.lower(object::OrderedObject)
    return Dict(pair.first => pair.second for pair in object.pairs)
end

function _invalid_text(s::AbstractString)
    !isvalid(s) || any(c -> (UInt32(c) < 0x20 || UInt32(c) == 0x7f), s)
end

function _check_string(s::AbstractString, limits::ResourceLimits; field::AbstractString="value")
    text = String(s)
    isvalid(text) || throw(LocalValidationError("invalid UTF-8 in $field"; field_path=[String(field)]))
    ncodeunits(text) <= limits.max_string_bytes ||
        throw(LocalValidationError("string exceeds configured limit"; field_path=[String(field)]))
    text
end

function _object_key(key, limits::ResourceLimits; field::AbstractString="object key")
    text = if key isa AbstractString
        String(key)
    elseif key isa Symbol
        String(key)
    else
        throw(LocalValidationError("object keys must be strings or symbols"; field_path=[String(field)]))
    end
    _check_string(text, limits; field=field)
    _invalid_text(text) && throw(LocalValidationError("object key contains a control character";
                                                     field_path=[String(field)]))
    text
end

function _normalize_json(value;
                         limits::ResourceLimits=ResourceLimits(),
                         depth::Int=0,
                         path::Vector{String}=String[],
                         active::IdDict{Any,Nothing}=IdDict{Any,Nothing}())
    depth <= limits.max_json_depth ||
        throw(LocalValidationError("JSON value exceeds maximum depth"; field_path=path))

    if isnothing(value)
        return nothing
    elseif value isa Bool
        return value
    elseif value isa AbstractString
        return _check_string(value, limits; field=isempty(path) ? "value" : path[end])
    elseif value isa BigInt
        throw(LocalValidationError("BigInt is not an accepted JSON value"; field_path=path))
    elseif value isa Integer
        try
            return Int64(value)
        catch
            throw(LocalValidationError("integer is outside the supported range"; field_path=path))
        end
    elseif value isa AbstractFloat
        number = Float64(value)
        isfinite(number) || throw(LocalValidationError("non-finite floating point value"; field_path=path))
        return number
    elseif value isa NamedTuple
        length(value) <= limits.max_container_items ||
            throw(LocalValidationError("object exceeds maximum item count"; field_path=path))
        names = fieldnames(typeof(value))
        entries = Vector{Pair{String,Any}}(undef, length(names))
        for (index, name) in enumerate(names)
            key = _object_key(name, limits; field="object key")
            child = getfield(value, name)
            entries[index] = Pair{String,Any}(key, _normalize_json(child;
                limits=limits, depth=depth + 1, path=[path; key], active=active))
        end
        return OrderedObject(entries)
    elseif value isa AbstractDict
        haskey(active, value) && throw(LocalValidationError("cyclic JSON value"; field_path=path))
        length(value) <= limits.max_container_items ||
            throw(LocalValidationError("object exceeds maximum item count"; field_path=path))
        active[value] = nothing
        raw_entries = collect(value)
        keys = [_object_key(raw_key, limits; field="object key") for (raw_key, _) in raw_entries]
        length(unique(keys)) == length(keys) ||
            throw(LocalValidationError("duplicate object key"; field_path=path))
        entries = Vector{Pair{String,Any}}(undef, length(raw_entries))
        for (index, pair) in enumerate(raw_entries)
            key = keys[index]
            entries[index] = Pair{String,Any}(key, _normalize_json(pair.second;
                limits=limits, depth=depth + 1, path=[path; key], active=active))
        end
        delete!(active, value)
        sort!(entries; by=first)
        return OrderedObject(entries)
    elseif value isa AbstractVector
        value isa SubArray && throw(LocalValidationError("array views are not accepted"; field_path=path))
        haskey(active, value) && throw(LocalValidationError("cyclic JSON value"; field_path=path))
        length(value) <= limits.max_container_items ||
            throw(LocalValidationError("array exceeds maximum item count"; field_path=path))
        active[value] = nothing
        items = [_normalize_json(child;
            limits=limits, depth=depth + 1, path=[path; string(index)], active=active)
                 for (index, child) in pairs(value)]
        delete!(active, value)
        return items
    elseif value isa Tuple
        length(value) <= limits.max_container_items ||
            throw(LocalValidationError("array exceeds maximum item count"; field_path=path))
        return [_normalize_json(child;
            limits=limits, depth=depth + 1, path=[path; string(index)], active=active)
                for (index, child) in pairs(value)]
    else
        throw(LocalValidationError("value has no permitted JSON representation"; field_path=path))
    end
end

const _JSON_VALUE = Union{Nothing, Bool, Int64, Float64, String, Vector{Any}, OrderedObject}

function _json_bytes(value)
    value isa _JSON_VALUE ||
        throw(LocalValidationError("internal value is not JSON-normalized"))
    Vector{UInt8}(codeunits(JSON3.write(value)))
end

function _validate_normalized(value;
                              limits::ResourceLimits,
                              depth::Int=0,
                              path::Vector{String}=String[])
    depth <= limits.max_json_depth ||
        throw(LocalValidationError("JSON value exceeds maximum depth"; field_path=path))
    if value isa String
        _check_string(value, limits; field=isempty(path) ? "value" : path[end])
    elseif value isa Vector{Any}
        length(value) <= limits.max_container_items ||
            throw(LocalValidationError("array exceeds maximum item count"; field_path=path))
        for (index, child) in pairs(value)
            _validate_normalized(child; limits=limits, depth=depth + 1,
                                 path=[path; string(index)])
        end
    elseif value isa OrderedObject
        length(value.pairs) <= limits.max_container_items ||
            throw(LocalValidationError("object exceeds maximum item count"; field_path=path))
        keys = first.(value.pairs)
        length(unique(keys)) == length(keys) ||
            throw(LocalValidationError("duplicate object key"; field_path=path))
        for pair in value.pairs
            _object_key(pair.first, limits; field="object key")
            _validate_normalized(pair.second; limits=limits, depth=depth + 1,
                                 path=[path; pair.first])
        end
    end
    nothing
end
