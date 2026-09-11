"""Blender 4.5: render actual Kenney models into the existing 2x2 tree atlas contract.

Run: blender --background --python tools/render_kenney_nature.py
Original Kenney geometry; documented Earth material adaptation; no AI inputs.
"""
from pathlib import Path
import hashlib
import json
import math
import bpy
from mathutils import Vector

ROOT = Path(__file__).resolve().parents[1]
DEST = ROOT / "assets/ui/factory/natural/kenney_nature"
MODELS = ("tree_oak", "tree_detailed", "tree_default", "tree_pineRoundC")
LEAF_COLORS = ((0.09, 0.20, 0.045, 1), (0.13, 0.26, 0.06, 1), (0.18, 0.27, 0.07, 1), (0.055, 0.14, 0.07, 1))

bpy.ops.object.select_all(action="SELECT")
bpy.ops.object.delete(use_global=False)
scene = bpy.context.scene
bpy.context.preferences.filepaths.save_version = 0
scene.render.engine = "CYCLES"
scene.cycles.samples = 64
scene.cycles.use_denoising = True
scene.render.resolution_x = 2048
scene.render.resolution_y = 2048
scene.render.resolution_percentage = 100
scene.render.film_transparent = True
scene.render.image_settings.file_format = "PNG"
scene.render.image_settings.color_mode = "RGBA"
scene.view_settings.view_transform = "Standard"
scene.world.use_nodes = True
scene.world.node_tree.nodes["Background"].inputs[0].default_value = (0.68, 0.76, 0.90, 1)
scene.world.node_tree.nodes["Background"].inputs[1].default_value = 0.55

# A 70-degree elevation gives legible crown silhouettes and a small visible trunk.
camera_data = bpy.data.cameras.new("Earth canopy orthographic camera")
camera = bpy.data.objects.new("Earth canopy orthographic camera", camera_data)
scene.collection.objects.link(camera)
camera.location = (0, -math.cos(math.radians(70)) * 25, math.sin(math.radians(70)) * 25)
camera.rotation_euler = (-camera.location).to_track_quat("-Z", "Y").to_euler()
camera_data.type = "ORTHO"
camera_data.ortho_scale = 8
scene.camera = camera
rotation = camera.rotation_euler.to_matrix()
right = rotation @ Vector((1, 0, 0))
up = rotation @ Vector((0, 1, 0))
depth = rotation @ Vector((0, 0, 1))
placements = []
for index, name in enumerate(MODELS):
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=str(DEST / "source/models" / (name + ".glb")))
    imported = set(bpy.data.objects) - before
    meshes = [obj for obj in imported if obj.type == "MESH"]
    # Remove import parent transforms while preserving the original model shape.
    for obj in meshes:
        transform = obj.matrix_world.copy()
        obj.parent = None
        obj.matrix_world = transform
    bpy.context.view_layer.update()
    points = [obj.matrix_world @ vertex.co for obj in meshes for vertex in obj.data.vertices]
    xs, ys, zs = [[p.dot(axis) for p in points] for axis in (right, up, depth)]
    center = right * ((min(xs) + max(xs)) / 2) + up * ((min(ys) + max(ys)) / 2) + depth * ((min(zs) + max(zs)) / 2)
    scale = 3.3 / max(max(xs) - min(xs), max(ys) - min(ys))
    target = right * (-2 if index % 2 == 0 else 2) + up * (2 if index < 2 else -2)
    for obj in meshes:
        obj.location = (obj.location - center) * scale + target
        obj.scale *= scale
        for slot in obj.material_slots:
            if slot.material is None:
                continue
            slot.material = slot.material.copy()
            material = slot.material
            material.use_nodes = True
            principled = next(node for node in material.node_tree.nodes if node.type == "BSDF_PRINCIPLED")
            principled.inputs["Metallic"].default_value = 0
            principled.inputs["Roughness"].default_value = 0.88
            color = (0.19, 0.085, 0.035, 1) if "wood" in material.name.lower() else LEAF_COLORS[index]
            principled.inputs["Base Color"].default_value = color
    placements.append({"cell": index, "source_model": name + ".glb", "scale": scale, "leaf_base_color_linear_rgba": LEAF_COLORS[index]})

sun_data = bpy.data.lights.new("Warm upper-left sunlight", "SUN")
sun_data.energy = 2.0
sun_data.color = (1.0, 0.94, 0.83)
sun_data.angle = math.radians(10)
sun = bpy.data.objects.new("Warm upper-left sunlight", sun_data)
scene.collection.objects.link(sun)
sun.rotation_euler = Vector((4, -5, -8)).to_track_quat("-Z", "Y").to_euler()
output = DEST / "kenney_earth_canopies_v1.png"
scene.render.filepath = str(output)
bpy.ops.wm.save_as_mainfile(filepath=str(DEST / "source/earth_canopies.blend"))
bpy.ops.render.render(write_still=True)
manifest = {"renderer": bpy.app.version_string, "engine": "CYCLES", "samples": 64, "resolution": [2048, 2048], "atlas_grid": [2, 2], "camera_elevation_degrees": 70, "orthographic_scale": 8, "background": "transparent", "model_materials": "Derived Earth palette: leaf greens per cell, bark linear RGBA [0.19,0.085,0.035,1], metallic=0, roughness=0.88; source GLB unchanged", "cells_row_major": placements, "output": output.name, "sha256": hashlib.sha256(output.read_bytes()).hexdigest()}
(DEST / "render_manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
print("KENNEY_RENDER_COMPLETE", manifest["sha256"])
