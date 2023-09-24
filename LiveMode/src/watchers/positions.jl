using Watchers
using Watchers: default_init
using Watchers.WatchersImpls: _tfunc!, _tfunc, _exc!, _exc, _lastfetched!, _lastfetched
@watcher_interface!
using .Exchanges: check_timeout
using .Lang: splitkws, safenotify, safewait

const CcxtPositionsVal = Val{:ccxt_positions}
# :read, if true, the value of :pos has already be locally synced
# :closed, if true, the value of :pos should be considered stale, and the position should be closed (contracts == 0)
const PositionUpdate7 = NamedTuple{
    (:date, :notify, :read, :closed, :resp),
    Tuple{DateTime,Base.Threads.Condition,Ref{Bool},Ref{Bool},Py},
}
const PositionsDict2 = Dict{String,PositionUpdate7}

function guess_settle(s::MarginStrategy)
    try
        first(s.universe).asset.sc |> string |> uppercase
    catch
        ""
    end
end

_dopush!(w, v; if_func=islist) =
    if if_func(v)
        pushnew!(w, v)
        _lastfetched!(w, now())
    end

function split_params(kwargs)
    (split, rest) = splitkws(:params; kwargs)
    tup = tuple(split...)
    # (params, reset)
    isempty(tup) ? LittleDict{Py,Any}() : tup[1][2], rest
end

function _w_fetch_positions_func(s, interval; kwargs)
    exc = exchange(s)
    params, rest = split_params(kwargs)
    @lget! params @pyconst("settle") guess_settle(s)
    if has(exc, :watchPositions)
        f = exc.watchPositions
        (w) -> try
            v = _execfunc(f; params, rest...)
            _dopush!(w, v)
        catch
        end
    else
        (w) -> try
            @lock w begin
                v = fetch_positions(s, (); params, rest...)
                _dopush!(w, v)
            end
            sleep(interval)
        catch
            sleep(interval)
        end
    end
end

function ccxt_positions_watcher(
    s::Strategy;
    interval=Second(5),
    wid="ccxt_positions",
    buffer_capacity=10,
    start=true,
    kwargs...,
)
    exc = st.exchange(s)
    check_timeout(exc, interval)
    attrs = Dict{Symbol,Any}()
    _tfunc!(attrs, _w_fetch_positions_func(s, interval; kwargs))
    _exc!(attrs, exc)
    watcher_type = Py
    wid = string(wid, "-", hash((exc.id, nameof(s))))
    watcher(
        watcher_type,
        wid,
        CcxtPositionsVal();
        start,
        load=false,
        flush=false,
        process=true,
        buffer_capacity,
        view_capacity=1,
        fetch_interval=interval,
        attrs,
    )
end

function watch_positions!(s::LiveStrategy; interval=st.throttle(s))
    w = @lget! attrs(s) :live_positions_watcher ccxt_positions_watcher(
        s; interval, start=true
    )
    isstopped(w) && start!(w)
    w
end

_position_task!(w) = begin
    f = _tfunc(w)
    @async while isstarted(w)
        f(w)
    end
end

_position_task(w) = @lget! attrs(w) :position_task _position_task!(w)

function Watchers._fetch!(w::Watcher, ::CcxtPositionsVal)
    task = _position_task(w)
    if !istaskstarted(task) || istaskdone(task)
        _position_task!(w)
    end
    return true
end

function Watchers._init!(w::Watcher, ::CcxtPositionsVal)
    default_init(w, (; long=PositionsDict2(), short=PositionsDict2()), false)
    _lastfetched!(w, DateTime(0))
end

# TODO: Maybe call live_sync_position! directly here?

function _posupdate(date, resp)
    PositionUpdate7((;
        date, notify=Base.Threads.Condition(), read=Ref(false), closed=Ref(false), resp
    ))
end
function _posupdate(prev, date, resp)
    PositionUpdate7((; date, prev.notify, prev.read, prev.closed, resp))
end
_deletek(py, k=@pyconst("info")) = haskey(py, k) && py.pop(k)
function Watchers._process!(w::Watcher, ::CcxtPositionsVal; sym=nothing)
    isempty(w.buffer) && return nothing
    data_date, data = last(w.buffer)
    long_dict = w.view.long
    short_dict = w.view.short
    islist(data) || return nothing
    eid = typeof(exchangeid(_exc(w)))
    processed_syms = Set{Tuple{String,PositionSide}}()
    for resp in data
        isdict(resp) || continue
        sym = resp_position_symbol(resp, eid, String)
        side = posside_fromccxt(resp, eid)
        side_dict = ifelse(islong(side), long_dict, short_dict)
        pup_prev = get(side_dict, sym, nothing)
        date = let this_date = @something pytodate(resp, eid) data_date
            prev_date = isnothing(pup_prev) ? DateTime(0) : pup_prev.date
            if this_date == prev_date
                data_date
            else
                this_date
            end
        end
        pup = if isnothing(pup_prev)
            _posupdate(date, resp)
        elseif pup_prev.date < date
            _posupdate(pup_prev, date, resp)
        end
        push!(processed_syms, (sym, side))
        isnothing(pup) || (side_dict[sym] = pup)
    end
    # do notify if we added at least one response, or removed at least one
    skip_notify = all(isempty(x for x in (processed_syms, long_dict, short_dict)))
    _setposflags!(data_date, long_dict, Long(), processed_syms; sym, eid)
    _setposflags!(data_date, short_dict, Short(), processed_syms; sym, eid)
    skip_notify || safenotify(w.beacon.process)
end

function _setposflags!(data_date, dict, side, processed_syms; sym, eid)
    if isnothing(sym)
        for (sym, pup) in dict
            if (pup.closed[] = (sym, side) ∉ processed_syms)
                pup_prev = get(dict, sym, nothing)
                @deassert pup_prev === pup
                dict[sym] = _posupdate(pup_prev, data_date, pup_prev.resp)
            end
            pup.read[] = false
            safenotify(pup.notify)
        end
    else
        pup = get(dict, sym, nothing)
        if pup isa PositionUpdate7
            pup.read[] = false
            pup.closed[] = iszero(resp_position_contracts(pup.resp, eid))
            safenotify(pup.notify)
        end
    end
end

function _setunread!(w)
    data = w.view
    map(v -> (v.read[] = false), values(data.long))
    map(v -> (v.read[] = false), values(data.short))
end

positions_watcher(s) = s[:live_positions_watcher]

# function _load!(w::Watcher, ::ThisVal) end

# function _process!(w::Watcher, ::ThisVal) end

# function _start!(w::Watcher, ::ThisVal) end

# function _stop!(w::Watcher, ::ThisVal) end
