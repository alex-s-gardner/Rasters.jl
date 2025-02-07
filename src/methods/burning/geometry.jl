# _burn_geometry!
# Fill a raster with `fill` where it interacts with a geometry.
function burn_geometry!(B::AbstractRaster, data::T; kw...) where T
    if Tables.istable(T)
        geomcolname = first(GI.geometrycolumns(data))::Symbol
        geoms = Tables.getcolumn(data, geomcolname)
        _burn_geometry!(B, nothing, geoms; kw...)
    else
        _burn_geometry!(B, GI.trait(data), data; kw...)
    end
    return B
end

# This feature filling is simplistic in that it does not use any feature properties.
# This is suitable for masking. See `rasterize` for a version using properties.
_burn_geometry!(B, obj; kw...) = _burn_geometry!(B, GI.trait(obj), obj; kw...)::Bool
function _burn_geometry!(B::AbstractRaster, ::GI.AbstractFeatureTrait, feature; kw...)::Bool
    _burn_geometry!(B, GI.geometry(feature); kw...)
end
function _burn_geometry!(B::AbstractRaster, ::GI.AbstractFeatureCollectionTrait, fc; kw...)::Bool
    geoms = (GI.geometry(f) for f in GI.getfeature(fc))
    _burn_geometry!(B, nothing, geoms; kw...)
end
# Where geoms is an iterator
function _burn_geometry!(B::AbstractRaster, trait::Nothing, geoms; 
    collapse::Union{Bool,Nothing}=nothing, lock=SectorLocks(), verbose=true, progress=true, threaded=true,
    allocs=_burning_allocs(B; threaded), kw...
)::Bool
    range = _geomindices(geoms)
    burnchecks = _alloc_burnchecks(range)
    if isnothing(collapse) || collapse
        _run(range, threaded, progress, "") do i
            geom = _getgeom(geoms, i)
            ismissing(geom) && return nothing
            a = _get_alloc(allocs)
            B1 = a.buffer
            burnchecks[i] = _burn_geometry!(B1, geom; allocs=a, lock, kw...)
            return nothing
        end
        if allocs isa Allocs
            _do_broadcast!(|, B, allocs.buffer)
        else
            buffers = map(a -> a.buffer, allocs)
            _do_broadcast!(|, B, buffers...)
        end
    else
        _run(range, threaded, progress, "") do i
            geom = _getgeom(geoms, i)
            ismissing(geom) && return nothing
            B1 = view(B, Dim{:geometry}(i))
            a = _get_alloc(allocs)
            burnchecks[i] = _burn_geometry!(B1, geom; allocs=a, lock, kw...)
            return nothing
        end
    end
    
    _set_burnchecks(burnchecks, metadata(B), verbose)
    return false
end

function _burn_geometry!(B::AbstractRaster, ::GI.AbstractGeometryTrait, geom; 
    shape=nothing, verbose=true, boundary=:center, allocs=nothing, kw...
)::Bool
    hasburned = false
    GI.npoint(geom) > 0 || return hasburned
    # Use the specified shape or detect it
    shape = shape isa Symbol ? shape : _geom_shape(geom)
    if shape === :point
        hasburned = _fill_point!(B, geom; fill=true, shape, kw...)
    elseif shape === :line
        n_on_line = _burn_lines!(B, geom; shape, kw...)
        hasburned = n_on_line > 0
    elseif shape === :polygon
        # Get the extents of the geometry and array
        geomextent = _extent(geom)
        arrayextent = Extents.extent(B, DEFAULT_POINT_ORDER)
        # Only fill if the gemoetry bounding box overlaps the array bounding box
        if !Extents.intersects(geomextent, arrayextent) 
            verbose && _verbose_extent_info(geomextent, arrayextent)
            return false
        end
        # Take a view of the geometry extent
        B1 = view(B, Touches(geomextent))
        buf1 = _init_bools(B1)
        # Burn the polygon into the buffer
        allocs = isnothing(allocs) ? Allocs(B) : allocs
        hasburned = _burn_polygon!(buf1, geom; shape, geomextent, allocs, boundary, kw...)
        @inbounds for i in eachindex(B1)
            if buf1[i]
                B1[i] = true
            end
        end
    else
        _shape_error(shape)
    end
    return hasburned
end

# Get the shape category for a geometry
@inline _geom_shape(geom) = _geom_shape(GI.geomtrait(geom), geom)
@inline _geom_shape(::Union{<:GI.PointTrait,<:GI.MultiPointTrait}, geom) = :point
@inline _geom_shape(::Union{<:GI.LineTrait,<:GI.LineStringTrait,<:GI.MultiLineStringTrait}, geom) = :line
@inline _geom_shape(::Union{<:GI.LinearRingTrait,<:GI.PolygonTrait,<:GI.MultiPolygonTrait}, geom) = :polygon
@inline _geom_shape(x, geom) = throw(ArgumentError("Geometry trait $x cannot be rasterized"), geom)
@inline _geom_shape(::Nothing, geom) = throw(ArgumentError("Object is not a GeoInterface.jl compatible geometry: $geom"), geom)

@noinline _shape_error(shape) = 
    throw(ArgumentError("`shape` is $shape, must be `:point`, `:line`, `:polygon` or `nothing`"))

@noinline _verbose_extent_info(geomextent, arrayextent) =
    @info "A geometry was ignored at $geomextent as it was outside of the supplied extent $arrayextent"
