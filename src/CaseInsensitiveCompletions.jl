# These methods are coped from the julia source and slightly modified
# Julia licence is here https://github.com/JuliaLang/julia/blob/master/LICENSE.md

module CaseInsensitiveCompletions

using Pkg
using REPL

import Pkg: REPLMode
import REPL: LineEdit, REPLCompletions

startswith_lowercase(a, b) = startswith(lowercase(a), lowercase(b))

function REPLMode.complete_remote_package(partial)
    isempty(partial) && return String[]
    cmp = Set{String}()
    for reg in Registry.reachable_registries()
        for (uuid, regpkg) in reg
            name = regpkg.name
            name in cmp && continue
            if startswith_lowercase(regpkg.name, partial)
                pkg = Registry.registry_info(regpkg)
                compat_info = Registry.compat_info(pkg)
                # Filter versions
                for (v, uncompressed_compat) in compat_info
                    Registry.isyanked(pkg, v) && continue
                    # TODO: Filter based on offline mode
                    is_julia_compat = nothing
                    for (pkg_uuid, vspec) in uncompressed_compat
                        if pkg_uuid == REPLMode.JULIA_UUID
                            found_julia_compat = true
                            is_julia_compat = VERSION in vspec
                            is_julia_compat && continue
                        end
                    end
                    # Found a compatible version or compat on julia at all => compatible
                    if is_julia_compat === nothing || is_julia_compat
                        push!(cmp, name)
                        break
                    end
                end
            end
        end
    end
    return sort!(collect(cmp))
end

function LineEdit.complete_line(s::LineEdit.PromptState, repeats::Int)
    completions, partial, should_complete = LineEdit.complete_line(s.p.complete, s)::Tuple{Vector{String},String,Bool}
    isempty(completions) && return false
    if !should_complete
        # should_complete is false for cases where we only want to show
        # a list of possible completions but not complete, e.g. foo(\t
        LineEdit.show_completions(s, completions)
    elseif length(completions) == 1
        # Replace word by completion
        prev_pos = LineEdit.position(s)
        LineEdit.push_undo(s)
        LineEdit.edit_splice!(s, (prev_pos - sizeof(partial)) => prev_pos, completions[1])
    else
        lc_completions = lowercase.(completions)
        p = LineEdit.common_prefix(lc_completions)
        if !isempty(p) 
            ind = findfirst(==(p), lc_completions)
            if ind !== nothing
                prev_pos = LineEdit.position(s)
                LineEdit.push_undo(s)
                LineEdit.edit_splice!(s, (prev_pos - sizeof(partial)) => prev_pos, completions[ind])
            elseif p != lowercase(partial)
                # All possible completions share the same prefix, so we might as
                # well complete that
                prev_pos = LineEdit.position(s)
                LineEdit.push_undo(s)
                LineEdit.edit_splice!(s, (prev_pos - sizeof(partial)) => prev_pos, p)
            end
        elseif repeats > 0
            LineEdit.show_completions(s, completions)
        end
    end
    return true
end

function REPLCompletions.project_deps_get_completion_candidates(pkgstarts::String, project_file::String)
    loading_candidates = String[]
    d = Base.parsed_toml(project_file)
    pkg = get(d, "name", nothing)::Union{String, Nothing}
    if pkg !== nothing && startswith_lowercase(pkg, pkgstarts)
        push!(loading_candidates, pkg)
    end
    deps = get(d, "deps", nothing)::Union{Dict{String, Any}, Nothing}
    if deps !== nothing
        for (pkg, _) in deps
            startswith_lowercase(pkg, pkgstarts) && push!(loading_candidates, pkg)
        end
    end
    return REPLCompletions.Completion[REPLCompletions.PackageCompletion(name) for name in loading_candidates]
end

