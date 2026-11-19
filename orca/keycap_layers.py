# SPDX-License-Identifier: MPL-2.0
#
# /// script
# requires-python = ">=3.12"
#
# [tool.orcaslicer.plugin]
# name = "keycap layers"
# description = "Slices keycap's 3MF exports by the layers traced from their fields, not by their coarse meshes."
# author = "Rei Stepanenko"
# version = "0.1.0"
# ///
"""keycap layers: a slicing pipeline plugin for OrcaSlicer 2.5.

keycap's `print` export writes a 3MF whose mesh is coarse, for placing the
part, its seams and painting, and whose layers, traced from the model's
field at the heights the slicer will cut, are in its
`Metadata/keycap_layers.json`.  At `posSlice`, before perimeters, this puts
those layers in place of the ones Orca cut from the mesh, so that walls,
infill and supports follow the exact outlines.

A layer is replaced only where the export has one at the slicer's own
height: with the layer heights of the 3MF's profile and its first layer
height.  Layers it has none for, and objects of more than one region, keep
the mesh's slices.  A part may be moved, and turned or scaled about Z, but
not tilted.

Side-load this file in Orca's plugins dialog, then pick it as the process's
slicing pipeline plugin.  It reads the 3MF the object was loaded from, so
Orca asks once to let it; `layers_file` in its settings names another.
numpy, where Orca's Python has it, is faster and lets parts turn.

Untested in Orca: written against the plugin API of its sources, v2.5.1,
and tried on a stand-in for its `orca` module.
"""

import bisect
import json
import os
import zipfile

import orca

try:
    import numpy
except ImportError:
    numpy = None

SIDECAR = "Metadata/keycap_layers.json"

# How far apart, in millimetres, a layer's height and the export's may be
# to be the same layer: the export writes them to a tenth of a micrometre.
SAME_Z = 5e-4

_DEFAULTS = {
    # The JSON of the layers, when it is not in the 3MF the object came from
    "layers_file": "",
}

# The sidecars read so far, by path and modification time
_read = {}


def _sidecar(path):
    """The objects of the layers in PATH, a 3MF or their JSON."""
    key = (path, os.path.getmtime(path))
    if key not in _read:
        if zipfile.is_zipfile(path):
            with zipfile.ZipFile(path) as archive:
                data = json.loads(archive.read(SIDECAR))
        else:
            with open(path, encoding="utf-8") as file:
                data = json.load(file)
        _read[key] = data["objects"]
    return _read[key]


def _linear(print_object):
    """The 3x3 part of the object's transformation, rows of floats.

    Identity without numpy, which `trafo()` needs."""
    if numpy is None:
        return [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]]
    m = numpy.asarray(print_object.trafo())
    volumes = print_object.model_object().volumes()
    if len(volumes) == 1:
        m = m @ numpy.asarray(volumes[0].matrix())
    return [[float(m[i][j]) for j in range(3)] for i in range(3)]


class Placement:
    """Where the export's coordinates land in the slicer's.

    Orca slices a part turned by its transformation, centred on the middle
    of its turned footprint and standing on z = 0, as the export stands
    it."""

    def __init__(self, linear, hull):
        if any(abs(linear[i][2]) > 1e-9 or abs(linear[2][i]) > 1e-9 for i in range(2)):
            raise ValueError("the part is tilted; its layers are no longer level")
        self.xy = [row[:2] for row in linear[:2]]
        self.z = linear[2][2]
        footprint = [self._turn(p) for p in zip(hull[0::2], hull[1::2])]
        self.centre = [
            (min(p[i] for p in footprint) + max(p[i] for p in footprint)) / 2 for i in range(2)
        ]

    def _turn(self, p):
        return [self.xy[i][0] * p[0] + self.xy[i][1] * p[1] for i in range(2)]

    def points(self, flat, scale):
        """The scaled integer points of FLAT, [x0, y0, x1, y1, ...]."""
        out = []
        for p in zip(flat[0::2], flat[1::2]):
            q = self._turn(p)
            out.append((round((q[0] - self.centre[0]) * scale), round((q[1] - self.centre[1]) * scale)))
        # ExPolygon turns its outline counterclockwise and its holes
        # clockwise, as a mirrored part needs.
        return out


def _polygon(points):
    if numpy is not None:
        return numpy.array(points, dtype=numpy.int64)
    polygon = orca.host.Polygon()
    for x, y in points:
        polygon.append(orca.host.Point(x, y))
    return polygon


def _expolygons(shapes, placement, scale):
    """The export's SHAPES, each its outline and then its holes, as ExPolygons."""
    out = []
    for shape in shapes:
        contours = [_polygon(placement.points(c, scale)) for c in shape if len(c) >= 6]
        if contours:
            out.append(orca.host.ExPolygon(contours[0], contours[1:]))
    return out


class KeycapLayers(orca.slicing.SlicingPipelineCapabilityBase):
    def get_name(self):
        return "keycap layers"

    def get_default_config(self):
        return _DEFAULTS

    def _layers_file(self, print_object):
        try:
            configured = json.loads(self.get_config()).get("layers_file", "")
        except (AttributeError, TypeError, ValueError):
            configured = ""
        return configured or print_object.model_object().input_file

    def execute(self, ctx):
        if ctx.step != orca.slicing.Step.posSlice or ctx.object is None:
            return orca.ExecutionResult.success()
        print_object = ctx.object
        name = print_object.model_object().name
        path = self._layers_file(print_object)
        try:
            objects = _sidecar(path)
        except (OSError, KeyError, ValueError) as error:
            return orca.ExecutionResult.skipped(f"{name}: no keycap layers in {path}: {error}")
        found = [o for o in objects if o["name"] == name] or (objects if len(objects) == 1 else [])
        if not found:
            return orca.ExecutionResult.skipped(f"{name}: no keycap layers for it in {path}")
        exported = found[0]
        try:
            placement = Placement(_linear(print_object), exported["hull"])
        except ValueError as error:
            return orca.ExecutionResult.skipped(f"{name}: {error}")

        by_z = sorted((layer["z"], layer["shapes"]) for layer in exported["layers"])
        heights = [z for z, _ in by_z]
        scale = 1.0 / orca.slicing.unscale(1)
        replaced = missing = shared = 0
        for layer in print_object.layers():
            if ctx.cancelled():
                break
            regions = layer.regions()
            if len(regions) != 1:
                shared += 1
                continue
            z = layer.slice_z / placement.z
            at = bisect.bisect_left(heights, z - SAME_Z)
            if at == len(heights) or heights[at] > z + SAME_Z:
                missing += 1
                continue
            expolygons = _expolygons(by_z[at][1], placement, scale)
            regions[0].slices.set(expolygons, orca.host.SurfaceType.stInternal)
            layer.make_slices()
            replaced += 1

        message = f"{name}: {replaced} layers from keycap"
        if missing:
            message += f", {missing} at heights it has none for (check the layer heights)"
        if shared:
            message += f", {shared} of several regions kept"
        return orca.ExecutionResult.success(message)


@orca.plugin
class KeycapLayersPackage(orca.base):
    def register_capabilities(self):
        orca.register_capability(KeycapLayers)
