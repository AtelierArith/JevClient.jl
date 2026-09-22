abstract type AbstractQuestion end

"""
    NoulCriteria(; yes=nothing, no=nothing)

Criteria for a [`Noul`](@ref) question. At least one of `yes` or `no` must be
given; each value is any JSON-serializable description of what satisfies that
outcome.
"""
struct NoulCriteria
    yes::Any
    no::Any
end

function NoulCriteria(; yes=nothing, no=nothing)
    isnothing(yes) && isnothing(no) &&
        throw(LocalValidationError("NoulCriteria requires yes or no"; field_path=["criteria"]))
    normalized_yes = isnothing(yes) ? nothing : _normalize_json(yes)
    normalized_no = isnothing(no) ? nothing : _normalize_json(no)
    NoulCriteria(normalized_yes, normalized_no)
end

"""
    Noul(instructions; criteria=nothing)

Yes/no (noul) question. Returns a [`NoulAnswer`](@ref) whose `noul` field is a
probability. `instructions` is any non-null JSON-serializable value and
`criteria` is an optional [`NoulCriteria`](@ref).
"""
struct Noul <: AbstractQuestion
    instructions::Any
    criteria::Union{Nothing,NoulCriteria}
end

function Noul(instructions; criteria::Union{Nothing,NoulCriteria}=nothing)
    normalized = _normalize_json(instructions)
    isnothing(normalized) &&
        throw(LocalValidationError("instructions must not be null"; field_path=["instructions"]))
    Noul(normalized, criteria)
end

"""
    Choice(instructions; criteria)

Multiple-choice question over 2 to 255 candidates. `criteria` is a collection of
`ID => description` pairs, where each ID is a non-empty `AbstractString`.
Returns a [`ChoiceAnswer`](@ref) with the selected ID and the full probability
distribution. Treat the returned ID as untrusted and map it through an
application-owned allowlist.
"""
struct Choice <: AbstractQuestion
    instructions::Any
    criteria::Vector{Pair{String,Any}}
end

function _choice_pairs(criteria)
    iterable = criteria isa AbstractDict ? collect(criteria) : criteria
    iterable isa AbstractString &&
        throw(LocalValidationError("Choice criteria must be a collection of pairs"; field_path=["criteria"]))
    items = collect(iterable)
    ids = [_choice_id(item) for item in items]
    length(unique(ids)) == length(ids) ||
        throw(LocalValidationError("duplicate Choice ID"; field_path=["criteria"]))
    2 <= length(items) <= 255 ||
        throw(LocalValidationError("Choice requires between 2 and 255 candidates";
                                   field_path=["criteria"]))
    return [Pair{String,Any}(id, isnothing(item.second) ? nothing : _normalize_json(item.second))
            for (id, item) in zip(ids, items)]
end

function _choice_id(item)
    item isa Pair || throw(LocalValidationError("Choice criteria must contain pairs";
                                                field_path=["criteria"]))
    item.first isa AbstractString ||
        throw(LocalValidationError("Choice IDs must be strings"; field_path=["criteria"]))
    id = _check_string(item.first, ResourceLimits(); field="choice ID")
    isempty(id) && throw(LocalValidationError("Choice IDs must not be empty";
                                              field_path=["criteria"]))
    _invalid_text(id) && throw(LocalValidationError("Choice ID contains a control character";
                                                    field_path=["criteria", id]))
    return id
end

function Choice(instructions; criteria)
    normalized_instructions = _normalize_json(instructions)
    isnothing(normalized_instructions) &&
        throw(LocalValidationError("instructions must not be null"; field_path=["instructions"]))
    Choice(normalized_instructions, _choice_pairs(criteria))
end

"""
    Score(instructions; criteria)

Ordered score question with 2 to 10 labels, given as a vector of non-empty
strings in ascending order. Returns a [`ScoreAnswer`](@ref) with the chosen
level and its probability.
"""
struct Score <: AbstractQuestion
    instructions::Any
    criteria::Vector{String}
end

function Score(instructions; criteria)
    normalized_instructions = _normalize_json(instructions)
    isnothing(normalized_instructions) &&
        throw(LocalValidationError("instructions must not be null"; field_path=["instructions"]))
    criteria isa AbstractString &&
        throw(LocalValidationError("Score criteria must be a collection of labels"; field_path=["criteria"]))
    labels = [_score_label(label) for label in criteria]
    2 <= length(labels) <= 10 ||
        throw(LocalValidationError("Score requires between 2 and 10 levels";
                                   field_path=["criteria"]))
    Score(normalized_instructions, labels)
end

function _score_label(label)
    label isa AbstractString ||
        throw(LocalValidationError("Score labels must be strings"; field_path=["criteria"]))
    value = _check_string(label, ResourceLimits(); field="score label")
    isempty(value) && throw(LocalValidationError("Score labels must not be empty";
                                                 field_path=["criteria"]))
    _invalid_text(value) && throw(LocalValidationError("Score label contains a control character";
                                                       field_path=["criteria"]))
    return value
end

"""
    QuestionSet(items::Pair...)

Ordered collection of `ID => question` pairs, where each question is a
[`Noul`](@ref), [`Choice`](@ref), or [`Score`](@ref). IDs must be unique
non-empty strings. Supports `length`, iteration, and `questions[id]`.
"""
struct QuestionSet
    questions::Vector{Pair{String,AbstractQuestion}}
end

function QuestionSet(items::Pair...)
    isempty(items) && throw(LocalValidationError("QuestionSet must contain at least one question";
                                                 field_path=["questions"]))
    length(items) <= 1024 || throw(LocalValidationError("QuestionSet has too many questions";
                                                        field_path=["questions"]))
    ids = [_question_id(item) for item in items]
    length(unique(ids)) == length(ids) ||
        throw(LocalValidationError("duplicate question ID"; field_path=["questions"]))
    questions = Vector{Pair{String,AbstractQuestion}}(undef, length(items))
    for (index, item) in enumerate(items)
        item.first isa AbstractString ||
            throw(LocalValidationError("question IDs must be strings"; field_path=["questions"]))
        item.second isa AbstractQuestion ||
            throw(LocalValidationError("QuestionSet values must be questions"; field_path=["questions"]))
        questions[index] = Pair{String,AbstractQuestion}(ids[index], item.second)
    end
    return QuestionSet(questions)
end

function _question_id(item)
    item.first isa AbstractString ||
        throw(LocalValidationError("question IDs must be strings"; field_path=["questions"]))
    id = _check_string(item.first, ResourceLimits(); field="question ID")
    isempty(id) && throw(LocalValidationError("question ID must not be empty";
                                              field_path=["questions"]))
    length(id) <= 128 || throw(LocalValidationError("question ID is too long";
                                                    field_path=["questions", id]))
    _invalid_text(id) && throw(LocalValidationError("question ID contains a control character";
                                                    field_path=["questions", id]))
    !(first(id) == ' ' || last(id) == ' ') ||
        throw(LocalValidationError("question ID must not have surrounding whitespace";
                                   field_path=["questions", id]))
    return id
end

Base.length(questions::QuestionSet) = length(questions.questions)
Base.iterate(questions::QuestionSet, state...) = iterate(questions.questions, state...)
function Base.getindex(questions::QuestionSet, id::AbstractString)
    return first(filter(pair -> pair.first == id, questions.questions)).second
end