function REPLCompletions.completions(string::String, pos::Int, context_module::Module=Main)
    # First parse everything up to the current position
    partial = string[1:pos]
    inc_tag = Base.incomplete_tag(Meta.parse(partial, raise=false, depwarn=false))

    # if completing a key in a Dict
    identifier, partial_key, loc = REPLCompletions.dict_identifier_key(partial, inc_tag, context_module)
    if identifier !== nothing
        matches = find_dict_matches(identifier, partial_key)
        length(matches)==1 && (lastindex(string) <= pos || string[nextind(string,pos)] != ']') && (matches[1]*=']')
        length(matches)>0 && return REPLCompletions.Completion[REPLCompletions.DictCompletion(identifier, match) for match in sort!(matches)], loc::Int:pos, true
    end

    # otherwise...
    if inc_tag in [:cmd, :string]
        m = match(r"[\t\n\r\"`><=*?|]| (?!\\)", reverse(partial))
        startpos = nextind(partial, reverseind(partial, m.offset))
        r = startpos:pos

        expanded = REPLCompletions.complete_expanduser(replace(string[r], r"\\ " => " "), r)
        expanded[3] && return expanded  # If user expansion available, return it

        paths, r, success = REPLCompletions.complete_path(replace(string[r], r"\\ " => " "), pos)

        if inc_tag === :string &&
           length(paths) == 1 &&  # Only close if there's a single choice,
           !isdir(expanduser(replace(string[startpos:prevind(string, first(r))] * paths[1].path,
                                     r"\\ " => " "))) &&  # except if it's a directory
           (lastindex(string) <= pos ||
            string[nextind(string,pos)] != '"')  # or there's already a " at the cursor.
            paths[1] = REPLCompletions.PathCompletion(paths[1].path * "\"")
        end

        #Latex symbols can be completed for strings
        (success || inc_tag==:cmd) && return sort!(paths, by=p->p.path), r, success
    end

    ok, ret = REPLCompletions.bslash_completions(string, pos)
    ok && return ret

    # Make sure that only bslash_completions is working on strings
    inc_tag==:string && return REPLCompletions.Completion[], 0:-1, false
    if inc_tag === :other && REPLCompletions.should_method_complete(partial)
        frange, method_name_end = REPLCompletions.find_start_brace(partial)
        # strip preceding ! operator
        s = replace(partial[frange], r"\!+([^=\(]+)" => s"\1")
        ex = Meta.parse(s * ")", raise=false, depwarn=false)

        if isa(ex, Expr)
            if ex.head === :call
                return REPLCompletions.complete_methods(ex, context_module), first(frange):method_name_end, false
            elseif ex.head === :. && ex.args[2] isa Expr && (ex.args[2]::Expr).head === :tuple
                return REPLCompletions.complete_methods(ex, context_module), first(frange):(method_name_end - 1), false
            end
        end
    elseif inc_tag === :comment
        return REPLCompletions.Completion[], 0:-1, false
    end

    dotpos = something(findprev(isequal('.'), string, pos), 0)
    startpos = nextind(string, something(findprev(in(REPLCompletions.non_identifier_chars), string, pos), 0))
    # strip preceding ! operator
    if (m = match(r"^\!+", string[startpos:pos])) !== nothing
        startpos += length(m.match)
    end

    ffunc = (mod,x)->true
    suggestions = REPLCompletions.Completion[]
    comp_keywords = true
    if REPLCompletions.afterusing(string, startpos)
        # We're right after using or import. Let's look only for packages
        # and modules we can reach from here

        # If there's no dot, we're in toplevel, so we should
        # also search for packages
        s = string[startpos:pos]
        if dotpos <= startpos
            for dir in Base.load_path()
                if basename(dir) in Base.project_names && isfile(dir)
                    append!(suggestions, REPLCompletions.project_deps_get_completion_candidates(s, dir))
                end
                isdir(dir) || continue
                for pname in readdir(dir)
                    if pname[1] != '.' && pname != "METADATA" &&
                        pname != "REQUIRE" && startswith_lowercase(pname, s)
                        # Valid file paths are
                        #   <Mod>.jl
                        #   <Mod>/src/<Mod>.jl
                        #   <Mod>.jl/src/<Mod>.jl
                        if isfile(joinpath(dir, pname))
                            endswith(pname, ".jl") && push!(suggestions,
                                                            REPLCompletions.PackageCompletion(pname[1:prevind(pname, end-2)]))
                        else
                            mod_name = if endswith(pname, ".jl")
                                pname[1:prevind(pname, end-2)]
                            else
                                pname
                            end
                            if isfile(joinpath(dir, pname, "src",
                                               "$mod_name.jl"))
                                push!(suggestions, REPLCompletions.PackageCompletion(mod_name))
                            end
                        end
                    end
                end
            end
        end
        ffunc = (mod,x)->(Base.isbindingresolved(mod, x) && isdefined(mod, x) && isa(getfield(mod, x), Module))
        comp_keywords = false
    end
    startpos == 0 && (pos = -1)
    dotpos < startpos && (dotpos = startpos - 1)
    s = string[startpos:pos]
    comp_keywords && append!(suggestions, REPLCompletions.complete_keyword(s))
    # The case where dot and start pos is equal could look like: "(""*"").d","". or  CompletionFoo.test_y_array[1].y
    # This case can be handled by finding the beginning of the expression. This is done below.
    if dotpos == startpos
        i = prevind(string, startpos)
        while 0 < i
            c = string[i]
            if c in [')', ']']
                if c==')'
                    c_start='('; c_end=')'
                elseif c==']'
                    c_start='['; c_end=']'
                end
                frange, end_of_identifier = REPLCompletions.find_start_brace(string[1:prevind(string, i)], c_start=c_start, c_end=c_end)
                startpos = first(frange)
                i = prevind(string, startpos)
            elseif c in ('\'', '\"', '\`')
                s = "$c$c"*string[startpos:pos]
                break
            else
                break
            end
            s = string[startpos:pos]
        end
    end
    append!(suggestions, REPLCompletions.complete_symbol(s, ffunc, context_module))
    return sort!(unique(suggestions), by=REPLCompletions.completion_text), (dotpos+1):pos, true
end

end