using Aqua
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

const OBJECT_SCORE_RESPONSE = replace(VALID_RESPONSE,
    "\"legend\": [\"calm\", \"angry\"]" => "\"legend\": {\"0\": \"calm\", \"1\": \"angry\"}",
    "\"probabilities\": [0.8, 0.2]" => "\"probabilities\": {\"0\": 0.8, \"1\": 0.2}")

function crc32(data)
    c = 0xffffffff
    for byte in data
        c ⊻= UInt32(byte)
        for _ in 1:8
            c = (c & 0x00000001) == 0x00000001 ? (0xedb88320 ⊻ (c >> 1)) : (c >> 1)
        end
    end
    ~c
end

be32(x) = UInt8[(x >> 24) & 0xff, (x >> 16) & 0xff, (x >> 8) & 0xff, x & 0xff]

png_chunk(kind, data) = UInt8[be32(length(data)); codeunits(kind); data;
                              be32(crc32(UInt8[codeunits(kind); data]))]

# Uncompressed (stored-block) RGB PNG: a white canvas with a red rectangle.
function make_png(width, height; rect=(0, 0, 0, 0), extra_chunks=Vector{UInt8}[])
    raw = UInt8[]
    for y in 0:height-1
        push!(raw, 0x00)
        for x in 0:width-1
            red = rect[1] <= x < rect[3] && rect[2] <= y < rect[4]
            append!(raw, red ? UInt8[0xff, 0x00, 0x00] : UInt8[0xff, 0xff, 0xff])
        end
    end
    zlib = UInt8[0x78, 0x01]
    blocks = collect(Iterators.partition(raw, 65535))
    for (index, block) in enumerate(blocks)
        n = length(block)
        append!(zlib, UInt8[index == length(blocks) ? 0x01 : 0x00, n & 0xff, n >> 8,
                            ~UInt8(n & 0xff), ~UInt8(n >> 8)])
        append!(zlib, block)
    end
    a, b = UInt32(1), UInt32(0)
    for byte in raw
        a = (a + byte) % 65521
        b = (b + a) % 65521
    end
    append!(zlib, be32((b << 16) | a))
    ihdr = UInt8[be32(width); be32(height); UInt8[0x08, 0x02, 0x00, 0x00, 0x00]]
    UInt8[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
          png_chunk("IHDR", ihdr)..., reduce(vcat, extra_chunks; init=UInt8[])...,
          png_chunk("IDAT", zlib)..., png_chunk("IEND", UInt8[])...]
end

# Header-only baseline JPEG; enough for local header validation.
make_jpeg(width, height) = UInt8[0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, codeunits("JFIF")..., 0x00,
    0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00,
    0xff, 0xc0, 0x00, 0x11, 0x08, height >> 8, height & 0xff, width >> 8, width & 0xff,
    0x03, 0x01, 0x22, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01, 0xff, 0xd9]

function multipart_parts(body::Vector{UInt8}, content_type::AbstractString)
    boundary = split(content_type, "boundary=")[2]
    text = String(copy(body))
    sections = split(text, "--" * boundary)
    @test strip(sections[end]) == "--"
    parts = Dict{String,Tuple{String,String}}()
    for section in sections[2:end-1]
        head, data = split(section, "\r\n\r\n"; limit=2)
        name = match(r"name=\"([^\"]+)\"", head).captures[1]
        parts[name] = (String(head), String(chopsuffix(data, "\r\n")))
    end
    parts
end

