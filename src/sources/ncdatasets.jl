using .NCDatasets

export NCDarray, NCDstack, NCDstackMetadata, NCDarrayMetadata, NCDdimMetadata

struct NCDstackMetadata{K,V} <: ArrayMetadata{K,V}
    val::Dict{K,V}
end

struct NCDarrayMetadata{K,V} <: ArrayMetadata{K,V}
    val::Dict{K,V}
end

struct NCDdimMetadata{K,V} <: DimMetadata{K,V}
    val::Dict{K,V}
end

# Array ########################################################################
"""
    NCDarray(filename::AbstractString; refdims=(), window=())

Create an array from a path to a netcdf file. The first non-dimension
layer of the file will be used as the array.

## Arguments
- `filename`: `String` pointing to a netcdf file.

## Keyword arguments
- `refdims`: Add dimension position array was sliced from. Mostly used programatically.
- `window`: `Tuple` of `Dimension`, `Selector` or regular index to be applied when 
  loading the array. Can save on disk load time for large files.
"""
struct NCDarray{T,N,A,D<:Tuple,R<:Tuple,Na<:AbstractString,Me,Mi,W,S
               } <: DiskGeoArray{T,N,D,LazyArray{T,N}}
    filename::A
    dims::D
    refdims::R
    name::Na
    metadata::Me
    missingval::Mi
    window::W
    size::S
end
NCDarray(filename::AbstractString; kwargs...) =
    ncapply(dataset -> NCDarray(dataset, filename; kwargs...), filename)
NCDarray(dataset::NCDatasets.Dataset, filename;
         dims=dims(dataset),
         refdims=(),
         name=nothing,
         metadata=nothing,
         window=()) = begin
    key = first(nondimkeys(dataset))
    var = dataset[key]
    if name isa Nothing
        name = key
    end
    if metadata isa Nothing
        metadata = GeoData.metadata(var, GeoData.metadata(dataset))
    end
    if window == ()
        sze = size(var)
    else
        window = dims2indices(dims, window)
        sze = windowsize(window)
    end
    missingval = missing
    T = eltype(var)
    N = length(sze)
    NCDarray{T,N,typeof.((filename,dims,refdims,name,metadata,missingval,window,sze))...
       }(filename, dims, refdims, name, metadata, missingval, window, sze)
end

# AbstractGeoArray methods

data(A::NCDarray) =
    ncapply(filename(A)) do dataset
        var = dataset[name(A)]
        _window = maybewindow2indices(var, dims(A), window(A))
        ncread(var, _window)
    end

filename(A::NCDarray) = A.filename

crs(A::NCDarray) = ncapply(crs, filename(A))

# Base methods

Base.size(A::NCDarray) = A.size

Base.getindex(A::NCDarray, I::Vararg{<:Union{<:Integer,<:AbstractArray}}) =
    ncapply(filename(A)) do dataset
        var = dataset[name(A)]
        _window = maybewindow2indices(var, dims(A), window(A))
        # Slice for both window and indices
        _dims, _refdims = slicedims(slicedims(dims(A), refdims(A), _window)..., I)
        data = ncread(var, _window, I...)
        rebuild(A, data, _dims, _refdims)
    end
Base.getindex(A::NCDarray, I::Vararg{<:Integer}) =
    ncapply(filename(A)) do dataset
        var = dataset[name(A)]
        _window = maybewindow2indices(var, dims(A), window(A))
        ncread(var, _window, I...)
    end

"""
    Base.write(filename::AbstractString, ::Type{NCDarray}, s::AbstractGeoArray)

Write an NCDarray to a netcdf file using NCDatasets.jl
"""
Base.write(filename::AbstractString, ::Type{NCDarray}, A::AbstractGeoArray) = begin
    # Remove the dataset metadata
    stackmd = pop!(deepcopy(val(metadata(A))), "dataset", Dict())
    dataset = NCDatasets.Dataset(filename, "c"; attrib=stackmd)
    try
        ncwritevar!(dataset, A)
    finally
        close(dataset)
    end
end

# Stack ########################################################################

