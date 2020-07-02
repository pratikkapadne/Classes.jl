module Classes

using DataStructures
using MacroTools
using MacroTools:combinedef, combinestructdef
using InteractiveUtils: subtypes

export @class, Class, AbstractClass, isclass, classof, superclass, superclasses, issubclass, subclasses, absclass

#
# Functional interface to MacroTools' dict-based expression creation functions
# TBD: suggest adding these (without requiring dict) to MacroTools
#
function emit_struct(name::Symbol, supertype::Symbol, mutable::Bool, params::Vector, fields::Vector, ctors::Vector)
    fieldtups = [(tup[1], tup[2]) for tup in map(splitarg, fields)]
    d = Dict(:name=>name, :supertype=>supertype, :mutable=>mutable, :params=>params, :fields=>fieldtups, :constructors=>ctors)
    combinestructdef(d)
end

function emit_function(name::Symbol, body; args::Vector=[], kwargs::Vector=[], rtype=nothing, params::Vector=[], wparams::Vector=[])
    d = Dict(:name=>name, :args=>args, :kwargs=>kwargs, :body=>body, :params=>params, :whereparams=>wparams)
    if rtype !== nothing
        d[:rtype] = rtype
    end
    combinedef(d)
end


abstract type AbstractClass end            # supertype of all shadow class types
abstract type Class <: AbstractClass end   # superclass of all concrete classes

abs_symbol(cls::Symbol) = Symbol("Abstract", cls)

# Since nameof() doesn't cover all the cases we need, we define our own
typename(t) = t
typename(t::TypeVar) = t.name


# fieldnames(DataType)
# (:name, :super, :parameters, :types, :names, :instance, :layout, :size, :ninitialized, :uid, :abstract, :mutable, :hasfreetypevars,
# :isconcretetype, :isdispatchtuple, :isbitstype, :zeroinit, :isinlinealloc, Symbol("llvm::StructType"), Symbol("llvm::DIType"))
#
# if dtype.hasfreetypevars, dtype.types is like svec(XYZ<:ABC,...)

function _translate_ivar(d::Dict, ivar)
    if ! @capture(ivar, vname_::vtype_ | vname_)
        error("Expected field definition, got $ivar")
    end

    if vtype === nothing
        return ivar    # no type, nothing to translate
    end

    vtype = get(d, vtype, vtype)    # translate parameterized types
    return :($vname::$vtype)
end

function _translate_where(d::Dict, wparam::TypeVar)
    # supname = :Any
    supname = wparam.ub          # TBD: not sure this suffices
    name = wparam.name
    name = get(d, name, name)    # translate, if a type parameter, else pass through

    return :($name <: $supname)
end

# If a symbol is already a gensym, extract the symbol and re-gensym with it
regensym(s) = MacroTools.isgensym(s) ? gensym(Symbol(MacroTools.gensymname(s))) : gensym(s)

_cache = nothing

# Return info about a class in a named tuple
function _class_info(::Type{T}) where {T <: AbstractClass}
    global _cache
    _cache === nothing && (_cache = Dict())
    haskey(_cache, T) && return _cache[T]

    # @info "_class_info($T)"

    typ = (typeof(T) === UnionAll ? Base.unwrap_unionall(T) : T)

    # note: must extract symbol from type to create required expression
    ivars = (isabstracttype(typ) ? Expr[] : [:($vname::$(typename(vtype))) for (vname, vtype) in zip(fieldnames(typ), typ.types)])
    wheres = typ.parameters

    d = Dict(t.name=>regensym(t.name) for t in wheres)    # create mapping of type params to gen'd symbols
    ivars = [_translate_ivar(d, iv) for iv in ivars]      # translate types to use gensyms
    wheres = [_translate_where(d, w) for w in wheres]

    result = (wheres=wheres, ivars=ivars, super=superclass(typ))
    _cache[T] = result
    return result
end

"""
    superclass(t::Type{Class})

Returns the type of the concrete superclass of the given class, or `nothing`
for `Class`, which is the root of the class hierarchy.
"""
superclass(::Type{Class}) = nothing

"""
    superclasses(::Type{T}) where {T <: AbstractClass}

Returns a vector of superclasses from the superclass of the current class
to `Class`, in order.
"""
superclasses(::Type{Class}) = []

function superclasses(::Type{T}) where {T <: AbstractClass}
    super = superclass(T)
    [super, superclasses(super)...]
end

"""
    isclass(X)

Return `true` if `X` is a concrete subclass of `AbstractClass`, or is `Class`, which is abstract.
"""
isclass(any) = false

