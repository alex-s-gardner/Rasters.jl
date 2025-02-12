module RastersArchGDALExt

@static if isdefined(Base, :get_extension) # julia < 1.9
    using Rasters, ArchGDAL
else    
    using ..Rasters, ..ArchGDAL
end

import DiskArrays,
    Extents,
    Missings

using DimensionalData,
    GeoFormatTypes,
    GeoInterface

using Rasters.LookupArrays
using Rasters.Dimensions
using Rasters: GDALsource, AbstractProjected, RasterStackOrArray, FileArray,
    RES_KEYWORD, SIZE_KEYWORD, CRS_KEYWORD, FILENAME_KEYWORD, SUFFIX_KEYWORD, EXPERIMENTAL,
    GDAL_EMPTY_TRANSFORM, GDAL_TOPLEFT_X, GDAL_WE_RES, GDAL_ROT1, GDAL_TOPLEFT_Y, GDAL_ROT2, GDAL_NS_RES

import Rasters: reproject, resample, warp, cellsize

const RA = Rasters
const DD = DimensionalData
const DA = DiskArrays
const GI = GeoInterface
const LA = LookupArrays

include("cellsize.jl")
include("gdal_source.jl")
include("reproject.jl")
include("resample.jl")
include("warp.jl")

end