"""
    NCDstack(filename; refdims=(), window=(), metadata=nothing)

A lazy GeoStack that loads netcdf files using NCDatasets.jl

Create a stack from the filename of a netcdf file. Passing a 
vector of `String` will create a stack from multiple files. 
The first non-dimension layer of each file will be used in the stack.

# Arguments
-`filename`: `String` or `Vector` of `String` pointing to netcdf file(s).

# Keyword arguments
- `refdims`: Add dimension position array was sliced from. Mostly used programatically.
- `window`: can be a tuple of Dimensions, selectors or regular indices.
- `metadata`: Add additional metadata as a `Dict`.

# Examples
```julia
stack = NCDstack(filename; window=(Lat(Between(20, 40),))
stack[:soil_temperature]

multifile_stack = NCDstack([path1, path2, path3, path4])
```
"""
struct NCDstack{T,R,W,M} <: DiskGeoStack{T}
    filename::T
    refdims::R
    window::W
    metadata::M
end
NCDstack(filenames::Union{Tuple,Vector}; refdims=(), window=(), metadata=nothing,
         keys=Tuple(Symbol.((ncapply(ds -> first(nondimkeys(ds)), fp) for fp in filenames)))) =
    NCDstack(NamedTuple{keys}(filenames), refdims, window, metadata)
NCDstack(filename::AbstractString; refdims=(), window=(), metadata=ncapply(metadata, filename)) =
    NCDstack(filename, refdims, window, metadata)

# AbstractGeoStack methods

safeapply(f, ::NCDstack, path) = ncapply(f, path)

dims(::NCDstack, dataset, key::Key) = dims(dataset, key)
dims(::NCDstack, dataset, key::Key) = dims(dataset, key)

missingval(stack::NCDstack) = missing

# Base methods

Base.getindex(s::NCDstack, key::Key, i1::Integer, I::Integer...) =
    ncapply(filename(s, key)) do dataset
        key = string(key)
        var = dataset[key]
        _window = maybewindow2indices(var, dims(dataset, key), window(s))
        ncread(var, _window, i1, I...)
    end
Base.getindex(s::NCDstack, key::Key, I::Union{Colon,Integer,AbstractArray}...) =
    ncapply(filename(s, key)) do dataset
        key = string(key)
        var = dataset[key]
        _dims = dims(dataset, key)
        _window = maybewindow2indices(var, _dims, window(s))
        _dims, _refdims = slicedims(slicedims(_dims, refdims(s), _window)..., I)
        A = ncread(var, _window, I...)
        GeoArray(A, _dims, _refdims, key, metadata(s), missingval(s))
    end

Base.keys(stack::NCDstack{<:AbstractString}) =
    Tuple(Symbol.(safeapply(nondimkeys, stack, source(stack))))

Base.copy!(dst::AbstractGeoArray, src::NCDstack, key::Key) =
    copy!(data(dst), src, key)
Base.copy!(dst::AbstractArray, src::NCDstack, key) =
    ncapply(filename(src)) do dataset
        key = string(key)
        var = dataset[key]
        _window = maybewindow2indices(var, dims(dataset, key), window(src))
        copy!(dst, readwindowed(var, _window))
    end


"""
    Base.write(filename::AbstractString, ::Type{NCDstack}, s::AbstractGeoStack)

Write an NCDstack to a single netcdf file, using NCDatasets.jl.

Currently `Dimension` metadata is not handled, and array metadata from other
array types is ignored.
"""
Base.write(filename::AbstractString, ::Type{NCDstack}, s::AbstractGeoStack) = begin
    dataset = NCDatasets.Dataset(filename, "c"; attrib=val(metadata(s)))
    try
        map(key -> ncwritevar!(dataset, s[key]), keys(s))
    finally
        close(dataset)
    end
end

# DimensionalData methods for NCDatasets types ###############################

dims(dataset::NCDatasets.Dataset) = dims(dataset, first(nondimkeys(dataset)))
dims(dataset::NCDatasets.Dataset, key::Key) = begin
    v = dataset[string(key)]
    dims = []
    for (i, dimname) in enumerate(NCDatasets.dimnames(v))
        if haskey(dataset, dimname)
            dvar = dataset[dimname]
            # Find the matching dimension constructor. If its an unknown name use
            # the generic Dim with the dim name as type parameter
            dimtype = get(dimmap, dimname, Dim{Symbol(dimname)})
            # Order: data is always forwards, we check the index order
            order = dvar[end] > dvar[1] ? Ordered(Forward(), Forward(), Forward()) :
                                          Ordered(Reverse(), Forward(), Reverse())

            # Assume the locus is at the center of the cell if boundaries aren't provided.
            # http://cfconventions.org/cf-conventions/cf-conventions.html#cell-boundaries

            if eltype(dvar) isa Number
                beginhalfcell = abs((dvar[2] - dvar[1]) * 0.5)
                endhalfcell = abs((dvar[end] - dvar[end-1]) * 0.5)
                bounds = if isrev(indexorder(order))
                    dvar[end] - endhalfcell, dvar[1] + beginhalfcell
                else
                    dvar[1] - beginhalfcell, dvar[end] + endhalfcell
                end
                locus = (dimtype <: TimeDim) ? Start() : Center()
                mode = Sampled(order, Irregular(bounds), Intervals(locus))
            else
                mode = Sampled(order, Irregular(), Points())
            end

            meta = metadata(dvar)
            # Add the dim containing the dimension var array
            push!(dims, dimtype(dvar[:], mode, meta))
        else
            # The var doesn't exist. Maybe its `complex` or some other marker,
            # so make it a custom `Dim` with `NoIndex`
            push!(dims, Dim{Symbol(dimname)}(1:size(v, i), NoIndex(), nothing))
        end
    end
    (dims...,)
