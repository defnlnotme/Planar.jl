using Base: @kwdef
using Dates: Period
using TOML
using TimeFrames: TimeFrame
using Pkg: Pkg
using FunctionalCollections: PersistentHashMap
# TODO: move config to own pkg

@doc "The config path (TOML), relative to the current project directory."
function config_path()
    ppath = Pkg.project().path
    cfg_dir = joinpath(dirname(ppath), "cfg")
    path = joinpath(cfg_dir, "backtest.toml")
    if !ispath(path)
        @warn "Config file not found at $path, creating anew."
        mkpath(cfg_dir)
        touch(path)
    end
    path
end

@doc """The config main structure:
- `window`: The default number of candles (OHLCV).
- `timeframe`: The default timeframe of the candles.
- `qc`: The default quote currency.
- `margin`: If margin is enabled, only margin pairs are considered.
- `leverage`:
    - `:yes` : leveraged pairs will not be filtered.
    - `:only` : ONLY leveraged will not be filtered.
    - `:from` : Selects non leveraged pairs, that also have a leveraged siblings.
- `futures`: Selects the futures version of an Exchange.
- `attrs`: Generic metadata container.
- `sources`: mapping of modules symbols name to (.jl) file paths
"""
@kwdef mutable struct Config8
    path::String = ""
    window::Period = Day(7)
    timeframe::TimeFrame = TimeFrame("1d")
    qc::Symbol = :USDT
    margin::Bool = false
    leverage::Symbol = :no # FIXME: Should be enum
    futures::Bool = false
    vol_min::Float64 = 10e4
    # - `slope/min/max`: Used in Analysios/slope.
    # - `ct`: Used in Analysis/corr.
    # slope_min::Float64= 0.
    # slope_max::Float64 = 90.
    # ct::Dict{Symbol, NamedTuple} = Dict()
    sources::Dict{Symbol,String} = Dict()
    attrs::Dict{Any,Any} = Dict()
    toml = nothing
end
Config = Config8

@doc "Global configuration instance."
const config = Config()
const SourcesDict = Dict{Symbol,String}

@doc "Parses the toml file and populates the global `config`."
function loadconfig!(
    name::T;
    path::String=config_path(),
    cfg::Config=config,
) where {T<:Symbol}
    name = convert(Symbol, name)
    if !isfile(path)
        throw("Config file not found at path $(config.path)")
    else
        cfg.path = path
    end
    name = string(name)
    cfg.toml = PersistentHashMap(k => v for (k, v) in TOML.parsefile(config.path))
    if name ∉ keys(cfg.toml)
        throw(
            "Config section [$name] not found in the configuration read from $(config.path)",
        )
    end
    kwargs = Dict{Symbol,Any}()
    options = fieldnames(Config)
    for (opt, val) in cfg.toml[name]
        sym = Symbol(opt)
        if sym ∈ options
            kwargs[sym] = val
        else
            cfg.attrs[opt] = val
        end
        # setcfg!(Symbol(opt), val)
    end
    for (k, v) in cfg.toml["sources"]
        cfg.sources[Symbol(k)] = v
    end
    for k in setdiff(keys(cfg.toml), Set([name, "sources"]))
        cfg.attrs[k] = cfg.toml[k]
    end
    cfg
end

@doc "Reset global config to default values."
function resetconfig!()
    default = Config()
    for k in fieldnames(Config)
        setcfg!(k, getproperty(default, k))
    end
end

@doc "Toggle config margin flag."
macro margin!()
    :(config.margin = !config.margin)
end

@doc "Toggle config leverage flag"
macro lev!()
    :(config.leverage = !config.leverage)
end

@doc "Sets a single config value."
setcfg!(k, v) = setproperty!(config, k, v)

resetconfig!()

export Config, loadconfig!, resetconfig!
