@doc """ Places a limit order and waits for its completion.

$(TYPEDSIGNATURES)

This function creates a live limit order and then waits for it to either be filled or canceled, depending on the waiting time provided.
It handles immediate orders differently, in such cases it waits for the order to be closed.
If an order fails or is canceled, the function returns the relevant status.

"""
function _live_limit_order(s::LiveStrategy, ai, t; skipchecks=false, amount, price, waitfor, synced, kwargs)
    local o, order_trades
    @debug "call limit order: locking" _module = LogCreateOrder isownable(ai.lock) isownable(s.lock)
    # NOTE: necessary locks to prevent race conditions between balance/positions updates
    # and order creation
    order_trades = begin
        o = create_live_order(s, ai; skipchecks, t, amount, price, exc_kwargs=kwargs)
        if !(o isa Order)
            return nothing
        end
        trades(o)
    end
    @debug "call limit order: waiting" _module = LogCreateOrder waitfor isimmediate(o)
    @timeout_start
    # TODO: streamline this logic better
    # if immediate should wait for the order to be closed
    if isimmediate(o)
        if waitorder(s, ai, o; waitfor=@timeout_now) && !isempty(order_trades)
            last(order_trades)
        elseif !haskey(s, ai, o)
            @debug "call limit order: order failed (immediate)" _module = LogCreateOrder o.id
            nothing
        elseif waittrade(s, ai, o; waitfor=@timeout_now, force=synced)
            last(order_trades)
        elseif haskey(s, ai, o)
            if synced
                live_sync_open_orders!(s, ai, side=orderside(o), exec=true)
                if !isempty(order_trades)
                    last(order_trades)
                elseif haskey(s, ai, o)
                    @debug "call limit order: no trades yet (immediate,synced)" _module = LogCreateOrder o.id
                    missing
                end
            else
                @debug "call limit order: no trades yet (immediate)" _module = LogCreateOrder o.id
                missing
            end
        else
            @debug "call limit order: order failed (immediate)" _module = LogCreateOrder o.id
        end
    elseif !isempty(order_trades)
        last(order_trades)
        # otherwise wait a little in case the there is already a fill for the gtc order
    elseif waittrade(s, ai, o; waitfor=@timeout_now, force=synced)
        last(order_trades)
    elseif haskey(s, ai, o)
        if synced
            live_sync_open_orders!(s, ai, side=orderside(o), exec=true)
            if !isempty(order_trades)
                last(order_trades)
            elseif haskey(s, ai, o)
                @debug "call limit order: no trades yet (synced)" _module = LogCreateOrder synced
                missing
            end
        else
            @debug "call limit order: no trades yet" _module = LogCreateOrder synced
            missing
        end
    else
        @debug "call limit order: canceled or failed" _module = LogCreateOrder
    end
end
