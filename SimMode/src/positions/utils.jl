using .OrderTypes.ExchangeTypes: ExchangeID
using .OrderTypes: PositionSide, PositionTrade, LiquidationType, ReduceOnlyOrder
using .Strategies.Instruments.Derivatives: Derivative
using Executors.Instances: leverage_tiers, tier, position
import Executors.Instances: Position, MarginInstance
using Executors: withtrade!, maintenance!, orders, isliquidatable, LIQUIDATION_FEES
using .Strategies: IsolatedStrategy, MarginStrategy, exchangeid
using .Instances: PositionOpen, PositionUpdate, PositionClose
using .Instances: margin, maintenance, status, posside
using .Misc: DFT
import Executors: position!

"""
Open a position in `s` with `ai` using `t`.

$(TYPEDSIGNATURES)

The function opens a position in the specified strategy using the given margin instance and position trade.
"""
function open_position!(
    s::IsolatedStrategy, ai::MarginInstance, t::PositionTrade{P};
) where {P<:PositionSide}
    # NOTE: Order of calls is important
    po = position(ai, P)
    @deassert cash(ai, opposite(P())) == 0.0 (cash(ai, opposite(P()))),
    status(ai, opposite(P()))
    @deassert !isopen(po)
    @deassert notional(po) == 0.0
    # Cash should already be updated from trade construction
    @deassert abs(cash(po)) == abs(cash(ai, P())) >= abs(t.amount)
    withtrade!(po, t)
    # Notional should never be above the trade size
    # unless fees are negative
    @deassert notional(po) < abs(t.size) ||
        minfees(ai) < 0.0 ||
        abs(t.amount) < abs(cash(ai, P()))
    # finalize
    status!(ai, P(), PositionOpen())
    @deassert status(po) == PositionOpen()
    call!(s, ai, t, po, PositionOpen())
end

@doc """Force exit a position.

$(TYPEDSIGNATURES)

This function cancels all orders associated with the specified position and updates the position with a forced order. The function also handles cases where the position is already closed or has zero committed funds.

"""
function force_exit_position(s::Strategy, ai, p, date::DateTime; kwargs...)
    @assert !hasorders(s, ai)
    @deassert isempty(collect(values(s, ai, p)))
    @deassert iszero(committed(ai, p)) committed(ai, p)
    ot = ReduceOnlyOrder(p)
    price = priceat(s, ot, ai, date)
    amount = abs(nondust(ai, ot, price))
    if amount > 0.0
        prevcash = s.cash.value
        t = call!(s, ai, ot; amount, date, price, kwargs...)
        @debug "force exit position: " amount price t.price s.cash.value - prevcash t.value
        @deassert let o = t.order
            (
                t isa Trade &&
                o.date == date &&
                isapprox(o.amount, amount; atol=ai.precision.amount)
            ) || isnothing(t)
        end
        # marketorder!(s, o, ai, o.amount; o.price, date, slippage)
        @deassert isdust(ai, price, p)
    end
end

"""
Closes a leveraged position.

$(TYPEDSIGNATURES)

When a date is given, this function closes pending orders and sells the remaining cash.
It then resets the position, deletes it from the holdings, and checks that the position is closed and no funds are committed.

"""
function close_position!(s::IsolatedStrategy, ai, p::PositionSide, date=nothing; kwargs...)
    @deassert !hasorders(s, ai, p)
    # when a date is given we should close pending orders and sell remaining cash
    if !isnothing(date)
        force_exit_position(s, ai, p, date; kwargs...)
    end
    reset!(ai, p)
    delete!(s.holdings, ai)
    @deassert !isopen(position(ai, p)) && iszero(ai)
    true
end

# TODO: Implement updating margin of open positions
# function update_margin!(pos::Position, qty::Real)
#     p = posside(pos)
#     price = entryprice(pos)
#     lev = leverage(pos)
#     size = notional(pos)
#     prev_additional = margin(pos) - size / lev
#     @deassert prev_additional >= 0.0 && qty >= 0.0
#     additional = prev_additional + qty
#     liqp = liqprice(p, price, lev, mmr(pos); additional, size)
#     liqprice!(pos, liqp)
#     # margin!(pos, )
# end

@doc """ Liquidates a position at a particular date.

$(TYPEDSIGNATURES)

`fees`: the fees for liquidating a position (usually higher than trading fees.)
`actual_price/amount`: the price/amount to execute the liquidation market order with (for paper mode).
"""
function liquidate!(
    s::MarginStrategy, ai::MarginInstance, p::PositionSide, date, fees=LIQUIDATION_FEES;
)
    pos = position(ai, p)
    ords = collect(values(s, ai, p))
    for o in ords
        @deassert o isa Order
        cancel!(s, o, ai; err=LiquidationOverride(o, liqprice(pos), date, p))
    end
    amount = abs(cash(pos).value)
    price = liqprice(pos)
    t = call!(s, ai, LiquidationOrder{liqside(p),typeof(p)}; amount, date, price, fees)
    isnothing(t) || begin
        @deassert t.order.date == date && 0.0 < abs(t.amount) <= abs(t.order.amount)
    end
    @deassert isdust(ai, price, p) (notional(ai, p), cash(ai, p), cash(ai, p) * price, p)
    close_position!(s, ai, p)
