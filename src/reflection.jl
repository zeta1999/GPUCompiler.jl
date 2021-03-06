using InteractiveUtils, Cthulhu


#
# code_* replacements
#

code_lowered(job::AbstractCompilerJob; kwargs...) =
    InteractiveUtils.code_lowered(source(job).f, source(job).tt; kwargs...)

function code_typed(job::AbstractCompilerJob; interactive::Bool=false, kwargs...)
    # TODO: use the compiler driver to get the Julia method instance (we might rewrite it)
    if interactive
        descend_code_typed(source(job).f, source(job).tt; kwargs...)
    else
        InteractiveUtils.code_typed(source(job).f, source(job).tt; kwargs...)
    end
end

function code_warntype(io::IO, job::AbstractCompilerJob; interactive::Bool=false, kwargs...)
    # TODO: use the compiler driver to get the Julia method instance (we might rewrite it)
    if interactive
        @assert io == stdout
        descend_code_warntype(source(job).f, source(job).tt; kwargs...)
    else
        InteractiveUtils.code_warntype(io, source(job).f, source(job).tt; kwargs...)
    end
end
code_warntype(job::AbstractCompilerJob; kwargs...) = code_warntype(stdout, job; kwargs...)

"""
    code_llvm([io], job; optimize=true, raw=false, dump_module=false, strict=false)

Prints the device LLVM IR generated for the given compiler job to `io` (default `stdout`).

The following keyword arguments are supported:

- `optimize`: determines if the code is optimized, which includes kernel-specific
  optimizations if `kernel` is true
- `raw`: return the raw IR including all metadata
- `dump_module`: display the entire module instead of just the function
- `strict`: verify generate code as early as possible

See also: [`@device_code_llvm`](@ref), InteractiveUtils.code_llvm
"""
function code_llvm(io::IO, job::AbstractCompilerJob; optimize::Bool=true, raw::Bool=false,
                   debuginfo::Symbol=:default, dump_module::Bool=false, strict::Bool=false)
    # NOTE: jl_dump_function_ir supports stripping metadata, so don't do it in the driver
    ir, entry = GPUCompiler.codegen(:llvm, job; optimize=optimize, strip=false, strict=strict)
    str = ccall(:jl_dump_function_ir, Ref{String},
                (Ptr{Cvoid}, Bool, Bool, Ptr{UInt8}),
                LLVM.ref(entry), !raw, dump_module, debuginfo)
    print(io, str)
end
code_llvm(job::AbstractCompilerJob; kwargs...) = code_llvm(stdout, job; kwargs...)

"""
    code_native([io], f, types; cap::VersionNumber, kernel=false, raw=false, strict=false)

Prints the native assembly generated for the given compiler job to `io` (default `stdout`).

The following keyword arguments are supported:

- `cap` which device to generate code for
- `kernel`: treat the function as an entry-point kernel
- `raw`: return the raw code including all metadata
- `strict`: verify generate code as early as possible

See also: [`@device_code_native`](@ref), InteractiveUtils.code_llvm
"""
function code_native(io::IO, job::AbstractCompilerJob; raw::Bool=false, strict::Bool=false)
    asm, _ = GPUCompiler.codegen(:asm, job; strip=!raw, strict=strict)
    print(io, asm)
end
code_native(job::AbstractCompilerJob; kwargs...) =
    code_native(stdout, func, types; kwargs...)


#
# @device_code_* functions
#

function emit_hooked_compilation(inner_hook, ex...)
    user_code = ex[end]
    user_kwargs = ex[1:end-1]
    quote
        # wipe the compile cache to force recompilation
        empty!(GPUCompiler.compilecache)

        local kernels = 0
        function outer_hook(job)
            kernels += 1
            $inner_hook(job; $(map(esc, user_kwargs)...))
        end

        if GPUCompiler.compile_hook[] != nothing
            error("Chaining multiple @device_code calls is unsupported")
        end
        try
            GPUCompiler.compile_hook[] = outer_hook
            $(esc(user_code))
        finally
            GPUCompiler.compile_hook[] = nothing
        end

        if kernels == 0
            error("no kernels executed while evaluating the given expression")
        end

        nothing
    end
