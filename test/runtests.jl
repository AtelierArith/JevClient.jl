using JevClient
using Test

const VALID_RESPONSE = """
{
  "model": "jev-1.13.0",
  "answers": {
    "urgent": {"type": "noul", "noul": 0.9},
    "team": {
      "type": "choice",
      "choice": "billing",
      "probabilities": {"billing": 0.8, "technical": 0.2},
      "confidence": 0.8
    },
    "mood": {
      "type": "score",
      "score": 0.2,
      "legend": ["calm", "angry"],
      "probabilities": [0.8, 0.2],
      "confidence": 0.8
    }
  },
  "usage": {"input_tokens": 3, "output_tokens": 2}
}
"""

function test_questions()
    questions = QuestionSet(
        "urgent" => Noul("Is this urgent?"; criteria=NoulCriteria(yes="yes", no="no")),
        "team" => Choice("Which team?"; criteria=["billing" => "billing", "technical" => "technical"]),
        "mood" => Score("How angry?"; criteria=["calm", "angry"]),
    )
    @test length(questions) == 3
    @test questions["urgent"] isa Noul
    @test_throws JevClient.LocalValidationError QuestionSet("urgent" => Noul("x"), "urgent" => Noul("y"))
    @test_throws JevClient.LocalValidationError Choice("x"; criteria=["only" => "x"])
    @test_throws JevClient.LocalValidationError Score("x"; criteria=["only"])
    @test_throws JevClient.LocalValidationError PinnedModel("jev-latest")
    @test MovingAlias("jev-latest").id == "jev-latest"
    questions
end

@testset "JevClient" begin
    questions = test_questions()

    @testset "content validation and serialization" begin
        request = JevClient._serialize_request((document="hello",), PinnedModel("jev-1.13.0"), questions)
        request_text = String(request)
        @test occursin("\"state\"", request_text)
        @test occursin("\"questions\"", request_text)
        @test occursin("\"true\"", request_text)
        @test_throws JevClient.LocalValidationError JevClient._serialize_request(1, PinnedModel("jev-1.13.0"), questions)
        @test_throws JevClient.LocalValidationError JevClient._serialize_request((value=NaN,), PinnedModel("jev-1.13.0"), questions)
        @test_throws JevClient.LocalValidationError JevClient._serialize_request((value=BigInt(1),), PinnedModel("jev-1.13.0"), questions)
        @test_throws JevClient.LocalValidationError JevClient._serialize_request(Dict(:foo => 1, "foo" => 2), PinnedModel("jev-1.13.0"), questions)
        cycle = Any[]
        push!(cycle, cycle)
        @test_throws JevClient.LocalValidationError JevClient._serialize_request(cycle, PinnedModel("jev-1.13.0"), questions)
    end

    @testset "credentials and redaction" begin
        credential = StaticCredential("  test-key-123  ")
        @test String(JevClient._credential(credential)) == "test-key-123"
        @test sprint(show, credential) == "<redacted>"
        @test !occursin("test-key-123", repr(credential))
        @test_throws JevClient.CredentialError StaticCredential("bad key")
        close(credential)
        @test !isopen(credential)
        @test_throws JevClient.CredentialError JevClient._credential(credential)
    end

    @testset "strict response validation" begin
        response = JevClient._parse_response(Vector{UInt8}(codeunits(VALID_RESPONSE)), questions)
        @test response.model == "jev-1.13.0"
        @test answer(response, "urgent").noul == 0.9
        @test answer(response, "team").choice == "billing"
        @test answer(response, "mood").score == 0.2
        @test response.usage.input_tokens == 3
        @test_throws JevClient.LocalValidationError answer(response, "missing")
        duplicate = replace(VALID_RESPONSE, "\"model\": \"jev-1.13.0\"," => "\"model\": \"jev-1.13.0\", \"model\": \"jev-1.13.0\",")
        @test_throws JevClient.MalformedJSONError JevClient._parse_response(Vector{UInt8}(codeunits(duplicate)), questions)
        invalid_probability = replace(VALID_RESPONSE, "0.8, 0.2" => "0.9, 0.2")
        @test_throws JevClient.ResponseValidationError JevClient._parse_response(Vector{UInt8}(codeunits(invalid_probability)), questions)
    end

    @testset "mock transport, retry, and lifecycle" begin
        attempts = Ref(0)
        request_ref = Ref{JevClient.MockRequest}()
        transport = JevClient.MockTransport(request -> begin
            attempts[] += 1
            request_ref[] = request
            if attempts[] == 1
                JevClient.TransportResponse(429, ["x-request-id" => "retry-1", "retry-after" => "0"], UInt8[])
            else
                JevClient.TransportResponse(200, ["Content-Type" => "application/json", "x-request-id" => "ok-1"], Vector{UInt8}(codeunits(VALID_RESPONSE)))
            end
        end)
        client = Client(model=PinnedModel("jev-1.13.0"), credential=StaticCredential("sentinel-key"),
                        retry=RetryPolicy(max_retries=1, initial_delay=0.0, max_delay=0.0, total_budget=5.0),
                        transport=transport)
        response = system_one(client; state="hello", questions)
        @test attempts[] == 2
        @test request_ref[].path == "/v1/systemone"
        @test any(pair -> pair.first == "Authorization" && pair.second == "Bearer sentinel-key", request_ref[].headers)
        @test !occursin("sentinel-key", sprint(show, client))
        @test sprint(show, response) == "SystemOneResponse(model=\"jev-1.13.0\", answers=3, usage=(input_tokens=3, output_tokens=2), request_id=present)"
        close(client)
        @test !isopen(client)
        @test_throws JevClient.ClosedClientError system_one(client; state="hello", questions)
    end

    @testset "with_client scopes lifecycle" begin
        transport = JevClient.MockTransport(request ->
            JevClient.TransportResponse(200, ["Content-Type" => "application/json", "x-request-id" => "ok-1"], Vector{UInt8}(codeunits(VALID_RESPONSE))))
        seen = Ref{Client}()
        result = with_client(model=PinnedModel("jev-1.13.0"), credential=StaticCredential("sentinel-key"),
                             transport=transport) do client
            seen[] = client
            @test isopen(client)
            system_one(client; state="hello", questions)
        end
        @test result isa SystemOneResponse
        @test !isopen(seen[])
        @test_throws JevClient.ClosedClientError system_one(seen[]; state="hello", questions)

        error_client = Ref{Client}()
        @test_throws ErrorException with_client(model=PinnedModel("jev-1.13.0"),
                                                credential=StaticCredential("sentinel-key"),
                                                transport=transport) do client
            error_client[] = client
            error("boom")
        end
        @test !isopen(error_client[])
    end
end
