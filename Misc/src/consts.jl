@doc "Global configuration instance."
const config = Config()
const SourcesDict = Dict{Symbol,String}()
const _config_defaults = _defaults(config)
