using Planar.Engine.Lang: @ifdebug, safewait, safenotify
using Planar.Engine.LiveMode.Watchers.WatchersImpls:
    ccxt_ohlcv_tickers_watcher, start!, load!, isstopped

__revise_mode__ = :eval
const CACHE = Dict{Symbol,Any}()
const THREADSAFE = Ref(true)
const SANDBOX = Ref(true)
const TradeResult = Union{Missing,Nothing,<:Trade,<:OrderError}

_timeframe(s) = attr(s, :timeframe, tf"1m")
ind_timeframe(s) = attr(s, :ind_timeframe, tf"1m")
_reset!(s) = begin
    attrs = s.attrs
    attrs[:buydiff] = 1.01
    attrs[:selldiff] = 1.005
    attrs[:ordertype] = :fok
    attrs[:verbose] = false
    attrs[:this_close] = nothing
    attrs[:prev_close] = nothing
    attrs[:timeframe] = s.timeframe
    attrs[:params_index] = Dict{Symbol,Int}()
    delete!(attrs, :this_close)
    delete!(attrs, :prev_close)
    attrs[:sim_indicators_set] = false
    if :tickers_watcher in keys(attrs)
        close(attrs[:tickers_watcher])
    end
    s
end

function _tickers_watcher(s; view_capacity=1000, k=:tickers_watcher, tf=_timeframe(s))
    if s isa Union{PaperStrategy,LiveStrategy}
        exc = getexchange!(exchangeid(s); sandbox=false)
        w = ccxt_ohlcv_tickers_watcher(
            exc;
            timeframe=tf,
            syms=marketsid(s),
            flush=false,
            logfile=st.logpath(s; name=string(k)),
            view_capacity,
        )
        w.attrs[:quiet] = true
        w.attrs[:resync_noncontig] = true
        wv = w.view
        for ai in s.universe
            wv[ai.asset.raw] = ai.ohlcv
        end
        w[:process_func] = () -> begin
            while isstarted(w)
                for ai in s.universe
                    try
                        propagate_ohlcv!(ai.data)
                    catch
                    end
                end
                safewait(w.beacon.process)
            end
            @warn "propagate loop stopped"
        end
        w[:quiet] = true
        @async begin
            try
                @sync for sym in marketsid(s)
                    @async load!(w, sym)
                end
            catch
            end
            start!(w)
            w[:process_task] = @async w[:process_func]()
        end
        s[k] = w
    end
end

_overrides!(s) = begin
    attrs = s.attrs
    for (k, v) in pairs(get(attrs, :overrides, ()))
        attrs[k] = v
    end
    s
end

getparam(s, params, sym) = params[s[:params_index][sym]]

_thisclose(s) = s.attrs[:this_close]::Option{Float64}
_prevclose(s) = s.attrs[:prev_close]::Option{Float64}
_thisclose!(s, v) = s.attrs[:this_close] = v
_prevclose!(s, v) = s.attrs[:prev_close] = v

function select_ordertype(
    s::SC, os::Type{<:OrderSide}, p::PositionSide=Long(); t=s.ordertype
)
    if p == Long()
        if t == :market
            MarketOrder{os}, t
        elseif t == :ioc
            IOCOrder{os}, t
        elseif t == :fok
            FOKOrder{os}, t
        elseif t == :gtc
            GTCOrder{os}, t
        else
            error("Wrong order type $t")
        end
    else
        if t == :market
            ShortMarketOrder{os}, t
        elseif t == :ioc
            ShortIOCOrder{os}, t
        elseif t == :fok
            ShortFOKOrder{os}, t
        elseif t == :gtc
            ShortGTCOrder{os}, t
        else
            error("Wrong order type $t")
        end
    end
end

function select_orderkwargs(otsym::Symbol, ::Type{Buy}, ai, ats)
    if otsym == :gtc
        (; price=1.02 * closeat(ohlcv(ai), ats))
    else
        ()
    end
end

function select_orderkwargs(otsym::Symbol, ::Type{Sell}, ai, ats)
    if otsym == :gtc
        (; price=0.99 * closeat(ohlcv(ai), ats))
    else
        ()
    end
end

function closepair(s, ai, ats, tf=_timeframe(s))
    data = ai.data[tf]
    prev_date = ats - tf
    if data.timestamp[begin] > prev_date
        _thisclose!(s, nothing)
        return nothing
    end
    _thisclose!(s, closeat(data, ats))
    _prevclose!(s, closeat(data, prev_date))
    nothing
end
