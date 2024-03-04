using PythonCall:
    Py, pynew, pydict, pyimport, pyexec, pycopy!, pyisnull, pybuiltins, pyconvert, pyisTrue
using Dates: Period, Second
using Lang: safenotify, safewait
using Mocking: @mock, Mocking

@doc """ Checks if python async state (event loop) is initialized.

$(TYPEDSIGNATURES)
"""
function isinitialized_async(pa::PythonAsync)
    !pyisnull(pa.pyaio)
end

@doc """ Copies a python async structures.

$(TYPEDSIGNATURES)
"""
function Base.copyto!(pa_to::PythonAsync, pa_from::PythonAsync)
    if pyisnull(pa_to.pyaio) && !pyisnull(pa_from.pyaio)
        for f in fieldnames(PythonAsync)
            let v = getfield(pa_from, f)
                if v isa Py
                    pycopy!(getfield(pa_to, f), v)
                elseif f == :task
                    isassigned(v) && (pa_to.task[] = v[])
                elseif f == :task_running
                    continue
                else
                    error()
                end
            end
        end
        true
    else
        false
    end
end

@doc """ Initialized a PythonAsync structure (which holds a reference to the event loop.)

$(TYPEDSIGNATURES)
"""
function _async_init(pa::PythonAsync)
    isinitialized_async(pa) && return nothing
    copyto!(pa, gpa) && return nothing
    if pyisnull(pa.pyaio)
        PYREF[] = pa
        pycopy!(pa.pyaio, pyimport("asyncio"))
        pycopy!(pa.pythreads, pyimport("threading"))
        async_start_runner_func!(pa)
        py_start_loop(pa)
        copyto!(gpa, pa)
    end
    @assert !pyisnull(gpa.pyaio)
end

@doc """ Starts a python event loop, updating `pa`.

$(TYPEDSIGNATURES)
"""
function py_start_loop(pa::PythonAsync=gpa)
    if pa === gpa
        PYREF[] = gpa
    end
    pyaio = pa.pyaio
    pyloop = pa.pyloop
    pycoro_type = pa.pycoro_type

    @assert !pyisnull(pyaio)
    @assert pyisnull(pyloop) || !Bool(pyloop.is_running())
    if isassigned(pa.task) && !istaskdone(pa.task[])
        gpa.task_running[] = false
        try
            wait(pa.task[])
        catch
        end
    end

    pyisnull(pycoro_type) && pycopy!(pycoro_type, pyimport("types").CoroutineType)
    start_task() = pa.task[] = @async while true
        try
            gpa.task_running[] = true
            pyisnull(pa.start_func) || pa.start_func(Python)
        catch e
            @debug e
        finally
            gpa.task_running[] = false
            pyisnull(pyloop) || pyloop.stop()
        end
        sleep(1)
    end

    start_task()
    sleep(0)
    sleep_t = 0.0
    while pyisnull(pyloop) || !Bool(pyloop.is_running())
        @info "waiting for python event loop to start"
        sleep(0.1)
        sleep_t += 0.1
        if sleep_t > 3.0
            start_task()
            sleep_t = 0.0
        end
    end

    atexit(pyloop_stop_fn())
end

function py_stop_loop(pa::PythonAsync=gpa)
    pa.task_running[] = false
    try
        wait(pa.task[])
    catch
    end
end

@doc """ Generates a function that terminates the python even loop.

$(TYPEDSIGNATURES)
"""
function pyloop_stop_fn()
    fn() = begin
        !isassigned(gpa.task) || istaskdone(gpa.task[]) && return nothing
        gpa.task_running[] = false
        pyisnull(gpa.pyloop) || py_stop_loop(gpa)
    end
    fn
end

# FIXME: This doesn't work if we pass =args...; kwargs...=
macro pytask(code)
    @assert code.head == :call
    Expr(:call, :pytask, esc(code.args[1]), esc.(code.args[2:end])...)
end

# FIXME: This doesn't work if we pass =args...; kwargs...`
macro pyfetch(code)
    @assert code.head == :call
    Expr(:call, :pyfetch, esc(code.args[1]), esc.(code.args[2:end])...)
end

@doc """ Schedules a Python coroutine to run on the event loop.

$(TYPEDSIGNATURES)
"""
function pyschedule(coro::Py)
    gpa.pyloop.create_task(
        if pyisinstance(coro, Python.gpa.pycoro_type)
            coro
        else
            coro()
        end,
    )
end

@doc """ Checks if a Python future is done.

$(TYPEDSIGNATURES)
"""
_isfutdone(fut::Py) = pyisnull(fut) || let v = fut.done()
    pyisTrue(v)
end

@doc """ Waits for a Python future to be done.

$(TYPEDSIGNATURES)
"""
pywait_fut(fut::Py) = begin
    if !_isfutdone(fut)
        try
            this_task = current_task()
            cond = this_task.donenotify
            this_task.storage = (ispytask=true, notify=cond)
            safewait(cond)
            # Manually cancel
            if !Python._isfutdone(fut)
                Python.pycancel(fut)
                safewait(cond)
                return nothing
            end
        catch
            if !_isfutdone(fut)
                Python.pycancel(fut)
            end
            rethrow()
        end
    end
    fut.result()
end

