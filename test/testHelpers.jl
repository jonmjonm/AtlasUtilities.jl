# Helpers shared by the library tests.
using AtlasUtilities: mapDataHistograms, writeHistograms, stripAtlasExt

"`extract-map-data-histogram` from the library: `mapDataHistograms`, then `writeHistograms` next to the atlas."
function histogramFiles(path; burn_in = 0, max_maps = 0, compress = true, force = false, kw...)
    hists, _ = mapDataHistograms(path; burn_in, max_maps, kw...)
    return writeHistograms(stripAtlasExt(path), hists; atlas = path, burn_in, max_maps, compress, force)
end
