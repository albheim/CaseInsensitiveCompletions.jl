module CaseInsensitiveCompletions

using Pkg
using REPL

import Pkg: REPLMode
import REPL: LineEdit

function REPLMode.complete_remote_package(partial)
    isempty(partial) && return String[]
    cmp = Set{String}()
    for reg in Registry.reachable_registries()
        for (uuid, regpkg) in reg
            name = regpkg.name
            name in cmp && continue
            if startswith(lowercase(regpkg.name), lowercase(partial))
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
        p = LineEdit.common_prefix(completions)
        if !isempty(p) && p != partial && length(p) == length(LineEdit.common_prefix(lowercase.(completions)))
            # All possible completions share the same prefix, so we might as
            # well complete that
            prev_pos = LineEdit.position(s)
            LineEdit.push_undo(s)
            LineEdit.edit_splice!(s, (prev_pos - sizeof(partial)) => prev_pos, p)
        elseif repeats > 0
            LineEdit.show_completions(s, completions)
        end
    end
    return true
end

end 