const BOX_RESPONSE = """
{
  "model": "jev-1.14.0",
  "answers": {
    "where": {"type": "box", "box": {"left": 0.25, "top": 0.1, "right": 0.75, "bottom": 0.5}, "confidence": 0.7},
    "present": {"type": "noul", "noul": 0.95}
  },
  "usage": {"input_tokens": 300, "output_tokens": 2}
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
    @testset "Aqua" begin
        Aqua.test_all(JevClient)
    end

    questions = test_questions()

    @testset "content validation and serialization" begin
        request = JevClient._serialize_request((document="hello",), PinnedModel("jev-1.13.0"), questions)
        @test request.content_type == "application/json; charset=utf-8"
        @test !request.multimodal
        request_text = String(request.body)
        @test occursin("\"state\"", request_text)
        @test occursin("\"questions\"", request_text)
        @test occursin("\"true\"", request_text)
        @test String(JevClient._serialize_request([1, 2], PinnedModel("jev-1.13.0"), questions).body) |>
              startswith("{\"state\":[1,2],")
        @test String(JevClient._serialize_request(("a", 1.5), PinnedModel("jev-1.13.0"), questions).body) |>
              startswith("{\"state\":[\"a\",1.5],")
        @test_throws JevClient.LocalValidationError JevClient._serialize_request(1, PinnedModel("jev-1.13.0"), questions)
        @test_throws JevClient.LocalValidationError JevClient._serialize_request((value=NaN,), PinnedModel("jev-1.13.0"), questions)
        @test_throws JevClient.LocalValidationError JevClient._serialize_request((value=BigInt(1),), PinnedModel("jev-1.13.0"), questions)
        @test_throws JevClient.LocalValidationError JevClient._serialize_request(Dict(:foo => 1, "foo" => 2), PinnedModel("jev-1.13.0"), questions)
        cycle = Any[]
        push!(cycle, cycle)
        @test_throws JevClient.LocalValidationError JevClient._serialize_request(cycle, PinnedModel("jev-1.13.0"), questions)
    end

    @testset "wire key order and golden serialization" begin
        ordered = QuestionSet(
            "zeta" => Choice("Pick"; criteria=["z" => "last letter", "a" => nothing, "m" => (k=1, b=2.5)]),
            "alpha" => Noul("Yes?"; criteria=NoulCriteria(no="no")),
            "mid" => Score("Rate"; criteria=["low", "high"]),
        )
        request = String(JevClient._serialize_request(Dict("b" => true, "a" => [1, nothing]),
                                                       PinnedModel("jev-1.13.0"), ordered).body)
        @test request == "{\"state\":{\"a\":[1,null],\"b\":true},\"model\":\"jev-1.13.0\"," *
            "\"questions\":{\"zeta\":{\"type\":\"choice\",\"instructions\":\"Pick\"," *
            "\"criteria\":{\"z\":\"last letter\",\"a\":null,\"m\":{\"k\":1,\"b\":2.5}}}," *
            "\"alpha\":{\"type\":\"noul\",\"instructions\":\"Yes?\",\"criteria\":{\"false\":\"no\"}}," *
            "\"mid\":{\"type\":\"score\",\"instructions\":\"Rate\",\"criteria\":[\"low\",\"high\"]}}}"
        escaped = String(JevClient._serialize_request("quote\" slash\\ é", PinnedModel("jev-1.13.0"), ordered).body)
        @test startswith(escaped, "{\"state\":\"quote\\\" slash\\\\ é\",")
    end

    @testset "bounded JSON parser" begin
        parsed = JevClient._parse_json(Vector{UInt8}(codeunits("{\"b\":[1,2.5,null],\"a\":\"\\u00e9\"}")))
        @test collect(keys(parsed)) == ["b", "a"]
        @test parsed["a"] == "é"
        @test parsed["b"] isa Vector{Any}
        @test_throws JevClient.MalformedJSONError JevClient._parse_json(Vector{UInt8}(codeunits("{\"a\":1,\"\\u0061\":2}")))
        @test_throws JevClient.MalformedJSONError JevClient._parse_json(Vector{UInt8}(codeunits("{\"a\":NaN}")))
        @test_throws JevClient.MalformedJSONError JevClient._parse_json(Vector{UInt8}(codeunits("{\"a\":1} x")))
        deep = repeat("[", 40) * repeat("]", 40)
        @test_throws JevClient.MalformedJSONError JevClient._parse_json(Vector{UInt8}(codeunits(deep)))
    end

    @testset "images" begin
        png_bytes = make_png(320, 300)
        image = Image(png_bytes)
        @test image.format === :png
        @test (image.width, image.height) == (320, 300)
        png_bytes[1] = 0x00
        @test Image(make_png(320, 300)).bytes !== png_bytes
        @test sprint(show, image) == "Image(png, 320x300, $(length(image.bytes)) bytes)"
        jpeg = Image(make_jpeg(640, 480))
        @test jpeg.format === :jpeg
        @test (jpeg.width, jpeg.height) == (640, 480)
        @test_throws JevClient.LocalValidationError Image(make_png(100, 400))
        @test_throws JevClient.LocalValidationError Image(make_jpeg(2000, 400))
        @test_throws JevClient.LocalValidationError Image(UInt8[0x47, 0x49, 0x46, 0x38])
        @test_throws JevClient.LocalValidationError Image(make_png(320, 300)[1:40])
        actl = png_chunk("acTL", UInt8[be32(2); be32(0)])
        @test_throws JevClient.LocalValidationError Image(make_png(320, 300; extra_chunks=[actl]))
        @test_throws JevClient.LocalValidationError Image(joinpath(@__DIR__, "missing.png"))
        mktempdir() do dir
            path = joinpath(dir, "door.png")
            write(path, make_png(400, 300))
            @test Image(path).width == 400
        end
        @test_throws JevClient.LocalValidationError JevClient._json_bytes(image)
    end

    @testset "multimodal serialization" begin
        door = Image(make_png(320, 300))
        palm = Image(make_jpeg(640, 480))
        mm_questions = QuestionSet(
            "gesture" => Choice("Which gesture is shown in `photo`?";
                                criteria=["open_palm" => (description="An open palm.", examples=[palm]),
                                          "fist" => "A closed fist."]),
            "same" => Noul(["Is this the same door?", door]),
        )
        request = JevClient._serialize_request((photo=door, note="front door"),
                                               PinnedModel("jev-1.13.0"), mm_questions)
        @test request.multimodal
        @test startswith(request.content_type, "multipart/form-data; boundary=")
        parts = multipart_parts(request.body, request.content_type)
        @test sort(collect(keys(parts))) == ["image-1", "image-2", "request"]
        @test occursin("Content-Type: application/json", parts["request"][1])
        @test occursin("filename=\"image-1.png\"", parts["image-1"][1])
        @test occursin("Content-Type: image/png", parts["image-1"][1])
        @test occursin("Content-Type: image/jpeg", parts["image-2"][1])
        @test codeunits(parts["image-1"][2]) == door.bytes
        @test codeunits(parts["image-2"][2]) == palm.bytes
        wire = JevClient._parse_json(Vector{UInt8}(codeunits(parts["request"][2])))
        @test collect(keys(wire)) == ["state", "model", "questions", "assets"]
        reference = wire["state"]["photo"]
        @test startswith(reference, "jevclient-image-")
        @test wire["questions"]["same"]["instructions"][2] == reference
        palm_reference = wire["questions"]["gesture"]["criteria"]["open_palm"]["examples"][1]
        @test palm_reference != reference
        @test wire["assets"][reference]["part"] == "image-1"
        @test wire["assets"][reference]["type"] == "image"
        @test wire["assets"][reference]["format"] == "png"
        @test wire["assets"][palm_reference]["format"] == "jpg"
        @test length(wire["assets"]) == 2

        box_only = JevClient._serialize_request("text", PinnedModel("jev-1.14.0"),
                                                QuestionSet("where" => Box("Find the door.")))
        @test box_only.multimodal
        @test box_only.content_type == "application/json; charset=utf-8"
        @test String(box_only.body) == "{\"state\":\"text\",\"model\":\"jev-1.14.0\"," *
            "\"questions\":{\"where\":{\"type\":\"box\",\"instructions\":\"Find the door.\"}}}"

        small = ResourceLimits(max_image_bytes=100)
        @test_throws JevClient.LocalValidationError JevClient._serialize_request(door,
            PinnedModel("jev-1.13.0"), QuestionSet("q" => Noul("x")); limits=small)
        expanded = ResourceLimits(max_image_request_bytes=3 * length(door.bytes))
        @test_throws JevClient.LocalValidationError JevClient._serialize_request([door, door, door],
            PinnedModel("jev-1.13.0"), QuestionSet("q" => Noul("x")); limits=expanded)
        @test_throws JevClient.LocalValidationError Box("")
        @test_throws JevClient.LocalValidationError Box(42)
    end

    @testset "multimodal requests and Box answers" begin
        seen = Ref{JevClient.MockRequest}()
        calls = Ref(0)
        transport = JevClient.MockTransport(request -> begin
            calls[] += 1
            seen[] = request
            JevClient.TransportResponse(200, ["Content-Type" => "application/json"],
                                        Vector{UInt8}(codeunits(BOX_RESPONSE)))
        end)
        box_questions = QuestionSet("where" => Box("Locate the red square in `photo`."),
                                    "present" => Noul("Is there a red square in `photo`?"))
        state = (photo=Image(make_png(320, 300)),)
        with_client(model=PinnedModel("jev-1.14.0"), credential=StaticCredential("sentinel-key"),
                    transport=transport) do client
            @test_throws JevClient.LocalValidationError system_one(client; state, questions=box_questions)
            @test_throws JevClient.LocalValidationError system_one(client; state="text",
                questions=QuestionSet("where" => Box("Find it.")))
            @test calls[] == 0
            response = system_one(client; state, questions=box_questions, danger_zone_images=true)
            @test calls[] == 1
            box = answer(response, "where")
            @test box isa BoxAnswer
            @test (box.left, box.top, box.right, box.bottom, box.confidence) == (0.25, 0.1, 0.75, 0.5, 0.7)
            @test JevClient._header_value(seen[].headers, "TypeSafe-Danger-Zone-Images") == "true"
            @test startswith(JevClient._header_value(seen[].headers, "Content-Type"), "multipart/form-data; boundary=")

            @test_throws JevClient.ResponseValidationError system_one(client; state="hello", questions)
            @test isnothing(JevClient._header_value(seen[].headers, "TypeSafe-Danger-Zone-Images"))
            @test JevClient._header_value(seen[].headers, "Content-Type") == "application/json; charset=utf-8"
        end

        parse_box(text) = JevClient._parse_response(Vector{UInt8}(codeunits(text)), box_questions)
        @test parse_box(BOX_RESPONSE)["present"].noul == 0.95
        @test_throws JevClient.ResponseValidationError parse_box(replace(BOX_RESPONSE, "\"left\": 0.25" => "\"left\": 0.8"))
        @test_throws JevClient.ResponseValidationError parse_box(replace(BOX_RESPONSE, "\"bottom\": 0.5" => "\"bottom\": 0.1"))
        @test_throws JevClient.ResponseValidationError parse_box(replace(BOX_RESPONSE, "\"right\": 0.75" => "\"right\": 1.5"))
        @test_throws JevClient.ResponseValidationError parse_box(replace(BOX_RESPONSE, "\"confidence\": 0.7" => "\"confidence\": -0.1"))
        @test_throws JevClient.ResponseValidationError parse_box(replace(BOX_RESPONSE, ", \"bottom\": 0.5" => ""))
        @test_throws JevClient.ResponseValidationError parse_box(replace(BOX_RESPONSE, "\"type\": \"box\"" => "\"type\": \"noul\""))
    end

    @testset "model list" begin
        body = """{"models": [{"name": "jev-latest", "description": "Latest", "release_date": "2026-09-10T18:38:01.391457+00:00"},
                              {"name": "jev-1.13.0", "description": "", "release_date": "2026-06-01"}]}"""
        transport = JevClient.MockTransport(request ->
            JevClient.TransportResponse(200, ["Content-Type" => "application/json"], Vector{UInt8}(codeunits(body))))
        with_client(model=PinnedModel("jev-1.13.0"), credential=StaticCredential("sentinel-key"),
                    transport=transport, max_inflight=2) do client
            for _ in 1:5
                models = list_models(client).models
                @test [model.name for model in models] == ["jev-latest", "jev-1.13.0"]
                @test models[1].release_date == JevClient.Date(2026, 9, 10)
            end
        end
        parse_list(date) = JevClient._parse_model_list(Vector{UInt8}(codeunits(
            "{\"models\": [{\"name\": \"m\", \"description\": \"\", \"release_date\": \"$date\"}]}")))
        @test parse_list("2026-09-10T18:38:01Z").models[1].release_date == JevClient.Date(2026, 9, 10)
        @test_throws JevClient.ResponseValidationError parse_list("2026-09-10 junk")
        @test_throws JevClient.ResponseValidationError parse_list("2026-13-10")
        @test_throws JevClient.ResponseValidationError parse_list("10/09/2026")
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

        object_response = JevClient._parse_response(Vector{UInt8}(codeunits(OBJECT_SCORE_RESPONSE)), questions)
        @test answer(object_response, "mood").legend == ["calm", "angry"]
        @test answer(object_response, "mood").probabilities == [0.8, 0.2]
        @test answer(object_response, "mood").score == 0.2
        missing_index = replace(OBJECT_SCORE_RESPONSE, "\"0\": 0.8, " => "")
        @test_throws JevClient.ResponseValidationError JevClient._parse_response(Vector{UInt8}(codeunits(missing_index)), questions)
        noncanonical_index = replace(OBJECT_SCORE_RESPONSE, "\"0\": \"calm\"" => "\"00\": \"calm\"")
        @test_throws JevClient.ResponseValidationError JevClient._parse_response(Vector{UInt8}(codeunits(noncanonical_index)), questions)
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
