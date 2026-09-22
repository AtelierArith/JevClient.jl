using Documenter
using JevClient

DocMeta.setdocmeta!(JevClient, :DocTestSetup, :(using JevClient); recursive=true)

makedocs(;
    modules = [JevClient],
    authors = "Satoshi Terasaki <terasakisatoshi.math@gmail.com> and contributors",
    sitename = "JevClient.jl",
    format = Documenter.HTML(;
        canonical = "https://AtelierArith.github.io/JevClient.jl/",
        edit_link = "main",
        assets = String[],
    ),
    pages = [
        "Home" => "index.md",
        "API Reference" => "api.md",
        "Security" => "security.md",
    ],
)

deploydocs(;
    repo = "github.com/AtelierArith/JevClient.jl",
    devbranch = "main",
)