# Note that !isabstracttype(T) != isconcretetype(T): parameterized types return false for both
isclass(::Type{T}) where {T <: AbstractClass} = (T === Class || !isabstracttype(T))

"""
    issubclass(t1::DataType, t2::DataType)

Returns `true` if `t1` is a subclass of `t2`, else false.
"""
# identity
issubclass(::Type{T}, ::Type{T}) where {T <: AbstractClass} = true

issubclass(::Type{T1}, ::Type{T2}) where {T1 <: AbstractClass, T2 <: AbstractClass} = T1 in Set(superclasses(T2))

"""
    classof(::Type{T}) where {T <: AbstractClass}

Compute the concrete class associated with abstract class `T`, which must
be a subclass of `AbstractClass`.
"""
function classof(::Type{T}) where {T <: AbstractClass}
    if isclass(T)
        return T
    end

    # Abstract types should have only one concrete subtype
    concrete = filter(isconcretetype, subtypes(T))

    if length(concrete) == 1
        return concrete[1]
    end

    # Should never happen unless user manually creates errant subtypes
    error("Abstract class supertype $T has multiple concrete subtypes: $concrete")
end

"""
    subclasses(::Type{T}) where {T <: AbstractClass}

Compute the vector of subclasses for a given class.
"""
function subclasses(::Type{T}) where {T <: AbstractClass}
    # immediate supertype is "our" entry in the type hierarchy
    super = supertype(T)

    # collect immediate subclasses
    subs = [classof(t) for t in subtypes(super) if isabstracttype(t)]

    # recurse on subclasses
    return [subs; [subclasses(t) for t in subs]...]
end

"""
    absclass(::Type{T}) where {T <: AbstractClass}

Returns the abstract type associated with the concrete class `T`.
"""
function absclass(::Type{T}) where {T <: AbstractClass}
    isclass(T) ? supertype(T) : error("absclass(T) must be called on concrete classes; $T is abstract.")
end

function _argnames(fields)
    return [sym for (sym, arg_type, slurp, default) in map(splitarg, fields)]
end

# We generate two initializer functions: one takes all fields, cumulative through superclasses,
# and another initializes only locally-defined fields. This function produces either, depending
# on the fields passed by _constructors().
function _initializer(class, fields, wheres)
    args = _argnames(fields)
    # we use setfield!() to allow classes to override setproperty()
    # assigns = [:(_self.$arg = $arg) for arg in args]
    assigns = [:(setfield!(_self, $(QuoteNode(arg)), $arg)) for arg in args]
    T = gensym(class)

    funcdef = :(
        function $class(_self::$T, $(fields...)) where {$T <: $(abs_symbol(class)), $(wheres...)}
            $(assigns...)
            _self
        end
    )

    return funcdef
end

function super_constructor_inheritance(clsname, super, super_fields, has_params, params)
    guide_constructor = Expr[]
    super_fields_len = length(super_fields)
    # new{T...} is not supported on Julia 1.0.5
    if has_params
        function_return = :(new{(getfield(typeof(super_inctance), :parameters)...)})
    else
        function_return = :(new)
    end
    # paramsless constructor
    if super_fields_len != 0
        argnames = _argnames(super_fields)
        paramsless_guide_constructor = quote
            function $clsname(arguments...)
                super_inctance = $super(arguments...)    # super's extra constructor
                # setting subclass fields
                subcls_fields = getfield.(Ref(super_inctance), $argnames)
                return $function_return(subcls_fields...)
            end
        end
    else
        # call the super constructor that may do some stuff
        paramsless_guide_constructor = quote
            function $clsname(arguments...)
                super_inctance = $super(arguments...) # does something
                return $function_return()
            end
        end
    end
    push!(guide_constructor, paramsless_guide_constructor)
    # paramsful constructor
    if has_params
        if super_fields_len != 0
            argnames = _argnames(super_fields)
            paramsful_guide_constructor = quote
                function $clsname{$(params...)}(arguments...) where {$(params...)}
                    super_inctance = $super{$(params...)}(arguments...)    # super's extra constructor
                    # setting subclass fields
                    subcls_fields = getfield.(Ref(super_inctance), $argnames)
                    return $function_return(subcls_fields...)
                end
            end
        else
            # call the super constructor that may do some stuff
            paramsful_guide_constructor = quote
                function $clsname{$(params...)}(arguments...) where {$(params...)}
                    super_inctance = $super{$(params...)}(arguments...) # does something
                    return $function_return()
                end
            end
        end
        push!(guide_constructor, paramsful_guide_constructor)
    end
    return guide_constructor
end

