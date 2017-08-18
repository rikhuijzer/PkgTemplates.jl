"""
    generate(
        pkg_name::AbstractString,
        t::Template;
        force::Bool=false,
        ssh::Bool=false,
    ) -> Void

Generate a package from a template.

# Arguments
* `pkg_name::AbstractString`: Name of the package (with or without trailing ".jl").
* `t::Template`: The template from which to generate the package.

# Keyword Arguments
* `force::Bool=false`: Whether or not to overwrite old packages with the same name.
* `ssh::Bool=false`: Whether or not to use SSH for the remote.

# Notes
The package is generated entirely in a temporary directory (`t.temp_dir`), and only moved
into `joinpath(t.dir, pkg_name)` at the very end. In the case of an error, the temporary
directory will contain leftovers, but the destination directory will remain untouched
(this is especially helpful when `force=true`).
"""
function generate(
    pkg_name::AbstractString,
    t::Template;
    force::Bool=false,
    ssh::Bool=false,
)
    pkg_name = Pkg.splitjl(pkg_name)
    pkg_dir = joinpath(t.dir, pkg_name)
    temp_pkg_dir = joinpath(t.temp_dir, pkg_name)

    if !force && ispath(pkg_dir)
        throw(ArgumentError(
            "Path '$pkg_dir' already exists, use force=true to overwrite it."
        ))
    end

    # Initialize the repo and configure it.
    repo = LibGit2.init(temp_pkg_dir)
    info("Initialized git repo at $temp_pkg_dir")
    cfg = LibGit2.GitConfig(repo)
    !isempty(t.git_config) && info("Applying git configuration")
    for (key, val) in t.git_config
        LibGit2.set!(cfg, key, val)
    end
    LibGit2.commit(repo, "Empty initial commit")
    info("Made initial empty commit")
    rmt = if ssh
        "git@$(t.host):$(t.user)/$pkg_name.jl.git"
    else
        "https://$(t.host)/$(t.user)/$pkg_name.jl"
    end
    LibGit2.set_remote_url(repo, rmt)
    info("Set remote origin to $rmt")

    # Create the gh-pages branch if necessary.
    if haskey(t.plugins, GitHubPages)
        LibGit2.branch!(repo, "gh-pages")
        LibGit2.commit(repo, "Empty initial commit")
        info("Created empty gh-pages branch")
        LibGit2.branch!(repo, "master")
    end

    # Generate the files.
    files = vcat(
        gen_entrypoint(pkg_name, t),
        gen_tests(pkg_name, t),
        gen_require(temp_pkg_dir, t),
        gen_readme(pkg_name, t),
        gen_gitignore(pkg_name, t),
        gen_license(pkg_name, t),
        vcat(collect(gen_plugin(plugin, t, pkg_name) for plugin in values(t.plugins))...),
    )

    LibGit2.add!(repo, files...)
    info("Staged $(length(files)) files/directories: $(join(files, ", "))")
    LibGit2.commit(repo, "Files generated by PkgTemplates")
    info("Committed files generated by PkgTemplates")
    multiple_branches = length(collect(LibGit2.GitBranchIter(repo))) > 1
    info("Moving temporary package directory into $(t.dir)/")
    mv(temp_pkg_dir, pkg_dir; remove_destination=force)
    rm(t.temp_dir; recursive=true)
    info("Finished")
    if multiple_branches
        warn("Remember to push all created branches to your remote: git push --all")
    end
end

"""
    gen_entrypoint(pkg_name::AbstractString, template::Template) -> Vector{String}

Create the module entrypoint in the temp package directory.

# Arguments
* `pkg_name::AbstractString`: Name of the package.
* `template::Template`: The template whose entrypoint we are generating.

Returns an array of generated file/directory names.
"""
function gen_entrypoint(pkg_name::AbstractString, template::Template)
    text = """
        module $pkg_name

        # Package code goes here.

        end
        """

    gen_file(joinpath(template.temp_dir, pkg_name, "src", "$pkg_name.jl"), text)
    return ["src/"]
end

"""
    gen_tests(pkg_name::AbstractString, template::Template) -> Vector{String}

Create the test directory and entrypoint in the temp package directory.

# Arguments
* `pkg_name::AbstractString`: Name of the package.
* `template::Template`: The template whose tests we are generating.

Returns an array of generated file/directory names.
"""
function gen_tests(pkg_name::AbstractString, template::Template)
    text = """
        using $pkg_name
        using Base.Test

        # Write your own tests here.
        @test 1 == 2
        """

    gen_file(joinpath(template.temp_dir, pkg_name, "test", "runtests.jl"), text)
    return ["test/"]
end

"""
    gen_require(pkg_name::AbstractString, template::Template) -> Vector{String}

Create the `REQUIRE` file in the temp package directory.

# Arguments
* `pkg_name::AbstractString`: Name of the package.
* `template::Template`: The template whose REQUIRE we are generating.

Returns an array of generated file/directory names.
"""
function gen_require(pkg_name::AbstractString, template::Template)
    text = "julia $(version_floor(template.julia_version))\n"
    text *= join(template.requirements, "\n")

    gen_file(joinpath(template.temp_dir, pkg_name, "REQUIRE"), text)
    return ["REQUIRE"]
end

