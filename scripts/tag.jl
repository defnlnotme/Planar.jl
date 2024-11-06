using TOML
using Pkg

function tag_repo(; major=nothing, minor=nothing, patch=nothing)
    Pkg.activate("Vindicta")
    p = Pkg.project()
    v = p.version
    if isnothing(major)
        major = v.major
        patch = if isnothing(minor)
            minor = v.minor
            @something patch v.patch + 1
        else
            0
        end
    elseif isnothing(minor)
        minor = 0
        patch = 0
    else
    end
    toml = TOML.parsefile(p.path)
    v_string = string(VersionNumber(major, minor, patch))
    toml["version"] = v_string
    open(p.path, "w") do f
        TOML.print(f, toml)
    end
    Pkg.activate("VindictaInteractive")
    Pkg.resolve()
    Pkg.activate("VindictaDev")
    Pkg.resolve()
    Pkg.activate("Vindicta")
    run(`git add Vindicta/Project.toml VindictaDev/Manifest.toml VindictaInteractive/Manifest.toml`)
    run(`git commit -m "v$v_string"`)
    run(`git tag v$v_string`)
end