end

"""
Checks asset positions for liquidations and executes them (Non hedged mode, so only the currently open position).

$(TYPEDSIGNATURES)

If a position is open and liquidatable, it is liquidated using the `liquidate!` function.
The liquidation is performed on the asset positions in `ai` on the specified `date`.

"""
function maybe_liquidate!(s::IsolatedStrategy, ai::MarginInstance, date::DateTime)
    pos = position(ai)
    isnothing(pos) && return nothing
    @deassert !isopen(opposite(ai, pos))
    p = posside(pos)
    isliquidatable(s, ai, p, date) && liquidate!(s, ai, p, date)
end

@doc """Updates the position by applying a position trade.

$(TYPEDSIGNATURES)

Applies the position trade `t` to the isolated strategy `s` and the margin instance `ai`.
The order of calls is important.
Checks if the position has a notional value not equal to zero.
Updates the cash of the position using the trade construction.
"""
function update_position!(
    s::IsolatedStrategy, ai, t::PositionTrade{P}
) where {P<:PositionSide}
    # NOTE: Order of calls is important
    po = position(ai, P)
    @deassert notional(po) != 0.0
    # Cash should already be updated from trade construction
    withtrade!(po, t)
    # position is still open
    call!(s, ai, t, po, PositionUpdate())
end

@doc """ Updates or opens a position based on a given trade.

$(TYPEDSIGNATURES)

This function checks if a position is open. If it is, it either updates the position with the given trade or closes it if the position is dust.
If the position is not open, it opens a new position with the given trade.
After updating or opening the position, it checks if the position needs to be liquidated.

"""
function position!(
    s::IsolatedStrategy, ai::MarginInstance, t::PositionTrade{P}; check_liq=true
) where {P<:PositionSide}
    @deassert exchangeid(s) == exchangeid(t)
    @deassert t.order.asset == ai.asset
    pos = position(ai, P)
    if isopen(pos)
        if isdust(ai, t.price, P())
            close_position!(s, ai, P())
        else
            @deassert !iszero(cash(pos)) || t isa ReduceTrade
            @debug "position update" pos.entryprice[] t.value t.price
            update_position!(s, ai, t)
        end
    elseif t isa IncreaseTrade
        @debug "position open" cash(ai, t) t
        open_position!(s, ai, t)
    end
    if check_liq
        maybe_liquidate!(s, ai, t.date)
    end
end

@doc """ Updates an isolated position in `Sim` mode from a new candle.

$(TYPEDSIGNATURES)

This function checks if a position is open and updates the timestamp.
If the position is liquidatable, it is liquidated.
Otherwise, the position remains open and a `PositionUpdate` is pinged.

"""
function position!(s::IsolatedStrategy{Sim}, ai, date::DateTime, pos::Position=position(ai))
    # NOTE: Order of calls is important
    @deassert isopen(pos)
    p = posside(pos)
    @deassert notional(pos) != 0.0
    timestamp!(pos, date)
    if isliquidatable(s, ai, p, date)
        liquidate!(s, ai, p, date)
    else
        # position is still open
        call!(s, ai, date, pos, PositionUpdate())
    end
end

_checkorders(s) = begin
    for (_, ords) in s.buyorders
        for (_, o) in ords
            @assert abs(committed(o)) > 0.0
        end
    end
    for (_, ords) in s.sellorders
        for (_, o) in ords
            @assert abs(committed(o)) > 0.0
        end
    end
end

""" Updates all open positions in an isolated (non hedged) strategy for a specific date.

$(TYPEDSIGNATURES)

This function is used to update the state of all active asset holdings within the provided instance of `IsolatedStrategy` for a specified date.
Execution updates include the maintenance of position and order records and accounting for any change of asset state to reflect liquidations or trade updates.
"""
function positions!(s::IsolatedStrategy{<:Union{Paper,Sim}}, date::DateTime)
    @ifdebug _checkorders(s)
    for ai in s.holdings
        @deassert isopen(ai) || hasorders(s, ai) ai
        if isopen(ai)
            position!(s, ai, date)
        end
    end
    @ifdebug _checkorders(s)
    @ifdebug for ai in universe(s)
        @assert !(isopen(ai, Short()) && isopen(ai, Long()))
        po = position(ai)
        @assert if !isnothing(po)
            ai ∈ s.holdings && !iszero(cash(po)) && isopen(po)
        else
            iszero(cash(ai, Long())) &&
                iszero(cash(ai, Short())) &&
                !isopen(ai, Long()) &&
                !isopen(ai, Short())
        end
    end
end

positions!(args...; kwargs...) = nothing