end

"""
    @device_code_lowered ex

Evaluates the expression `ex` and returns the result of
InteractiveUtils.code_lowered for every compiled GPU kernel.

See also: InteractiveUtils.@code_lowered
"""
macro device_code_lowered(ex...)
    quote
        buf = Any[]
        function hook(job::AbstractCompilerJob)
            append!(buf, code_lowered(job))
        end
        $(emit_hooked_compilation(:hook, ex...))
        buf
    end
end

"""
    @device_code_typed ex

Evaluates the expression `ex` and returns the result of
InteractiveUtils.code_typed for every compiled GPU kernel.

See also: InteractiveUtils.@code_typed
"""
macro device_code_typed(ex...)
    quote
        output = Dict{AbstractCompilerJob,Any}()
        function hook(job::AbstractCompilerJob)
            output[job] = code_typed(job)
        end
        $(emit_hooked_compilation(:hook, ex...))
        output
    end
end

"""
    @device_code_warntype [io::IO=stdout] ex

Evaluates the expression `ex` and prints the result of
InteractiveUtils.code_warntype to `io` for every compiled GPU kernel.

See also: InteractiveUtils.@code_warntype
"""
macro device_code_warntype(ex...)
    function hook(job::AbstractCompilerJob; io::IO=stdout, kwargs...)
        println(io, "$job")
        println(io)
        code_warntype(io, job; kwargs...)
    end
    emit_hooked_compilation(hook, ex...)
end

"""
    @device_code_llvm [io::IO=stdout, ...] ex

Evaluates the expression `ex` and prints the result of InteractiveUtils.code_llvm
to `io` for every compiled GPU kernel. For other supported keywords, see
[`GPUCompiler.code_llvm`](@ref).

See also: InteractiveUtils.@code_llvm
"""
macro device_code_llvm(ex...)
    function hook(job::AbstractCompilerJob; io::IO=stdout, kwargs...)
        println(io, "; $job")
        code_llvm(io, job; kwargs...)
    end
    emit_hooked_compilation(hook, ex...)
end

"""
    @device_code_native [io::IO=stdout, ...] ex

Evaluates the expression `ex` and prints the result of [`GPUCompiler.code_native`](@ref) to `io`
for every compiled GPU kernel. For other supported keywords, see
[`GPUCompiler.code_native`](@ref).
"""
macro device_code_native(ex...)
    function hook(job::AbstractCompilerJob; io::IO=stdout, kwargs...)
        println(io, "// $job")
        println(io)
        code_native(io, job; kwargs...)
    end
    emit_hooked_compilation(hook, ex...)
end

"""
    @device_code dir::AbstractString=... [...] ex

Evaluates the expression `ex` and dumps all intermediate forms of code to the directory
`dir`.
"""
macro device_code(ex...)
    only(xs) = (@assert length(xs) == 1; first(xs))
    localUnique = 1
    function hook(job::AbstractCompilerJob; dir::AbstractString)
        name = something(job.source.name, nameof(job.source.f))
        fn = "$(name)_$(localUnique)"
        mkpath(dir)

        open(joinpath(dir, "$fn.lowered.jl"), "w") do io
            code = only(code_lowered(job))
            println(io, code)
        end

        open(joinpath(dir, "$fn.typed.jl"), "w") do io
            if VERSION >= v"1.1.0"
                code = only(code_typed(job; debuginfo=:source))
            else
                code = only(code_typed(job))
            end
            println(io, code)
        end

        open(joinpath(dir, "$fn.unopt.ll"), "w") do io
            code_llvm(io, job; dump_module=true, raw=true, optimize=false)
        end

        open(joinpath(dir, "$fn.opt.ll"), "w") do io
            code_llvm(io, job; dump_module=true, raw=true)
        end

        open(joinpath(dir, "$fn.asm"), "w") do io
            code_native(io, job)
        end

        localUnique += 1
    end
    emit_hooked_compilation(hook, ex...)
end
