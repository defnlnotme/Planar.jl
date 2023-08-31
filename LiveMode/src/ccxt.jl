using .Lang: @ifdebug
using .Python: @pystr, @pyconst
using .OrderTypes
using .Misc: IsolatedMargin, CrossMargin, NoMargin
const ot = OrderTypes

pytostring(v) = pytruth(v) ? string(v) : ""
get_py(v::Py, k) = get(v, @pystr(k), pybuiltins.None)
get_py(v::Py, k, def) = get(v, @pystr(k), def)
get_py(v::Py, def, keys::Vararg{String}) = begin
    for k in keys
        ans = get_py(v, k)
        pyisnone(ans) || (return ans)
    end
    return def
end
get_string(v::Py, k) = get_py(v, k) |> pytostring
get_float(v::Py, k) = get_py(v, k) |> pytofloat
get_bool(v::Py, k) = get_py(v, k) |> pytruth

_option_float(o::Py, k) =
    let v = get_py(o, k)
        if pyisinstance(v, pybuiltins.float)
            pytofloat(v)
        end
    end

function get_float(resp::Py, k, def, args...; ai)
    v = _option_float(resp, k)
    if isnothing(v)
        def
    else
        isapprox(ai, v, def, args...) || begin
            @warn "Exchange order $k not matching request $def (local),  $v ($(nameof(exchange(ai))))"
        end
        v
    end
end

islist(v) = pyisinstance(v, pybuiltins.list)
isdict(v) = pyisinstance(v, pybuiltins.dict)

get_timestamp(py, keys=("lastUpdateTimestamp", "timestamp")) =
    for k in keys
        v = get_py(py, k)
        pyisnone(v) || return v
    end

_tryasdate(py) = tryparse(DateTime, rstrip(string(py), 'Z'))
pytodate(py::Py) = pytodate(py, "lastUpdateTimestamp", "timestamp")
function pytodate(py::Py, keys...)
    let v = get_timestamp(py, keys)
        if pyisinstance(v, pybuiltins.str)
            _tryasdate(v)
        elseif pyisinstance(v, pybuiltins.int)
            pyconvert(Int, v) |> dt
        elseif pyisinstance(v, pybuiltins.float)
            pyconvert(DFT, v) |> dt
        end
    end
end
pytodate(py::Py, ::EIDType, args...; kwargs...) = pytodate(py, args...; kwargs...)
get_time(v::Py, keys...) = @something pytodate(v, keys...) now()

_pystrsym(v::String) = @pystr(uppercase(v))
_pystrsym(v::Symbol) = @pystr(uppercase(string(v)))
_pystrsym(ai::AssetInstance) = @pystr(ai.bc)

_ccxtordertype(::LimitOrder) = @pyconst "limit"
_ccxtordertype(::MarketOrder) = @pyconst "market"
_ccxtorderside(::Type{Buy}) = @pyconst "buy"
_ccxtorderside(::Type{Sell}) = @pyconst "sell"
_ccxtorderside(::Union{AnyBuyOrder,Type{<:AnyBuyOrder}}) = @pyconst "buy"
_ccxtorderside(::Union{AnySellOrder,Type{<:AnySellOrder}}) = @pyconst "sell"
_ccxtmarginmode(::IsolatedMargin) = @pyconst "isolated"
_ccxtmarginmode(::NoMargin) = pybuiltins.None
_ccxtmarginmode(::CrossMargin) = @pyconst "cross"
_ccxtmarginmode(v) = marginmode(v) |> _ccxtmarginmode

ordertype_fromccxt(resp, eid::EIDType) =
    let v = resp_order_type(resp, eid)
        if pyeq(Bool, v, @pyconst "market")
            MarketOrderType
        elseif pyeq(Bool, v, @pyconst "limit")
            ordertype_fromtif(resp, eid)
        end
    end

function _ccxttif(exc, type)
    if type <: AnyPostOnlyOrder
        @assert has(exc, :createPostOnlyOrder) "Exchange $(nameof(exc)) doesn't support post only orders."
        "PO"
    elseif type <: AnyGTCOrder
        "GTC"
    elseif type <: AnyFOKOrder
        "FOK"
    elseif type <: AnyIOCOrder
        "IOC"
    elseif type <: AnyMarketOrder
        ""
    else
        @warn "Unable to choose time-in-force setting for order type $type (defaulting to GTC)."
        "GTC"
    end
end

ordertype_fromtif(o::Py, eid::EIDType) =
    let tif = resp_order_tif(o, eid)
        if pyeq(Bool, tif, @pyconst("PO"))
            ot.PostOnlyOrderType
        elseif pyeq(Bool, tif, @pyconst("GTC"))
            ot.GTCOrderType
        elseif pyeq(Bool, tif, @pyconst("FOK"))
            ot.FOKOrderType
        elseif pyeq(Bool, tif, @pyconst("IOC"))
            ot.IOCOrderType
        end
    end

