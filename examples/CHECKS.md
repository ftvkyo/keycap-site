# Checks

How examples ported from OpenSCAD were compared with their originals' exports.
An example's opening comment says the result in one line.

## allen-key-handle

Max 0.016 mm, mean under 0.004: the port's field at points every 0.3 mm along OpenSCAD's `projection(cut = true)` of `handle()`, at z = 0, 2.5, -3.9, y = 0, x = 30, 58 (5600 points), read off `sdf` slices by `probe`; the original's 24- and 36-gons.

## bed-washers

Max 0.0074 mm: the port's field at 1400 points on the original's STL, the hole's 36 facets; outlines at z = 0.25, 0.45, 0.95 against a mesh export at 0.05 mm within 0.035, the mesh's own error.

## bendy-sheet

2D exports against OpenSCAD's own at `$fn` = 360, compared both ways every 5 µm along the outlines: the sheet within 0.004 mm, the half disc 0.0034 (OpenSCAD's 360-gon) and the leg 0.00001, SVG and DXF alike.

## fidget-flower

Max 0.26 mm, part by part at RESOLUTION 48 against mesh exports at 0.083 mm: housing top within 0.066 (OpenSCAD's facets), bearing shell 0.023, cage 0.084, inner half 0.26 (the joiners' `union_round`), petal and gear 0.13 (the gear's groove's facets).

## fidget-magnetic

Max 0.30 mm: outlines of the original's STL at RESOLUTION 48 and a mesh export at 0.067 mm, at 15 heights from z = -24 to 24; 0.30 is the grip's corners, elsewhere within 0.04.

## hex-bowl

Max 0.019 mm across the surface (2000 points on the original's STL), the hollow's 60 facets; outlines at z = 1, 4, 8, 14, 19 within 0.11, the same facets on the shallow hollow.

## knob

Max 0.62 mm, mean 0.09: the profile's outline walked to from 246 points of OpenSCAD's (`$fn` = 360), the most at the waist's cusp.

## laptop-stand

`leg1`, `leg2` and `lock` traced to DXF at 20 cells per mm against OpenSCAD's DXF at `$fn` = 360, both ways every 5 µm: legs within 0.001 mm (7 and 6 lines, 23 and 24 arcs against 4078 lines), lock 0.014 at the outer teeth's ends, OpenSCAD's 1-degree facets.
The printed joint: the port's field is 0 at every vertex of the original's STL.
The assembly by eye.

## laptop-stand-2

`leg1`, `leg2` within 0.035 mm of the original's SVGs (the 24-facet holes); `joint` within 0.047 mm both ways (STL, 20000 points, mean 0.015); `joint cut` within 0.043.
`all`: sections across Z at 19, 25, 31, 58, 64, 85.5, 97.6 differ by under 3 mm² in all, no piece over 1 mm², and the volumes by 0.08%.

## phone-stand

Max 0.051 mm, mean 0.004: 20000 points on the port's mesh (cells of 1/6 mm) against the original's STL and back, the `$fn` = 72 and 36 spheres' facets.

## pointer

Max 0.0002 mm: the port's field at 3000 points on the original's STL (the halves to print); outlines at z = 0.5, 5, 9.5, 14, 18 within 0.0003.

## scraper

Max 0.0375 mm, mean 0.008: the outline of the port's slice (label left out of both) against OpenSCAD's SVG export (214 lines), both ways sampled every 5 micrometres; the 48-gons' sag.

## spike

`PART = "all"`.
Max 0.024 mm: the port's field at points every 0.2 mm along OpenSCAD's `projection(cut = true)` at z = -3, -1, 1, 3.3, 5.5, 12, y = 0, x = 0, 1.2, read off `sdf` slices by `probe`; the original's 24-gons.

## vase-funky-2

Max 0.98 mm, mean 0.35 at z = 30 (0.71 at 75, 0.55 at 110): the port's outline walked to from 536 points of OpenSCAD's slice there, worked out from its profile (`$fn` = 96) and its own slice schedule, since CGAL could not cut the 36 slices in 50 minutes.
The profile alone is within 0.46 mm (mean 0.18): hg_sdf fillets where the hexagons meet at other than right angles.

## vase-practical

Slices against OpenSCAD's `projection(cut = true)`: at z = 13 and 25 within 0.05 mm at 0.028 mm pixels; at z = 0 and 50 within a pixel of 0.11.

## whistle

Max 0.010 mm: the outline of the port's slice at z = 0 walked to from all 79 points of OpenSCAD's `projection(cut = true)`, its E = 0.01 offsets.
The slider (`open = true`), cut at z = 3 above its hole: within 0.016, OpenSCAD's `$fn` = 48.
The label is not compared.