"""
    gen_readme(pkg_name::AbstractString, template::Template) -> Vector{String}

Create a README in the temp package directory with badges for each enabled plugin.

# Arguments
* `pkg_name::AbstractString`: Name of the package.
* `template::Template`: The template whose README we are generating.

Returns an array of generated file/directory names.
"""
function gen_readme(pkg_name::AbstractString, template::Template)
    text = "# $pkg_name\n"
    remaining = copy(collect(keys(template.plugins)))

    # Generate the ordered badges first, then add any remaining ones to the right.
    for plugin_type in BADGE_ORDER
        if haskey(template.plugins, plugin_type)
            text *= "\n"
            text *= join(
                badges(template.plugins[plugin_type], template.user, pkg_name),
                "\n",
            )
            deleteat!(remaining, find(p -> p == plugin_type, remaining)[1])
        end
    end
    for plugin_type in remaining
        text *= "\n"
        text *= join(
            badges(template.plugins[plugin_type], template.user, pkg_name),
            "\n",
        )
    end

    gen_file(joinpath(template.temp_dir, pkg_name, "README.md"), text)
    return ["README.md"]
end

"""
    gen_gitignore(pkg_name::AbstractString, template::Template) -> Vector{String}

Create a `.gitignore` in the temp package directory.

# Arguments
* `pkg_name::AbstractString`: Name of the package.
* `template::Template`: The template whose .gitignore we are generating.

Returns an array of generated file/directory names.
"""
function gen_gitignore(pkg_name::AbstractString, template::Template)
    text = ".DS_Store\n"
    seen = []
    patterns = vcat([plugin.gitignore for plugin in values(template.plugins)]...)
    for pattern in patterns
        if !in(pattern, seen)
            text *= "$pattern\n"
            push!(seen, pattern)
        end
    end

    gen_file(joinpath(template.temp_dir, pkg_name, ".gitignore"), text)
    return [".gitignore"]
end

"""
    gen_license(pkg_name::AbstractString, template::Template) -> Vector{String}

Create a license in the temp package directory.

# Arguments
* `pkg_name::AbstractString`: Name of the package.
* `template::Template`: The template whose LICENSE we are generating.

Returns an array of generated file/directory names.
"""
function gen_license(pkg_name::AbstractString, template::Template)
    if template.license == nothing
        return String[]
    end

    text = "Copyright (c) $(template.years) $(template.authors)\n"
    text *= read_license(template.license)

    gen_file(joinpath(template.temp_dir, pkg_name, "LICENSE"), text)
    return ["LICENSE"]
end

"""
    gen_file(file_path::AbstractString, text::AbstractString) -> Int

Create a new file containing some given text. Always ends the file with a newline.

# Arguments
* `file::AbstractString`: Path to the file to be created.
* `text::AbstractString`: Text to write to the file.

Returns the number of bytes written to the file.
"""
function gen_file(file::AbstractString, text::AbstractString)
    mkpath(dirname(file))
    if !endswith(text , "\n")
        text *= "\n"
    end
    open(file, "w") do fp
        return write(fp, text)
    end
end

"""
    version_floor(v::VersionNumber=VERSION) -> String

Format the given Julia version.

# Keyword arguments
* `v::VersionNumber=VERSION`: Version to floor.

Returns "major.minor" for the most recent release version relative to v. For prereleases
with v.minor == v.patch == 0, returns "major.minor-".
"""
function version_floor(v::VersionNumber=VERSION)
    if isempty(v.prerelease) || v.patch > 0
        return "$(v.major).$(v.minor)"
    else
        return "$(v.major).$(v.minor)-"
    end
end

"""
    substitute(template::AbstractString, view::Dict{String, Any}) -> String

Replace placeholders in `template` with values in `view`. `template` is not modified.

# Notes
Due to a bug in `Mustache`, conditionals often insert undesired newlines (more detail
[here](https://github.com/jverzani/Mustache.jl/issues/47)).

For example:
```
A
{{#B}}B{{/B}}
C
```

When `view` doesn't have a `"B"` key (or it does, but it's false), this becomes
`"A\\n\\nC"` We can get around this by writing ugly template files, like so:

```
A{{#B}}
B{{/B}}
C
```

In this case, the result is `"A\\nB\\nC"`, like we want it to be.

Also note that conditionals without a corresponding key in `view` won't error,
but will simply be evaluated as false.
"""
substitute(template::AbstractString, view::Dict{String, Any}) = render(template, view)

"""
    substitute(
        template::AbstractString,
        pkg_template::Template;
        view::Dict{String, Any}=Dict{String, Any}(),
    ) -> String

Replace placeholders in `template`, using some default replacements based on the
`pkg_template` and additional ones in `view`. `template` is not modified.
"""
function substitute(
    template::AbstractString,
    pkg_template::Template;
    view::Dict{String, Any}=Dict{String, Any}(),
)
    # Don't use version_floor here because we don't want the trailing '-' on prereleases.
    v = pkg_template.julia_version
    d = Dict{String, Any}(
        "USER" => pkg_template.user,
        "VERSION" => "$(v.major).$(v.minor)",
        "DOCUMENTER" => any(isa(p, Documenter) for p in values(pkg_template.plugins)),
        "CODECOV" => haskey(pkg_template.plugins, CodeCov),
        "COVERALLS" => haskey(pkg_template.plugins, Coveralls),
    )
    # d["AFTER"] is true whenever something needs to occur in a CI "after_script".
    d["AFTER"] = d["DOCUMENTER"] || d["CODECOV"] || d["COVERALLS"]
    return substitute(template, merge(d, view))
end