_orderside(o::Py, eid) =
    let v = resp_order_side(o, eid)
        if pyeq(Bool, v, @pyconst("buy"))
            Buy
        elseif pyeq(Bool, v, @pyconst("sell"))
            Sell
        end
    end

_orderid(o::Py, eid::EIDType) =
    let v = resp_order_id(o, eid)
        if pyisinstance(v, pybuiltins.str)
            return string(v)
        else
            v = resp_order_clientid(o, eid)
            if pyisinstance(v, pybuiltins.str)
                return string(v)
            end
        end
    end

function _checkordertype(exc, sym)
    @assert has(exc, sym) "Exchange $(nameof(exc)) doesn't support $sym orders."
end

function _ccxtordertype(exc, type)
    @pystr if type <: AnyLimitOrder
        _checkordertype(exc, :createLimitOrder)
        "limit"
    elseif type <: AnyMarketOrder
        _checkordertype(exc, :createMarketOrder)
        "market"
    else
        error("Order type $type is not valid.")
    end
end

time_in_force_value(::Exchange, v) = v
time_in_force_key(::Exchange) = "timeInForce"

function _ccxtisfilled(resp::Py, ::EIDType)
    get_float(resp, "filled") == get_float(resp, "amount") &&
        iszero(get_float(resp, "remaining"))
end

function isorder_synced(o, ai, resp::Py, eid::EIDType=exchangeid(ai))
    isapprox(ai, filled_amount(o), resp_order_filled(resp, eid), Val(:amount)) ||
        let ntrades = length(resp_order_trades(resp, eid))
            ntrades > 0 && ntrades == length(trades(o))
        end
end

function _ccxt_sidetype(resp, o, eid::EIDType; getter=resp_trade_side)::Type{<:OrderSide}
    side = getter(resp, eid)
    if pyeq(Bool, side, @pyconst("buy"))
        Buy
    elseif pyeq(Bool, side, @pyconst("sell"))
        Sell
    else
        orderside(o)
    end
end

_ccxtisstatus(status::String, what) = pyeq(Bool, @pystr(status), @pystr(what))
_ccxtisstatus(resp, statuses::Vararg{String}) = any(x -> _ccxtisstatus(resp, x), statuses)
function _ccxtisstatus(resp, status::String, eid::EIDType)
    pyeq(Bool, resp_order_status(resp, eid), @pystr(status))
end
_ccxtisopen(resp, eid::EIDType) = pyeq(Bool, resp_order_status(resp, eid), @pyconst("open"))
function _ccxtisclosed(resp, eid::EIDType)
    pyeq(Bool, resp_order_status(resp, eid), @pyconst("closed"))
end

resp_trade_cost(resp, ::EIDType)::DFT = get_float(resp, "cost")
resp_trade_amount(resp, ::EIDType)::DFT = get_float(resp, Trf.amount)
resp_trade_amount(resp, ::EIDType, ::Type{Py}) = get_py(resp, Trf.amount)
resp_trade_price(resp, ::EIDType)::DFT = get_float(resp, Trf.price)
resp_trade_price(resp, ::EIDType, ::Type{Py}) = get_py(resp, Trf.price)
resp_trade_timestamp(resp, ::EIDType) = get_py(resp, Trf.timestamp, @pyconst(0))
resp_trade_symbol(resp, ::EIDType) = get_py(resp, Trf.symbol, @pyconst(""))
resp_trade_id(resp, ::EIDType) = get_py(resp, Trf.id, @pyconst(""))
resp_trade_side(resp, ::EIDType) = get_py(resp, Trf.side)
resp_trade_fee(resp, ::EIDType) = get_py(resp, Trf.fee)
resp_trade_fees(resp, ::EIDType) = get_py(resp, Trf.fees)
resp_trade_order(resp, ::EIDType) = get_py(resp, Trf.order)
resp_trade_order(resp, ::EIDType, ::Type{String}) = get_py(resp, Trf.order) |> pytostring
resp_trade_type(resp, ::EIDType) = get_py(resp, Trf.type)
resp_trade_tom(resp, ::EIDType) = get_py(resp, Trf.takerOrMaker)
resp_trade_info(resp, ::EIDType) = get_py(resp, "info")

resp_order_remaining(resp, ::EIDType)::DFT = get_float(resp, "remaining")
resp_order_remaining(resp, ::EIDType, ::Type{Py}) = get_py(resp, "remaining")
resp_order_filled(resp, ::EIDType)::DFT = get_float(resp, "filled")
resp_order_filled(resp, ::EIDType, ::Type{Py}) = get_py(resp, "filled")
resp_order_cost(resp, ::EIDType)::DFT = get_float(resp, "cost")
resp_order_cost(resp, ::EIDType, ::Type{Py}) = get_py(resp, "cost")
resp_order_average(resp, ::EIDType)::DFT = get_float(resp, "average_price")
resp_order_average(resp, ::EIDType, ::Type{Py}) = get_py(resp, "average_price")
resp_order_price(resp, ::EIDType, ::Type{Py}) = get_py(resp, "price")
function resp_order_price(resp, ::EIDType, args...; kwargs...)::DFT
    get_float(resp, "price", args...; kwargs...)
