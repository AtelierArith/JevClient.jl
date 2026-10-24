const _MAX_IMAGE_FILE_BYTES = 16 * 1024 * 1024
const _MIN_IMAGE_SIDE = 280
const _MAX_IMAGE_SIDE = 1568
const _PNG_SIGNATURE = UInt8[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]

"""
    Image(path::AbstractString)
    Image(bytes::AbstractVector{UInt8})

Experimental still PNG or JPEG image for multimodal System One requests. Place
an `Image` anywhere a JSON value is accepted in `state`, question
`instructions`, or `criteria`; JevClient assigns it an opaque reference and
uploads it as a multipart file part. Requests containing an `Image` require
`system_one(...; danger_zone_images=true)`.

The image is validated locally: PNG or JPEG only (animated PNG is rejected), at
most 16 MiB, and each side between 280 and 1568 pixels. Images are never
resized. The bytes are copied on construction and are never shown or logged.
"""
struct Image
    bytes::Vector{UInt8}
    format::Symbol
    width::Int
    height::Int
end

function Image(bytes::AbstractVector{UInt8})
    data = Vector{UInt8}(bytes)
    length(data) <= _MAX_IMAGE_FILE_BYTES ||
        throw(LocalValidationError("image exceeds the maximum file size"; field_path=["image"]))
    format, width, height = _image_header(data)
    for side in (width, height)
        _MIN_IMAGE_SIDE <= side <= _MAX_IMAGE_SIDE ||
            throw(LocalValidationError("image width and height must be between 280 and 1568 pixels";
                                       field_path=["image"]))
    end
    return Image(data, format, width, height)
end

function Image(path::AbstractString)
    isfile(path) || throw(LocalValidationError("image file does not exist"; field_path=["image"]))
    filesize(path) <= _MAX_IMAGE_FILE_BYTES ||
        throw(LocalValidationError("image exceeds the maximum file size"; field_path=["image"]))
    data = open(io -> read(io, _MAX_IMAGE_FILE_BYTES + 1), path)
    return Image(data)
end

Base.show(io::IO, image::Image) =
    print(io, "Image(", image.format, ", ", image.width, "x", image.height, ", ",
          length(image.bytes), " bytes)")

# An Image must only reach the wire as a multipart file part; never serialize
# its bytes into JSON.
JSON.lower(::Image) = throw(LocalValidationError("image was not replaced by an asset reference"))

_image_extension(image::Image) = image.format === :png ? "png" : "jpg"
_image_content_type(image::Image) = image.format === :png ? "image/png" : "image/jpeg"

_be16(data::Vector{UInt8}, pos::Int) = (Int(data[pos]) << 8) | Int(data[pos + 1])
_be32(data::Vector{UInt8}, pos::Int) =
    (Int(data[pos]) << 24) | (Int(data[pos + 1]) << 16) | (Int(data[pos + 2]) << 8) | Int(data[pos + 3])

_image_error(message="image is not a valid still PNG or JPEG") =
    throw(LocalValidationError(message; field_path=["image"]))

function _image_header(data::Vector{UInt8})
    if length(data) >= 8 && data[1:8] == _PNG_SIGNATURE
        return _png_header(data)
    elseif length(data) >= 3 && data[1] == 0xff && data[2] == 0xd8 && data[3] == 0xff
        return _jpeg_header(data)
    end
    _image_error()
end

function _png_header(data::Vector{UInt8})
    length(data) >= 33 || _image_error()
    _be32(data, 9) == 13 && String(data[13:16]) == "IHDR" || _image_error()
    width = _be32(data, 17)
    height = _be32(data, 21)
    pos = 9
    while pos + 7 <= length(data)
        chunk_length = _be32(data, pos)
        chunk_type = String(data[pos + 4:pos + 7])
        chunk_type == "acTL" && _image_error("animated PNG images are not supported")
        chunk_type == "IDAT" && return (:png, width, height)
        chunk_type == "IEND" && break
        next = pos + 12 + chunk_length
        next > pos || _image_error()
        pos = next
    end
    _image_error()
end

function _jpeg_header(data::Vector{UInt8})
    pos = 3
    while pos <= length(data)
        data[pos] == 0xff || _image_error()
        while pos <= length(data) && data[pos] == 0xff
            pos += 1
        end
        pos <= length(data) || _image_error()
        marker = data[pos]
        pos += 1
        (0xd0 <= marker <= 0xd7 || marker == 0x01) && continue
        (marker == 0xd9 || marker == 0xda) && _image_error()
        pos + 1 <= length(data) || _image_error()
        segment_length = _be16(data, pos)
        segment_length >= 2 && pos + segment_length - 1 <= length(data) || _image_error()
        if 0xc0 <= marker <= 0xcf && !(marker in (0xc4, 0xc8, 0xcc))
            segment_length >= 7 || _image_error()
            return (:jpeg, _be16(data, pos + 5), _be16(data, pos + 3))
        end
        pos += segment_length
    end
    _image_error()
end