function _constructors(clsname, super, super_info, local_fields, all_fields, wheres)
    all_wheres = [super_info.wheres; wheres]
    init_all = _initializer(clsname, all_fields, all_wheres)
    inits = [init_all]

    # If clsname is a direct subclasses of Classes.Class, it has no fields
    # other than those defined locally, so the two methods would be identical.
    # In this case, we emit only one of them.
    if all_fields != local_fields
        init_local = _initializer(clsname, local_fields, wheres)
        push!(inits, init_local)
    end

    # extract parameter names from where clauses
    params = [(clause isa Expr ? clause.args[1] : clause) for clause in all_wheres]
    has_params = length(params) != 0

    args = _argnames(all_fields)
    body = has_params ? :(new{$(params...)}($(args...))) : :(new($(args...)))
    dflt = emit_function(clsname, body, args=all_fields, params=params, wparams=all_wheres, rtype=clsname)

    methods = [dflt]

    # Primarily for immutable classes, we emit a constructor that takes an instance
    # of the direct superclass and copies values when creating a new object.
    super_fields = super_info.ivars
    if length(super_fields) != 0
        # super_args = [:(_super.$arg) for arg in _argnames(super_fields)]
        super_args = [:(getfield(_super, $(QuoteNode(arg)))) for arg in _argnames(super_fields)]
        local_args = _argnames(local_fields)
        all_args = [super_args; local_args]

        body = has_params ? :(new{$(params...)}($(all_args...))) : :(new($(all_args...)))
        args = [:(_super::$super); local_fields]
        immut_init = emit_function(clsname, body; args=args, params=params, wparams=all_wheres, rtype=clsname)
        push!(methods, immut_init)
    end

    # super constructor inheritance: when the class and superclass have the same fields,
    # the constructors of the superclass are valid for the subclass,
    # so we make an outter constructor for subclass pointing to those.
    if super !== Class && length(local_fields) === 0
        guide_constructor = super_constructor_inheritance(clsname, super, super_fields, has_params, params)
        push!(methods, guide_constructor...)
    end

    return methods, inits
end

function _defclass(clsname, supercls, mutable, wheres, exprs)
    wheres   = (wheres === nothing ? [] : wheres)
    # @info "clsname:$clsname supercls:$supercls mutable:$mutable wheres:$wheres exprs:$exprs"

    # partition expressions into constructors and field defs
    ctors  = Vector{Expr}()
    fields = Vector{Union{Expr, Symbol}}()
    for ex in exprs
        if ex isa Symbol || (ex isa Expr && ex.head === :(::) && ex.args[1] isa Symbol )  # x or x::Int64
            push!(fields, ex)
        else
            splitdef(ex)        # throws AssertionError if not a func def
            push!(ctors, ex)
        end
    end

    super_info = _class_info(supercls)
    all_fields = [super_info.ivars; fields]
    all_wheres = [super_info.wheres; wheres]

    # add default constructors
    inner, outer = _constructors(clsname, supercls, super_info, fields, all_fields, wheres)
    append!(ctors, inner)

    abs_class = abs_symbol(clsname)
    abs_super = nameof(absclass(supercls))

    struct_def = emit_struct(clsname, abs_class, mutable, all_wheres, all_fields, ctors)

    # set mutability flag
    struct_def.args[1] = mutable

    result = quote
        abstract type $abs_class <: $abs_super end
        Base.@__doc__($struct_def)
        $(outer...)
        Classes.superclass(::Type{$clsname}) = $supercls
        $clsname    # return the struct type
    end

    return result
end

macro class(elements...)
    if (mutable = (elements[1] == :mutable))
        elements = elements[2:end]
    end

    if (len = length(elements)) == 1                       # no fields defined
        name_expr = elements[1]
        definition = quote end
    elseif len == 2
        (name_expr, definition) = elements
    else
        error("Unrecognized form for @class definition: $elements")
    end

    # @info "name_expr: $name_expr, definition: $definition"

    # initialize the "captured" vars to avoid "unknown var" warnings
    cls = clsname = exprs = wheres = nothing

    @capture(definition, begin exprs__ end)

    # allow for optional type params and supertype
    if ! (@capture(name_expr, ((cls_{wheres__} | cls_) <: supername_) | (cls_{wheres__} | cls_)) && cls isa Symbol)
        error("Unrecognized class name expression: `$name_expr`")
    end

    supername = (supername === nothing ? :Class : supername)

    # __module__ is a "hidden" arg passed to macros with the caller's Module
    expr = _defclass(cls, getproperty(__module__, supername), mutable, wheres, exprs)
    return esc(expr)
end

end # module