end
resp_order_amount(resp, ::EIDType, ::Type{Py}) = get_py(resp, "amount")
function resp_order_amount(resp, ::EIDType, args...; kwargs...)::DFT
    get_float(resp, "amount", args...; kwargs...)
end
resp_order_trades(resp, ::EIDType) = get_py(resp, "trades", ())
resp_order_type(resp, ::EIDType) = get_py(resp, "type")
resp_order_tif(resp, ::EIDType) = get_py(resp, "timeInForce")
resp_order_lastupdate(resp, ::EIDType) = get_py(resp, "lastUpdateTimestamp")
resp_order_timestamp(resp, ::EIDType) = pytodate(resp)
resp_order_timestamp(resp, ::EIDType, ::Type{Py}) = get_py(resp, "timestamp")
resp_order_side(resp, ::EIDType) = get_py(resp, "side")
resp_order_id(resp, ::EIDType) = get_py(resp, "id")
resp_order_id(resp, eid::EIDType, ::Type{String})::String =
    resp_order_id(resp, eid) |> pytostring
resp_order_clientid(resp, ::EIDType) = get_py(resp, "clientOrderId")
resp_order_symbol(resp, ::EIDType) = get_py(resp, "symbol", @pyconst(""))
resp_order_side(resp, ::EIDType) = get_py(resp, Trf.side)
resp_order_status(resp, ::EIDType) = get_py(resp, "status")
function resp_order_status(resp, eid::EIDType, ::Type{String})
    resp_order_status(resp, eid) |> pytostring
end
resp_order_loss_price(resp, ::EIDType)::Option{DFT} = _option_float(resp, "stopLossPrice")
resp_order_profit_price(resp, ::EIDType)::Option{DFT} =
    _option_float(resp, "takeProfitPrice")
resp_order_stop_price(resp, ::EIDType)::Option{DFT} = _option_float(resp, "stopPrice")
resp_order_trigger_price(resp, ::EIDType)::Option{DFT} = _option_float(resp, "triggerPrice")
resp_order_info(resp, ::EIDType)::Option{DFT} = get_py(resp, "info")

resp_position_side(resp, ::EIDType) = get_py(resp, Pos.side)
resp_position_symbol(resp, ::EIDType) = get_py(resp, Pos.symbol)
function resp_position_symbol(resp, ::EIDType, ::Type{String})
    get_py(resp, Pos.symbol) |> pytostring
end
resp_position_contracts(resp, ::EIDType)::DFT = get_float(resp, Pos.contracts)
resp_position_entryprice(resp, ::EIDType)::DFT = get_float(resp, Pos.entryPrice)
resp_position_mmr(resp, ::EIDType)::DFT = get_float(resp, "maintenanceMarginPercentage")
resp_position_side(resp, ::EIDType) = get_py(resp, Pos.side, @pyconst("")).lower()
resp_position_unpnl(resp, ::EIDType)::DFT = get_float(resp, Pos.unrealizedPnl)
resp_position_leverage(resp, ::EIDType)::DFT = get_float(resp, Pos.leverage)
resp_position_liqprice(resp, ::EIDType)::DFT = get_float(resp, Pos.liquidationPrice)
resp_position_initial_margin(resp, ::EIDType)::DFT = get_float(resp, Pos.initialMargin)
resp_position_maintenance_margin(resp, ::EIDType)::DFT =
    get_float(resp, Pos.maintenanceMargin)
resp_position_collateral(resp, ::EIDType)::DFT = get_float(resp, Pos.collateral)
resp_position_notional(resp, ::EIDType)::DFT = get_float(resp, Pos.notional)
resp_position_lastprice(resp, ::EIDType)::DFT = get_float(resp, Pos.lastPrice)
resp_position_markprice(resp, ::EIDType)::DFT = get_float(resp, Pos.markPrice)
resp_position_hedged(resp, ::EIDType)::Bool = get_bool(resp, Pos.hedged)
resp_position_timestamp(resp, ::EIDType)::DateTime = get_time(resp)
resp_position_margin_mode(resp, ::EIDType) = get_py(resp, Pos.marginMode)

resp_code(resp, ::EIDType) = get_py(resp, "code")

function positions_func(exc::Exchange, ais, args...; kwargs...)
    pyfetch(first(exc, :fetchPositionsWs, :fetchPositions), _syms(ais), args...; kwargs...)
end
