# CaseInsensitiveCompletions.jl

A small package to test out case insensitive package completions in the REPL.

The current implementation was just a quick thing to be able to test this, and is overwriting stdlib methods which will create some warnings.

It currently just makes all comparisons in lowercase and completes as much as possible in lowercase. 
If a single completion exists it will put it with correct casing, or when one of the possible completions is the same as the current completion it will use the casing of that completion (`import libc[tab]` becomes `import LibCURL`).

It currently works for packages, both with `pkg> add/remove/update name[tab]` and `using/import name[tab]`.

Since it is overwriting internal julia methods it might not work well with julia version other than v1.7.2, but I haven't tried.

## Install
```julia
]add https://github.com/albheim/CaseInsensitiveCompletions.jl
```

## Usage
Running
```julia
using CaseInsensitiveCompletions
```
should overwrite existing methods.
