errors(w::Watcher) = w._exec.errors
@doc "Stores an error to the watcher log journal."
function logerror(w::Watcher, e, bt=[])
    if haskey(w.attrs, :logfile)
        file = w.attrs[:logfile]
        open(file, "a") do f
            Base.showerror(f, e)
            isempty(bt) || Base.show_backtrace(f, bt)
        end
    else
        push!(w._exec.errors, (e, bt))
    end
    e
end
@doc "Get the last logged watcher error."
lasterror(w::Watcher) = isempty(w._exec.errors) ? nothing : last(w._exec.errors)
@doc "Get the last logged watcher error of type `t`."
lasterror(t::Type, w::Watcher) = findlast(e -> e isa t, w._exec.errors)
@doc "Get all logged watcher errors of type `t`."
allerror(t::Type, w::Watcher) = filter(e -> e[1] isa t, w._exec.errors)
function showtrace(w::Watcher, rev_idx=0)
    if !isempty(w._exec.errors)
        e = errors(w)[end - rev_idx]
        Base.show_backtrace(stderr, e[2])
        println("\n")
        Base.showerror(stderr, e[1])
    end
end
macro logerror(w, expr)
    quote
        try
            $(esc(expr))
        catch e
            logerror($(esc(w)), e, stacktrace(catch_backtrace()))
        end
    end
end

export logerror, @logerror
