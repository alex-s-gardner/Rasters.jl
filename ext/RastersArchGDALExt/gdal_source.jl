const AG = ArchGDAL

const GDAL_X_ORDER = ForwardOrdered()
const GDAL_Y_ORDER = ReverseOrdered()

const GDAL_X_LOCUS = Start()
const GDAL_Y_LOCUS = Start()

# drivers supporting the gdal Create() method to directly write to disk
const GDAL_DRIVERS_SUPPORTING_CREATE = ("GTiff", "HDF4", "KEA", "netCDF", "PCIDSK", "Zarr", "MEM"#=...=#) 

# order is equal to https://gdal.org/user/virtual_file_systems.html
const GDAL_VIRTUAL_FILESYSTEMS = "/vsi" .* (
    "zip",
    "tar",
    "gzip",
    "7z",
    "rar",
    "curl",
    "curl_streaming",
    "s3",
    "s3_streaming",
    "gs",
    "gs_streaming",
    "az",
    "az_streaming",
    "adls",
    "oss",
    "oss_streaming",
    "swift",
    "swift_streaming",
    "hdfs",
    "webhdfs",
    "stdin",
    "stdout",
    "mem",
    "subfile",
    "sparse",
    )

# Array ########################################################################

function RA.FileArray(raster::AG.RasterDataset{T}, filename; kw...) where {T}
    eachchunk, haschunks = DA.eachchunk(raster), DA.haschunks(raster)
    RA.FileArray{GDALsource,T,3}(filename, size(raster); eachchunk, haschunks, kw...)
end

RA.cleanreturn(A::AG.RasterDataset) = Array(A)
RA.haslayers(::Type{GDALsource}) = false

"""
    Base.write(filename::AbstractString, ::Type{GDALsource}, A::AbstractRaster; force=false, kw...)

Write a `Raster` to file using GDAL.

# Keywords

- `driver`: A GDAL driver name or a GDAL driver retrieved via `ArchGDAL.getdriver(drivername)`. Guessed from the filename extension by default.
- `options::Dict{String,String}`: A dictionary containing the dataset creation options passed to the driver. For example: `Dict("COMPRESS"=>"DEFLATE")`\n
  Valid options for the drivers can be looked up here: https://gdal.org/drivers/raster/index.html

Returns `filename`.
"""
function Base.write(
    filename::AbstractString, ::Type{GDALsource}, A::AbstractRaster{T,2}; 
    force=false, verbose=true, kw...
) where T
    RA.check_can_write(filename, force)
    all(hasdim(A, (X, Y))) || error("Array must have Y and X dims")

    correctedA = _maybe_correct_to_write(A)
    nbands = 1
    _write(filename, correctedA, nbands; kw...)
end
function Base.write(
    filename::AbstractString, ::Type{GDALsource}, A::AbstractRaster{T,3}; 
    force=false, verbose=true, kw...
) where T
    RA.check_can_write(filename, force)
    all(hasdim(A, (X, Y))) || error("Array must have Y and X dims")
    hasdim(A, Band()) || error("Must have a `Band` dimension to write a 3-dimensional array")

    correctedA = _maybe_correct_to_write(A)
    nbands = size(correctedA, Band())
    _write(filename, correctedA, nbands; kw...)
end

function RA.create(filename, ::Type{GDALsource}, T::Type, dims::DD.DimTuple;
    missingval=nothing, metadata=nothing, name=nothing, keys=(name,),
    driver="", lazy=true, options=Dict{String,String}(), _block_template=nothing
)
    driver = _check_driver(filename, driver)
    if !(keys isa Nothing || keys isa Symbol) && length(keys) > 1
        throw(ArgumentError("GDAL cant write more than one layer per file, but keys $keys have $(length(keys))"))
    end
    x, y = map(DD.dims(dims, (XDim, YDim)), (GDAL_X_ORDER, GDAL_Y_ORDER)) do d, o
        reorder(lookup(d) isa NoLookup ? set(d, Sampled) : d, o)
    end
    T = Missings.nonmissingtype(T)

    if ismissing(missingval)
        missingval = RA._writeable_missing(T)
    end

    if hasdim(dims, Band)
        b = DD.dims(dims, Band)
        nbands = length(b)
        newdims = (x, y, b)
    else
        nbands = 1
        newdims = (x, y)
    end

    kw = (width=length(x), height=length(y), nbands=nbands, dtype=T)
    options_vec = _process_options(driver, options; _block_template)
    gdaldriver = driver isa String ? AG.getdriver(driver) : driver
    if driver in GDAL_DRIVERS_SUPPORTING_CREATE
        AG.create(filename; driver=gdaldriver, options=options_vec, kw...) do ds
            _set_dataset_properties!(ds, newdims, missingval)
        end
    else
        tif_options_vec = _process_options("GTiff", Dict{String,String}(); _block_template)
        # Create a tif and copy it to `filename`, as ArchGDAL.create
        # does not support direct creation of ASCII etc. rasters
        ArchGDAL.create(tempname() * ".tif"; driver=AG.getdriver("GTiff"), options=tif_options_vec, kw...) do ds
            _set_dataset_properties!(ds, newdims, missingval)
            target_ds = AG.copy(ds; filename=filename, driver=gdaldriver, options=options_vec)
            AG.destroy(target_ds)
        end
    end
    if hasdim(dims, Band)
        return Raster(filename; source=GDALsource, lazy)
    else
        return view(Raster(filename; source=GDALsource, lazy), Band(1))
    end
end

function RA._open(f, ::Type{GDALsource}, filename::AbstractString; write=false, kw...)
    # Check the file actually exists because GDALs error is unhelpful
    if !isfile(filename)
        # Allow gdal virtual file systems
        # the respective string is prepended to the data source,
        # e.g. /vsicurl/https://...
        if !(length(filename) >= 8 && any(startswith.(filename, GDAL_VIRTUAL_FILESYSTEMS)))
            # Check if the filename is a url
            if RA._isurl(filename)
                filename = "/vsicurl/" * filename
            else
                # Throw our own error that the file does not exist
                RA._filenotfound_error(filename)
            end
        end
    end
    if write 
        # Pass the OF_UPDATE flag to GDAL
        AG.readraster(RA.cleanreturn ∘ f, filename; flags=AG.OF_UPDATE)
    else
        # Otherwise just read
        AG.readraster(RA.cleanreturn ∘ f, filename)
    end
end
RA._open(f, ::Type{GDALsource}, ds::AG.RasterDataset; kw...) = RA.cleanreturn(f(ds))


# DimensionalData methods for ArchGDAL types ###############################

# These methods are type piracy on DimensionalData/ArchGDAL and may have to move some day

# We allow passing in crs and mappedcrs manually
function DD.dims(raster::AG.RasterDataset, crs=nothing, mappedcrs=nothing)
    gt = try
        AG.getgeotransform(raster)
    catch
        GDAL_EMPTY_TRANSFORM
    end
    xsize, ysize = size(raster)
    nbands = AG.nraster(raster)
    bandnames = _bandnames(raster, nbands)
    band = if all(==(""), bandnames)
        Band(Categorical(1:nbands; order=ForwardOrdered()))
    else
        Band(Categorical(bandnames; order=Unordered()))
    end

    crs = crs isa Nothing ? Rasters.crs(raster) : crs
    xy_metadata = metadata(raster)

    # Output Sampled index dims when the transformation is lat/lon alligned,
    # otherwise use Transformed index, with an affine map.
    if _isalligned(gt)
        xstep = gt[GDAL_WE_RES]
        if xstep > 0 
            xmin = gt[GDAL_TOPLEFT_X]
            xmax = gt[GDAL_TOPLEFT_X] + xstep * (xsize - 1)
            xorder = ForwardOrdered()
        else
            xmin = gt[GDAL_TOPLEFT_X] + xstep 
            xmax = gt[GDAL_TOPLEFT_X] + xstep * xsize
            xorder = ReverseOrdered()
        end
        xindex = LinRange(xmin, xmax, xsize)
        xorder = xstep > 0 ? ForwardOrdered() : ReverseOrdered()

        ystep = gt[GDAL_NS_RES] # A negative number
        if ystep > 0 
            ymax = gt[GDAL_TOPLEFT_Y]
            ymin = gt[GDAL_TOPLEFT_Y] + ystep * (ysize - 1)
            yorder = ForwardOrdered()
        else
            ymax = gt[GDAL_TOPLEFT_Y] + ystep
            ymin = gt[GDAL_TOPLEFT_Y] + ystep * ysize
            yorder = ReverseOrdered()
        end
        yindex = LinRange(ymax, ymin, ysize)

        # Spatial data defaults to area/inteval
        xsampling, ysampling = if _gdalmetadata(raster.ds, "AREA_OR_POINT") == "Point"
            Points(), Points()
        else
            # GeoTiff uses the "pixelCorner" convention
            Intervals(GDAL_X_LOCUS), Intervals(GDAL_Y_LOCUS)
        end

        xlookup = Projected(xindex;
            order=xorder,
            span=Regular(step(xindex)),
            sampling=xsampling,
            metadata=xy_metadata,
            crs=crs,
            mappedcrs=mappedcrs,
        )
        ylookup = Projected(yindex;
            order=yorder,
            sampling=ysampling,
            # Use the range step as is will be different to ystep due to float error
            span=Regular(step(yindex)),
            metadata=xy_metadata,
            crs=crs,
            mappedcrs=mappedcrs,
        )
        x = X(xlookup)
        y = Y(ylookup)

        DD.format((x, y, band), map(Base.OneTo, (xsize, ysize, nbands)))
    else
        affinemap = RA.geotransform2affine(gt)
        x = X(RA.AffineProjected(affinemap; crs, mappedcrs, metadata=xy_metadata, dim=X(), paired_lookup=Base.OneTo(ysize)))
        y = Y(RA.AffineProjected(affinemap; crs, mappedcrs, metadata=xy_metadata, dim=Y(), paired_lookup=Base.OneTo(xsize)))

        DD.format((x, y, band), map(Base.OneTo, (xsize, ysize, nbands)))
    end
end

function DD.metadata(raster::AG.RasterDataset, args...)
    band = AG.getband(raster.ds, 1)
    # color = AG.getname(AG.getcolorinterp(band))
    scale = AG.getscale(band)
    offset = AG.getoffset(band)
    # norvw = AG.noverview(band)
    units = AG.getunittype(band)
    filelist = AG.filelist(raster)
    metadata = RA._metadatadict(GDALsource, "scale"=>scale, "offset"=>offset)
    if units == ""
        metadata["units"] = units
    end
    if length(filelist) > 0
        metadata["filepath"] = first(filelist)
    end
    return metadata
end

# Rasters methods for ArchGDAL types ##############################

# Create a Raster from a dataset
RA.Raster(ds::AG.Dataset; kw...) = Raster(AG.RasterDataset(ds); kw...)
function RA.Raster(ds::AG.RasterDataset;
    crs=crs(ds), 
    mappedcrs=nothing,
    dims=dims(ds, crs, mappedcrs),
    refdims=(), 
    name=Symbol(""),
    metadata=metadata(ds),
    missingval=missingval(ds),
    lazy=false,
    dropband=false
)
    args = dims, refdims, name, metadata, missingval
    filelist = AG.filelist(ds)
    raster = if lazy && length(filelist) > 0
        filename = first(filelist)
        A = Raster(FileArray(ds, filename), args...)
    else
        Raster(Array(ds), args...)
    end
    return dropband ? RA._drop_single_band(raster, lazy) : raster
end

function RA.missingval(rasterds::AG.RasterDataset, args...)
    # All bands have the same missingval in GDAL
    band = AG.getband(rasterds.ds, 1)
    # GDAL will set this
    hasnodataval = Ref(Cint(0))
    # Int64 and UInt64 need special casing in GDAL
    nodataval = if eltype(rasterds) == Int64
        AG.GDAL.gdalgetrasternodatavalueasint64(band, hasnodataval)
    elseif eltype(rasterds) == UInt64
        AG.GDAL.gdalgetrasternodatavalueasuint64(band, hasnodataval)
    else
        AG.GDAL.gdalgetrasternodatavalue(band, hasnodataval)
    end
    # If there was a missingval, clean it and use it.
    # Otherwise set missingval to `nothing`, meaning there isnt one
    if Bool(hasnodataval[])
        return _missingval_from_gdal(eltype(band), nodataval)
    else
        return nothing
    end
end

# GDAL always returns well known text
function RA.crs(raster::AG.RasterDataset, args...)
    WellKnownText(GeoFormatTypes.CRS(), string(AG.getproj(raster.ds)))
end

# ArchGDAL methods for Rasters types ####################################

# Extend ArchGDAL RasterDataset and Dataset to accept AbstractRaster as input
function AG.Dataset(f::Function, A::AbstractRaster; kw...)
    AG.RasterDataset(A; kw...) do rds
        f(rds.ds)
    end
end
function AG.RasterDataset(f::Function, A::AbstractRaster; 
    filename=nothing, driver="",
)
    driver = _check_driver(filename, driver)
    all(hasdim(A, (X, Y))) || throw(ArgumentError("`AbstractRaster` must have both an `X` and `Y` to be converted to an ArchGDAL `Dataset`"))
    if ndims(A) === 3
        thirddim = otherdims(A, (X, Y))[1]
        thirddim isa Band || throw(ArgumentError("ArchGDAL can't handle $(basetypeof(thirddim)) dims - only X, Y, and Band"))
    elseif ndims(A) > 3
        throw(ArgumentError("ArchGDAL can only accept 2 or 3 dimensional arrays"))
    end

    A_m = RA._maybe_use_type_missingval(A, GDALsource)
    A_p = _maybe_permute_to_gdal(A_m)
    kw = (;
        width=length(DD.dims(A_p, X)),
        height=length(DD.dims(A_p, Y)),
        nbands=hasdim(A_p, Band) ? size(A_p, Band()) : 1,
        dtype=eltype(A_p),
    )
    if filename == nothing 
        filename = ""
    end
    _create_with_driver(filename, driver, kw; _block_template=A_p) do dataset
        _set_dataset_properties!(dataset, dims(A_p), missingval(A_p))
        rds = AG.RasterDataset(dataset)
        open(A_p) do a
            rds .= parent(a)
        end
        f(rds)
    end
end

# Utils ########################################################################

# Sometimes GDAL stores the `missingval` in the wrong type, so fix it.
_missingval_from_gdal(T::Type{<:AbstractFloat}, x::Real) = convert(T, x)
function _missingval_from_gdal(T::Type{<:Integer}, x::AbstractFloat)
    if trunc(x) === x
        convert(T, x)
    else
        @warn "Missing value $x can't be converted to array eltype $T. `missingval` set to `nothing`"
        nothing
    end
end
function _missingval_from_gdal(T::Type{<:Integer}, x::Integer)
    if x >= typemin(T) && x <= typemax(T)
        convert(T, x)
    else
        @warn "Missing value $x can't be converted to array eltype $T. `missingval` set to `nothing`"
        nothing
    end
end
_missingval_from_gdal(T, x) = x

# Fix array and dimension configuration before writing with GDAL
_maybe_correct_to_write(A) = _maybe_correct_to_write(lookup(A, X()), A)
_maybe_correct_to_write(lookup, A) = A
function _maybe_correct_to_write(lookup::Union{AbstractSampled,NoLookup}, A)
    _maybe_permute_to_gdal(A) |>
        a -> RA.noindex_to_sampled(a) |>
        a -> reorder(a, (X(GDAL_X_ORDER), Y(GDAL_Y_ORDER)))
end

# Write a Raster to disk using GDAL
function _write(filename, A::AbstractRaster, nbands; driver="", kw...)
    A = RA._maybe_use_type_missingval(A, GDALsource)
    create_kw = (width=size(A, X()), height=size(A, Y()), nbands=nbands, dtype=eltype(A))
    _create_with_driver(filename, driver, create_kw; _block_template=A, kw...) do dataset
        _set_dataset_properties!(dataset, A)
        rds = AG.RasterDataset(dataset)
        open(A; write=true) do O
            rds .= parent(O)
        end
    end

    return filename
end

_check_driver(filename::Nothing, driver) = "MEM"
function _check_driver(filename::AbstractString, driver)
    if isempty(driver) 
        driver = AG.extensiondriver(filename)
        if driver == "COG"
            driver = "GTiff"
        end
    end
    return driver
end

# Handle creating a dataset with any driver, 
# applying the function `f` to the created dataset
function _create_with_driver(f, filename, driver, create_kw;
    options=Dict{String,String}(), _block_template=nothing
)
    driver = _check_driver(filename, driver)
    options_vec = _process_options(driver, options; _block_template)
    gdaldriver = driver isa String ? AG.getdriver(driver) : driver
    if AG.shortname(gdaldriver) in GDAL_DRIVERS_SUPPORTING_CREATE
        AG.create(filename; driver=gdaldriver, create_kw..., options=options_vec) do dataset
            f(dataset)
        end
    else
        # Create a memory object and copy it to disk, as ArchGDAL.create
        # does not support direct creation of ASCII etc. rasters
        ArchGDAL.create(""; driver=AG.getdriver("MEM"), create_kw...) do dataset
            result = f(dataset)
            # This `copy` copies _to disk_
            AG.copy(dataset; filename=filename, driver=gdaldriver, options=options_vec) |> AG.destroy
            result
        end
    end
end

# Convert a Dict of options to a Vector{String} for GDAL
function _process_options(driver::String, options::Dict;
    _block_template=nothing
)
    # Get the GDAL driver object
    gdaldriver = AG.getdriver(driver)

    # set default compression
    if driver != "MEM" && !("COMPRESS" in keys(options)) && AG.validate(gdaldriver, ["COMPRESS=ZSTD"])
        options["COMPRESS"] = "ZSTD"
    end

    # the goal is to set write block sizes that correspond to eventually blocked reads
    # creation options are driver dependent

    if !isnothing(_block_template) && DA.haschunks(_block_template) == DA.Chunked()
        block_x, block_y = string.(DA.max_chunksize(DA.eachchunk(_block_template)))
        if driver == "GTiff"
            # dont overwrite user specified values
            if !("BLOCKXSIZE" in keys(options))
                options["BLOCKXSIZE"] = block_x
            end
            if !("BLOCKYSIZE" in keys(options))
                options["BLOCKYSIZE"] = block_y
            end
        elseif driver == "COG"
            if !("BLOCKSIZE" in keys(options))
                # cog only supports square blocks
                # if the source already has square blocks, use them
                # otherwise use the driver default
                options["BLOCKSIZE"] = block_x == block_y ? block_x : 512
            end
        end
    end
    # if the input is unchunked we just use the driver defaults
    options_vec = ["$(uppercase(k))=$(uppercase(string(v)))" for (k,v) in options]

    invalid_options = String[]
    for option in options_vec
        if !AG.validate(gdaldriver, [option])
            push!(invalid_options, option)
        end
    end

    if length(invalid_options) > 0
        throw(ArgumentError("Invalid driver creation option(s) detected.
        Please check them carefully with the documentation at https://gdal.org/drivers/raster/index.html.
        $invalid_options"))
    end

    return options_vec
end

# Bands can have text names, but usually dont
function _bandnames(rds::AG.RasterDataset, nbands=AG.nraster(rds))
    map(1:nbands) do b
        AG.getband(rds.ds, b) do band
            AG.GDAL.gdalgetdescription(band.ptr)
        end
    end
end

function _gdalmetadata(dataset::AG.Dataset, key)
    meta = AG.metadata(dataset)
    regex = Regex("$key=(.*)")
    i = findfirst(f -> occursin(regex, f), meta)
    if i isa Nothing
        return ""
    else
        return match(regex, meta[i])[1]
    end
end

# Set the properties of an ArchGDAL Dataset to match
# the dimensions and missingval of a Raster
_set_dataset_properties!(ds::AG.Dataset, A) = 
    _set_dataset_properties!(ds, dims(A), missingval(A))
function _set_dataset_properties!(dataset::AG.Dataset, dims::Tuple, missingval)
    # Convert the dimensions to `Projected` if they are `Converted`
    # This allows saving NetCDF to Tiff
    # Set the index loci to the start of the cell for the lat and lon dimensions.
    # NetCDF or other formats use the center of the interval, so they need conversion.
    x = DD.maybeshiftlocus(GDAL_X_LOCUS, convertlookup(Projected, DD.dims(dims, X)))
    y = DD.maybeshiftlocus(GDAL_Y_LOCUS, convertlookup(Projected, DD.dims(dims, Y)))
    # Convert crs to WKT if it exists
    if !isnothing(crs(x))
        AG.setproj!(dataset, convert(String, convert(WellKnownText, crs(x))))
    end
    # Get the geotransform from the updated lat/lon dims and write
    AG.setgeotransform!(dataset, RA.dims2geotransform(x, y))

    if !isnothing(missingval)
        bands = hasdim(dims, Band) ? axes(DD.dims(dims, Band), 1) : 1
        for i in bands
            rasterband = AG.getband(dataset, i)
            if missingval isa Int64
                AG.GDAL.gdalsetrasternodatavalueasint64(rasterband, missingval)
            elseif missingval isa UInt64
                AG.GDAL.gdalsetrasternodatavalueasuint64(rasterband, missingval)
            else
                AG.GDAL.gdalsetrasternodatavalue(rasterband, missingval)
            end
        end
    end

    # Write band labels if they are not Integers.
    if hasdim(dims, Band)
        bandlookup = DD.lookup(dims, Band)
        if !(eltype(bandlookup) <: Integer)
            for i in eachindex(bandlookup)
                AG.getband(dataset, i) do band
                    AG.GDAL.gdalsetdescription(band.ptr, string(bandlookup[i]))
                end
            end
        end
    end

    return dataset
end

# Detect the driver string from the extention
_extensiondriver(filename::Nothing) = "MEM"
function _extensiondriver(filename::AbstractString)
    # TODO move this check to ArchGDAL
    if filename == "/vsimem/tmp" 
        "MEM" 
    elseif splitext(filename)[2] == ".tif"
        # Force GTiff as the default for .tif because COG cannot do `create` yet
        "GTiff"
    else
        AG.extensiondriver(filename)
    end
end

# Permute dims unless they match the normal GDAL dimension order
_maybe_permute_to_gdal(A) = _maybe_permute_to_gdal(A, DD.dims(A, (X, Y, Band)))
_maybe_permute_to_gdal(A, dims::Tuple) = A
_maybe_permute_to_gdal(A, dims::Tuple{<:XDim,<:YDim,<:Band}) = permutedims(A, dims)
_maybe_permute_to_gdal(A, dims::Tuple{<:XDim,<:YDim}) = permutedims(A, dims)

_maybe_permute_from_gdal(A, dims::Tuple) = permutedims(A, dims)
_maybe_permute_from_gdal(A, dims::Tuple{<:XDim,<:YDim,<:Band}) = A
_maybe_permute_from_gdal(A, dims::Tuple{<:XDim,<:YDim}) = A

#= Geotranforms ########################################################################

See https://lists.osgeo.org/pipermail/gdal-dev/2011-July/029449.html

"In the particular, but common, case of a “north up” image without any rotation or
shearing, the georeferencing transform takes the following form" :
adfGeoTransform[0] /* top left x */
adfGeoTransform[1] /* w-e pixel resolution */
adfGeoTransform[2] /* 0 */
adfGeoTransform[3] /* top left y */
adfGeoTransform[4] /* 0 */
adfGeoTransform[5] /* n-s pixel resolution (negative value) */
=#

# These function are defined in ext/RastersCoordinateTransformationsExt.jl
const USING_COORDINATETRANSFORMATIONS_MESSAGE = 
    "Run `using CoordinateTransformations` to load affine transformed rasters"

function RA.dims2geotransform(x::XDim, y::YDim)
    gt = zeros(6)
    gt[GDAL_TOPLEFT_X] = first(x)
    gt[GDAL_WE_RES] = step(x)
    gt[GDAL_ROT1] = zero(eltype(gt))
    gt[GDAL_TOPLEFT_Y] = first(y) - step(y)
    gt[GDAL_ROT2] = zero(eltype(gt))
    gt[GDAL_NS_RES] = step(y)
    return gt
end
RA.geotransform2affine(gt) = error(USING_COORDINATETRANSFORMATIONS_MESSAGE)
RA.affine2geotransform(am) = error(USING_COORDINATETRANSFORMATIONS_MESSAGE)

_isalligned(geotransform) = geotransform[GDAL_ROT1] == 0 && geotransform[GDAL_ROT2] == 0

# precompilation
# function _precompile(::Type{GDALsource})
#     ccall(:jl_generating_output, Cint, ()) == 1 || return nothing

#     for T in (Any, UInt8, UInt16, Int16, UInt32, Int32, Float32, Float64)
#         DS = AG.RasterDataset{T,AG.Dataset}
#         precompile(crs, (DS,))
#         precompile(Rasters.FileArray, (DS, String))
#         precompile(dims, (DS,))
#         precompile(dims, (DS,WellKnownText{GeoFormatTypes.CRS},Nothing))
#         precompile(dims, (DS,WellKnownText{GeoFormatTypes.CRS},EPSG))
#         precompile(dims, (DS,WellKnownText{GeoFormatTypes.CRS},ProjString))
#         precompile(dims, (DS,WellKnownText{GeoFormatTypes.CRS},WellKnownText{GeoFormatTypes.CRS}))
#         precompile(metadata, (DS, key))
#         precompile(missingval, (DS, key))
#         precompile(Raster, (DS, key))
#         precompile(Raster, (DS, String, Nothing))
#         precompile(Raster, (DS, String, Symbol))
#     end
# end

# _precompile(GRDsource)
