module Data

include("data.jl")

function __init__()
    @require Temporal = "a110ec8f-48c8-5d59-8f7e-f91bc4cc0c3d" include("ts.jl")
    zi[] = ZarrInstance()
end

end # module Data
