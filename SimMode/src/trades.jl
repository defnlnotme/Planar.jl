using Base: negate
using Executors: @amount!, @price!, NewTrade, trade!
using Executors.Checks: cost, withfees, checkprice
using Executors.Instances
using Executors.Instruments
using Executors.Instances: NoMarginInstance, Instances as inst, price
using .Strategies: lowat, highat, closeat, openat, volumeat
using .Strategies: IsolatedStrategy, NoMarginStrategy
using .OrderTypes: BuyOrder, SellOrder, ShortBuyOrder, ShortSellOrder
using .OrderTypes: OrderTypes as ot, PositionSide
import .Strategies: call!
import Executors: maketrade

include("slippage.jl")

@doc """ Check if there is enough cash in the strategy currency for buying.

$(TYPEDSIGNATURES)

This function checks if the free cash in the strategy plus the committed amount is greater than or equal to the size of the buy order.

"""
function iscashenough(s::NoMarginStrategy, _, size, o::BuyOrder)
    @deassert committed(o) |> gtxzero
    st.freecash(s) + committed(o) >= size
end
@doc """ Check that we have enough asset holdings that we want to sell.

$(TYPEDSIGNATURES)

This function checks if the free cash in the asset plus the committed amount is greater than or equal to the actual amount of the sell order.

"""
function iscashenough(_::Strategy, ai, actual_amount, o::SellOrder)
    @deassert cash(ai, Long()) |> gtxzero
    @deassert committed(o) |> gtxzero
    inst.freecash(ai, Long()) + committed(o) >= actual_amount
end
@doc """ Checks if there is sufficient cash for a long buy order.

$(TYPEDSIGNATURES)

This function verifies if the free cash in the strategy, combined with the committed amount, is sufficient to cover the size of the buy trade when multiplied by the leverage.

"""
function iscashenough(s::IsolatedStrategy, ai, size, o::BuyOrder)
    @deassert s.cash |> gtxzero
    @deassert committed(o) |> gtxzero
    (st.freecash(s) + committed(o)) * leverage(ai, Long()) >= size
end
@doc """ Checks if there is sufficient QC for a short sell trade.

$(TYPEDSIGNATURES)

In a short sell trade, our position increases in the opposite direction.
This function checks if there is enough QC (Quote Currency) to cover the short sell trade.
It does this by verifying if the free cash in the strategy, combined with the committed amount, is sufficient to cover the size of the short sell trade when multiplied by the leverage.

"""
function iscashenough(s::IsolatedStrategy, ai, size, o::ShortSellOrder)
    @deassert s.cash |> gtxzero
    @deassert committed(o) |> gtxzero
    (st.freecash(s) + committed(o)) * leverage(ai, Short()) >= size
end
@doc """ A short buy reduces the required capital by the leverage. But we shouldn't buy back more than what we have shorted.

$(TYPEDSIGNATURES)

"""
function iscashenough(s::IsolatedStrategy, ai, actual_amount, o::ShortBuyOrder)
    @deassert cash(ai, Short()) |> ltxzero
    @deassert committed(o) |> ltxzero
    @deassert inst.freecash(ai, Short()) |> ltxzero
    abs(inst.freecash(ai, Short())) + abs(committed(o)) >= actual_amount
end

@doc """ Constructs a Trade object with the given parameters.

$(TYPEDSIGNATURES)

This macro generates a Trade object with the given order, date, actual amount, actual price, fees, size, leverage, and entry price.
The actual price and actual amount are the price and amount of the trade after considering slippage and fees.
The size is the total cost of the trade including fees.
The leverage is the leverage of the asset instance for the order.
The entry price is the price of the asset instance after the trade.

"""
macro maketrade()
    expr = quote
        Trade(
            o;
            date,
            amount=actual_amount,
            price=actual_price,
            fees=fees_quote,
            fees_base,
            size,
            lev=leverage(ai, o),
            entryprice=price(ai, actual_price, o),
        )
    end
    esc(expr)
end

@doc """ Constructs a Trade object with the given parameters.

$(TYPEDSIGNATURES)

This macro generates a Trade object with the given order, date, actual amount, actual price, fees, size, leverage, and entry price.
The actual price and actual amount are the price and amount of the trade after considering slippage and fees.
The size is the total cost of the trade including fees.
The leverage is the leverage of the asset instance for the order.
The entry price is the price of the asset instance after the trade.

"""
function maketrade(
    s::Strategy{<:Union{Sim,Paper}},
    o::IncreaseOrder,
    ai;
    date,
    actual_price,
    actual_amount,
    fees,
)
    net_cost = cost(actual_price, actual_amount)
    size = withfees(net_cost, fees, o)
    iscashenough(s, ai, size, o) || return nothing
    @deassert size > 0.0 && net_cost > 0.0
    fees_quote = size - net_cost
    fees_base = 0.0
    @deassert fees_quote > 0.0 || fees < 0.0
    @maketrade
end

@doc """ Creates a trade with given parameters and checks if there is enough cash for the trade.

$(TYPEDSIGNATURES)

This function calculates the net cost of the trade and checks if there is enough cash for the trade using the `iscashenough` function.
If there is not enough cash, it returns nothing.
Otherwise, it calculates the fees and creates a trade using the `@maketrade` macro.

"""
function maketrade(
    s::Strategy{<:Union{Sim,Paper}},
    o::ReduceOrder,
    ai;
    date,
    actual_price,
    actual_amount,
    fees,
)
    @deassert actual_amount >= 0
    iscashenough(s, ai, actual_amount, o) || return nothing
    net_cost = cost(actual_price, actual_amount)
    size = withfees(net_cost, fees, o)
    @deassert size > 0.0 && net_cost > 0.0
    fees_quote = net_cost - size
    fees_base = 0.0
    @deassert fees_quote > 0.0 || fees < 0.0
    @maketrade
end

@doc """ Fees override for simulation mode (taker).  """
simfeestaker(s::Strategy, ai) = @coalesce get(s, :sim_fees_taker, missing) maxfees(ai)
@doc """ Fees override for simulation mode (maker).  """
simfeesmaker(s::Strategy, ai) = @coalesce get(s, :sim_fees_maker, missing) minfees(ai)
