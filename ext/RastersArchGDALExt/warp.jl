"""
    warp(A::AbstractRaster, flags::Dict; kw...)

Gives access to the GDALs `gdalwarp` method given a `Dict` of 
`flag => value` arguments that can be converted to strings, or vectors
where multiple space-separated arguments are required.

Arrays with additional dimensions not handled by GDAL (other than `X`, `Y`, `Band`)
are sliced, warped, and then combined to match the original array dimensions. 
These slices will *not* be written to disk and loaded lazily at this stage -
you will need to do that manually if required.

See [the gdalwarp docs](https://gdal.org/programs/gdalwarp.html) for a list of arguments.

# Keywords

$FILENAME_KEYWORD
$SUFFIX_KEYWORD

Any additional keywords are passed to `ArchGDAL.Dataset`.

## Example

This simply resamples the array with the `:tr` (output file resolution) and `:r`
flags, giving us a pixelated version:

```jldoctest
using Rasters, RasterDataSources, Plots
A = Raster(WorldClim{Climate}, :prec; month=1)
a = plot(A)

flags = Dict(
    :tr => [2.0, 2.0],
    :r => :near,
)
b = plot(warp(A, flags))

savefig(a, "docs/build/warp_example_before.png");
savefig(b, "docs/build/warp_example_after.png"); nothing

# output

```

### Before `warp`:

![before warp](warp_example_before.png)

### After `warp`:

![after warp](warp_example_after.png)

In practise, prefer [`resample`](@ref) for this. But `warp` may be more flexible.

$EXPERIMENTAL
"""
function warp(A::AbstractRaster, flags::Dict; filename=nothing, kw...)
    odims = otherdims(A, (X, Y, Band))
    if length(odims) > 0
        isnothing(filename) || throw(ArgumentError("Cannot currently write dimensions other than X/Y/Band to disk using `filename` keyword. Make a Rasters.jl github issue if you need this."))
        # Handle dimensions other than X, Y, Band
        slices = slice(A, odims)
        warped = map(A -> _warp(A, flags; kw...), slices)
        return combine(warped, odims)
    else
        return _warp(A, flags; filename, kw...)
    end
end
function warp(st::AbstractRasterStack, flags::Dict; filename=nothing, suffix=keys(st), kw...)
    RA.mapargs((A, s) -> warp(A, flags; filename, suffix=s), st, suffix; kw...)
end

function _warp(A::AbstractRaster, flags::Dict; filename=nothing, suffix="", kw...)
    filename = RA._maybe_add_suffix(filename, suffix)
    flagvect = reduce([flags...]; init=[]) do acc, (key, val)
        append!(acc, String[_asflag(key), _stringvect(val)...])
    end
    tempfile = isnothing(filename) ? nothing : tempname() * ".tif"
    warp_kw = isnothing(filename) || filename == "/vsimem/tmp" ? () : (; dest=filename)
    warped = AG.Dataset(A; filename=tempfile, kw...) do dataset
        AG.gdalwarp([dataset], flagvect; warp_kw...) do warped
            # Read the raster lazily, dropping Band if there is none in `A`
            raster = Raster(warped; lazy=true, dropband=!hasdim(A, Band()))
            # Either read the MEM dataset, or get the filename as a FileArray
            # And permute the dimensions back to what they were in A
            p_raster = _maybe_permute_from_gdal(raster, dims(A))
            # Either read the MEM dataset to an Array, or keep a filename base raster lazy
            return isnothing(filename) ? read(p_raster) : p_raster
        end
    end
end

_asflag(x) = string(x)[1] == '-' ? x : string("-", x)

_stringvect(x::AbstractVector) = Vector(string.(x))
_stringvect(x::Tuple) = [map(string, x)...]
_stringvect(x) = [string(x)]