@doc """ Creates a Julia task from a Python coroutine and returns the Python future and the Julia task.

$(TYPEDSIGNATURES)
"""
function pytask(coro::Py)
    fut = pyschedule(coro)
    task = @async pywait_fut(fut)
    fut.add_done_callback((_) -> begin
        sto = task.storage
        if !isnothing(sto)
            cond = get(sto, :notify, missing)
            if !ismissing(cond)
                safenotify(cond)
            end
        end
    end)
    task
end

@doc """ Creates a Julia task from a Python function call and runs it asynchronously.

$(TYPEDSIGNATURES)
"""
function pytask(f::Py, args...; kwargs...)
    pytask(f(args...; kwargs...))
end

@doc """ Cancels a Python future.

$(TYPEDSIGNATURES)
"""
function pycancel(fut::Py)
    pyisnull(fut) || !pyisnull(gpa.pyloop.call_soon_threadsafe(fut.cancel))
end

function pycancel(task::Task)
    sto = task.storage
    if !isnothing(sto)
        if get(sto, :ispytask, false)
            safenotify(sto[:notify])
            fetch(task)
        else
            error("This task is not from python.")
        end
    else
        error("This task is not from python.")
    end
end

@doc """ Fetches the result of a Python function call synchronously.

$(TYPEDSIGNATURES)
"""
function _pyfetch(f::Py, args...; kwargs...)
    task = pytask(f(args...; kwargs...))
    try
        fetch(task)
    catch e
        if e isa TaskFailedException
            task.result
        else
            if !istaskdone(task)
                pycancel(task)
            end
            rethrow(e)
        end
    end
end

@doc """ Fetches the result of a Python function call synchronously and returns an exception if any.

$(TYPEDSIGNATURES)
"""
function _pyfetch(f::Py, ::Val{:try}, args...; kwargs...)
    try
        _pyfetch(f, args...; kwargs...)
    catch e
        e
    end
end

@doc """ Fetches the result of a Julia function call synchronously.

$(TYPEDSIGNATURES)
"""
function _pyfetch(f::Function, args...; kwargs...)
    fetch(@async(f(args...; kwargs...)))
end
_mockable_pyfetch(args...; kwargs...) = _pyfetch(args...; kwargs...)
pyfetch(args...; kwargs...) = @mock _mockable_pyfetch(args...; kwargs...)

@doc """ Fetches the result of a Python function call synchronously with a timeout. If the timeout is reached, it calls another function and returns its result.

$(TYPEDSIGNATURES)
"""
function _pyfetch_timeout(
    f1::Py, f2::Union{Function,Py}, timeout::Period, args...; kwargs...
)
    pytimeout = round(timeout, Second, RoundUp).value
    coro = gpa.pyaio.wait_for(f1(args...; kwargs...); timeout=pytimeout)
    task = pytask(coro)
    try
        fetch(task)
    catch e
        if e isa TaskFailedException
            result = e.task.result
            if pyisinstance(result, pybuiltins.TimeoutError)
                pyfetch(f2, args...; kwargs...)
            else
                result
            end
        else
            rethrow(e)
        end
    finally
        if !istaskdone(task)
            pycancel(task)
        end
    end
end

pyfetch_timeout(args...; kwargs...) = @mock _pyfetch_timeout(args...; kwargs...)

# function isrunning_func(running)
#     @pyexec (running) => """
#     global jl, jlrunning
#     import juliacall as jl
#     jlrunning = running
#     def isrunning(fut):
#         if fut.done():
#             jlrunning[0] = False
#     """ => isrunning
# end

# @doc "Main async loop function, sleeps indefinitely and closes loop on exception."
# function async_main_func()
#     code = """
#     global asyncio, inf
#     import asyncio
#     from math import inf
#     async def main():
#         try:
#             await asyncio.sleep(inf)
#         finally:
#             asyncio.get_running_loop().stop()
#     """
#     pyexec(NamedTuple{(:main,),Tuple{Py}}, code, pydict()).main
# end

_pyisrunning() = gpa.task_running[]

_set_loop(pa, loop) = pycopy!(pa.pyloop, loop)
_get_ref() =
    if isassigned(PYREF)
        PYREF[]
    end

@doc """Main async loop function, sleeps indefinitely and closes loop on exception.

$(TYPEDSIGNATURES)
"""
function async_start_runner_func!(pa)
    code = """
    global asyncio, juliacall, uvloop, Main
    import asyncio
    import juliacall
    import uvloop
    from juliacall import Main
    jlsleep = getattr(Main, "sleep")
    pysleep = asyncio.sleep
    async def main(Python):
        running = Python._pyisrunning
        pa = Python._get_ref()
        Python._set_loop(pa, asyncio.get_running_loop())
        try:
            while running():
                await pysleep(1e-3)
                jlsleep(1e-1)
        finally:
            loop = asyncio.get_running_loop()
            loop.close()
            loop.stop()
    """
    # main_func = pyexec(NamedTuple{(:main,),Tuple{Py}}, code, pydict()).main
    globs = pydict()
    pyexec(NamedTuple{(:main,),Tuple{Py}}, code, globs)
    code = """
    global asyncio, uvloop
    import asyncio, uvloop
    def start(Python):
        with asyncio.Runner(loop_factory=uvloop.new_event_loop) as runner:
            runner.run(main(Python))
    """
    start_func = pyexec(NamedTuple{(:start,),Tuple{Py}}, code, globs).start
    pycopy!(pa.start_func, start_func)
    pycopy!(pa.globs, globs)
end

export pytask, pyfetch, pycancel, @pytask, @pyfetch, pyfetch_timeout
