using TimeTicks
using Misc
using OrderTypes

include("context.jl")
include("checks.jl")
include("functions.jl")

include("orders/utils.jl")
include("orders/state.jl")
include("orders/limit.jl")
include("orders/market.jl")

include("positions/utils.jl")
include("positions/state.jl")
include("positions/info.jl")

pong!(args...; kwargs...) = error("Not implemented")
const execute! = pong!

struct UpdateOrders <: ExecAction end
struct UpdateOrdersShuffled <: ExecAction end
struct CancelOrders <: ExecAction end
struct UpdatePositions <: ExecAction end
struct UpdateLeverage <: ExecAction end
struct UpdateMargin <: ExecAction end

export pong!, execute!, UpdateOrders, UpdateOrdersShuffled, CancelOrders
export UpdateLeverage, UpdateMargin, UpdatePositions
export limitorder, marketorder
export unfilled, committed, isfilled, islastfill, isfirstfill, attr
export queue!, cancel!, fullfill!, commit!