end

metadata(dataset::NCDatasets.Dataset) = NCDstackMetadata(Dict{String,Any}(dataset.attrib))
metadata(dataset::NCDatasets.Dataset, key::Key) = metadata(dataset[string(key)])
metadata(var::NCDatasets.CFVariable) = NCDarrayMetadata(Dict{String,Any}(var.attrib))
metadata(var::NCDatasets.CFVariable, stackmetadata::NCDstackMetadata) = begin
    md = metadata(var)
    md["dataset"] = stackmetadata
    md
end

missingval(var::NCDatasets.CFVariable{<:Union{Missing}}) = missing

# crs(dataset::NCDatasets.Dataset)
# crs(var::NCDatasets.CFVariable) = NCDmetadata(Dict(var.attrib))


# Utils ########################################################################

# CF standards don't enforce dimension names.
# But these are common, and should take care of most dims.
const dimmap = Dict("lat" => Lat,
                    "latitude" => Lat,
                    "lon" => Lon,
                    "long" => Lon,
                    "longitude" => Lon,
                    "time" => Ti,
                    "lev" => Vert,
                    "level" => Vert,
                    "vertical" => Vert,
                    "x" => X,
                    "y" => Y,
                    "z" => Z,
                   )

ncapply(f, path::String) = NCDatasets.Dataset(f, path)

ncread(A, window::Tuple{}) = Array(A)
ncread(A, window::Tuple{}, I...) = A[I...]
ncread(A, window, I...) = A[Base.reindex(window, I)...]
ncread(A, window) = A[window...]

nondimkeys(dataset) = begin
    dimkeys = keys(dataset.dim)
    removekeys = if "bnds" in dimkeys
        dimkeys = setdiff(dimkeys, ("bnds",))
        boundskeys = map(k -> dataset[k].attrib["bounds"], dimkeys)
        union(dimkeys, boundskeys)
    else
        dimkeys
    end
    setdiff(keys(dataset), removekeys)
end

# Add a var array to a dataset before writing it.
ncwritevar!(dataset, A::AbstractGeoArray{T}) where T = begin
    A = reorderindex(A, Forward()) |>
        a -> reorderrelation(a, Forward())
    if ismissing(missingval(A))
        # TODO default _FillValue for Int?
        fillvalue = get(metadata(A), "_FillValue", NaN)
        A = replace_missing(A, convert(T, fillvalue))
    end
    # Define required dims
    for dim in dims(A)
        key = lowercase(name(dim))
        haskey(dataset.dim, key) && continue
        index = [val(dim)...]
        md = metadata(dim)
        attribvec = [] #md isa Nothing ? [] : [val(md)...]
        defDim(dataset, key, length(index))
        println("writing key: ", key, " of type: ", eltype(index))
        defVar(dataset, key, index, (key,); attrib=attribvec)
    end
    # TODO actually convert the metadata type
    attrib = if metadata isa NCDarrayMetadata
        deepcopy(val(metadata(A)))
    else
        Dict()
    end
    # Remove stack metdata if it is attached
    pop!(attrib, "dataset", nothing)
    # Set missing value
    if !ismissing(missingval(A))
        attrib["_FillValue"] = convert(T, missingval(A))
    end
    key = name(A)
    println("writing key: ", key, " of type: ", T)
    dimnames = lowercase.(name.(dims(A)))
    attribvec = [attrib...]
    var = defVar(dataset, key, eltype(A), dimnames; attrib=attribvec)
    var[:] = data(A)
end
