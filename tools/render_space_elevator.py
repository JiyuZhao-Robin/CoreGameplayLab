"""Bake original FUE5/Earendel elevator geometry for the 2D Factory canvas.

Blender 4.5 LTS: blender --background --python tools/render_space_elevator.py -- --preview
Omit --preview to bake the complete loop. No external image/model paths required.
"""
import bpy
import bmesh
import json
import math
import sys
from pathlib import Path
from mathutils import Vector

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'assets/models/space_elevator/source'
DEST = ROOT / 'assets/ui/factory/space_elevator'
PREVIEW = '--preview' in sys.argv
SHADOW_ONLY = '--shadow-only' in sys.argv
COUNT = 24
WIDTH, HEIGHT = 768, 1024
PITCH = 22.66744422912598
TOP = 78.0

bpy.ops.object.select_all(action='SELECT')
bpy.ops.object.delete(use_global=False)
scene = bpy.context.scene
bpy.context.preferences.filepaths.save_version = 0
groups = {}
for filename in ['static1.fbx', 'static2.fbx', 'animated1.fbx']:
    before = set(bpy.data.objects)
    bpy.ops.import_scene.fbx(filepath=str(SOURCE / filename))
    groups[filename] = list(set(bpy.data.objects) - before)
scene.frame_set(1)
bpy.context.view_layer.update()

# Keep source UVs and real surface detail; rebuild the UE material bindings in Blender.
for material in bpy.data.materials:
    if not material.name.startswith('mat'):
        continue
    family = material.name.split('.')[0]
    material.use_nodes = True
    nodes, links = material.node_tree.nodes, material.node_tree.links
    nodes.clear()
    output = nodes.new('ShaderNodeOutputMaterial')
    shader = nodes.new('ShaderNodeBsdfPrincipled')
    shader.inputs['Metallic'].default_value = 0.55
    shader.inputs['Roughness'].default_value = 0.48
    diffuse = nodes.new('ShaderNodeTexImage')
    diffuse.image = bpy.data.images.load(str(SOURCE / f'space-elevator_{family}_diffuse1.jpg'), check_existing=True)
    links.new(diffuse.outputs['Color'], shader.inputs['Base Color'])
    normal_path = SOURCE / f'space-elevator_{family}_normal1.jpg'
    if normal_path.exists():
        texture = nodes.new('ShaderNodeTexImage')
        texture.image = bpy.data.images.load(str(normal_path), check_existing=True)
        texture.image.colorspace_settings.name = 'Non-Color'
        normal = nodes.new('ShaderNodeNormalMap')
        links.new(texture.outputs['Color'], normal.inputs['Color'])
        links.new(normal.outputs[0], shader.inputs['Normal'])
    links.new(shader.outputs[0], output.inputs[0])

def world_mesh(obj):
    transform = obj.matrix_world.copy()
    obj.parent = None
    obj.data = obj.data.copy()
    obj.data.transform(transform)
    obj.matrix_world.identity()

def cut_mesh(obj, lower=None, upper=None):
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    for z, normal in [(lower, (0, 0, 1)), (upper, (0, 0, -1))]:
        if z is None: continue
        geometry = list(bm.verts) + list(bm.edges) + list(bm.faces)
        if geometry:
            bmesh.ops.bisect_plane(bm, geom=geometry, dist=0.00001,
                                  plane_co=(0, 0, z), plane_no=normal,
                                  clear_inner=True, clear_outer=False)
    bm.to_mesh(obj.data)
    bm.free()
    obj.data.update()

# Underground foundations must not appear below the grid's deployment footprint.
base = [o for o in groups['static1.fbx'] if o.type == 'MESH']
for obj in base:
    world_mesh(obj)
    cut_mesh(obj, lower=0.0)

# The original spire is a repeatable lifting section. Repeat its geometry vertically
# and bake its authored translation; clip only the ends hidden by the base/crown.
spire = [o for o in groups['static2.fbx'] if o.type == 'MESH']
templates = []
for obj in spire:
    world_mesh(obj)
    templates.append((obj.name, obj.data.copy(), obj))
    obj.hide_render = True
moving = []
for offset in [-PITCH, 0.0, PITCH, PITCH * 2, PITCH * 3]:
    for name, data, original in templates:
        obj = bpy.data.objects.new(name + '_lift', data.copy())
        scene.collection.objects.link(obj)
        moving.append((obj, data, offset))

def set_phase(index):
    # Original antenna action runs frames 1..301; omit duplicate endpoint.
    source_frame = 1.0 + 300.0 * index / COUNT
    scene.frame_set(int(source_frame), subframe=source_frame % 1)
    travel = PITCH * index / COUNT
    for obj, template, offset in moving:
        previous = obj.data
        obj.data = template.copy()
        for vertex in obj.data.vertices:
            vertex.co.z += offset + travel
        cut_mesh(obj, lower=24.0, upper=TOP)
        if previous.users == 0: bpy.data.meshes.remove(previous)
    bpy.context.view_layer.update()

set_phase(0)

# User-selected DSP planetary logistics crown: keep only the original upper
# docking platform, with its source UVs, and seat its neck over the FUE5 spire.
DSP = SOURCE / 'dsp'
before = set(bpy.data.objects)
bpy.ops.wm.obj_import(filepath=str(DSP / 'logistic-station-1__resources.assets__7418.obj'),
                      forward_axis='NEGATIVE_Z', up_axis='Y')
bpy.context.view_layer.update()
dock = [o for o in set(bpy.data.objects) - before if o.type == 'MESH']
deck_material = bpy.data.materials.new('DSP docking deck - industrial adaptation')
deck_material.use_nodes = True
nodes, links = deck_material.node_tree.nodes, deck_material.node_tree.links
p = nodes.get('Principled BSDF')
p.inputs['Metallic'].default_value = 0.6
p.inputs['Roughness'].default_value = 0.5
albedo = nodes.new('ShaderNodeTexImage')
albedo.image = bpy.data.images.load(str(DSP / 'logistic-station-a__sharedassets0.assets__1024.png'))
tint = nodes.new('ShaderNodeMixRGB')
tint.blend_type = 'MULTIPLY'
tint.inputs[0].default_value = 1.0
tint.inputs[2].default_value = (0.72, 0.44, 0.105, 1)
links.new(albedo.outputs['Color'], tint.inputs[1])
links.new(tint.outputs[0], p.inputs['Base Color'])
emission = nodes.new('ShaderNodeTexImage')
emission.image = bpy.data.images.load(str(DSP / 'logistic-station-e__sharedassets0.assets__1115.png'))
links.new(emission.outputs['Color'], p.inputs['Emission Color'])
p.inputs['Emission Strength'].default_value = 1.8
normal_image = nodes.new('ShaderNodeTexImage')
normal_image.image = bpy.data.images.load(str(DSP / 'logistic-station-n__sharedassets0.assets__422.png'))
normal_image.image.colorspace_settings.name = 'Non-Color'
normal = nodes.new('ShaderNodeNormalMap')
normal.inputs['Strength'].default_value = 0.7
links.new(normal_image.outputs['Color'], normal.inputs['Color'])
links.new(normal.outputs[0], p.inputs['Normal'])
noise = nodes.new('ShaderNodeTexNoise')
noise.inputs['Scale'].default_value = 105
noise.inputs['Detail'].default_value = 3
rough = nodes.new('ShaderNodeMapRange')
rough.inputs['To Min'].default_value = 0.38
rough.inputs['To Max'].default_value = 0.72
links.new(noise.outputs['Fac'], rough.inputs['Value'])
links.new(rough.outputs[0], p.inputs['Roughness'])
# Small variations break up the pristine DSP paint while preserving all authored
# markings and UV placement. This is a model material, not painted-over pixels.
wear = nodes.new('ShaderNodeMixRGB')
wear.blend_type = 'MULTIPLY'
wear.inputs[0].default_value = 0.24
links.new(tint.outputs[0], wear.inputs[1])
links.new(noise.outputs['Fac'], wear.inputs[2])
links.new(wear.outputs[0], p.inputs['Base Color'])
for obj in dock:
    world_mesh(obj)
    cut_mesh(obj, lower=19.8)
    for vertex in obj.data.vertices:
        vertex.co.x *= 3.0
        vertex.co.y *= 3.0
        vertex.co.z = (vertex.co.z - 19.8) * 3.0 + TOP - 4.0
    obj.data.materials.clear()
    obj.data.materials.append(deck_material)
    obj.name = 'DSP original planetary docking crown'

scene.render.engine = 'CYCLES'
scene.cycles.samples = 64
scene.cycles.use_denoising = True
scene.render.resolution_x, scene.render.resolution_y = WIDTH, HEIGHT
scene.render.resolution_percentage = 100
scene.render.film_transparent = True
scene.render.image_settings.file_format = 'PNG'
scene.render.image_settings.color_mode = 'RGBA'
scene.render.image_settings.color_depth = '8'
scene.view_settings.view_transform = 'AgX'
scene.world.use_nodes = True
scene.world.node_tree.nodes['Background'].inputs[0].default_value = (0.65, 0.73, 0.9, 1)
scene.world.node_tree.nodes['Background'].inputs[1].default_value = 0.65

# Fixed oblique camera. Render geometry is fitted to its ground contact, not the
# image rectangle, so the tall tower cannot shrink the base inside its grid box.
target = Vector((0, 0, 39))
bpy.ops.object.camera_add(location=target + Vector((70, -100, 116)))
camera = bpy.context.object
camera.rotation_euler = (target - camera.location).to_track_quat('-Z', 'Y').to_euler()
camera.data.type = 'ORTHO'
camera.data.ortho_scale = 116
scene.camera = camera
bpy.ops.object.light_add(type='AREA', location=(-40, -50, 100))
key = bpy.context.object
key.data.energy = 190000
key.data.shape = 'DISK'
key.data.size = 40
key.rotation_euler = (Vector((0,0,25)) - key.location).to_track_quat('-Z','Y').to_euler()

(DEST / 'frames').mkdir(parents=True, exist_ok=True)
for index in ([] if SHADOW_ONLY else ([0] if PREVIEW else range(COUNT))):
    set_phase(index)
    scene.render.filepath = str(DEST / ('preview.png' if PREVIEW else f'frames/{index:03}.png'))
    bpy.ops.render.render(write_still=True)
    print(f'ELEVATOR_FRAME {index+1}/{COUNT}', flush=True)

if not PREVIEW:
    # A short, static foundation shadow grounds the sprite without covering the
    # neighboring factory with the full tower's long silhouette.
    set_phase(0)
    for obj in bpy.data.objects:
        if obj.type == 'MESH':
            obj.visible_camera = False
            obj.visible_shadow = obj in base
    bpy.ops.mesh.primitive_plane_add(size=400, location=(0,0,-0.025))
    floor = bpy.context.object
    floor.is_shadow_catcher = True
    key.location = (-40,-50,200)
    key.rotation_euler = (-key.location).to_track_quat('-Z','Y').to_euler()
    key.data.energy = 500000
    key.data.size = 35
    # Remove the shadow catcher's tiny sampling residual from unoccluded ground.
    scene.use_nodes = True
    nodes, links = scene.node_tree.nodes, scene.node_tree.links
    nodes.clear()
    render = nodes.new('CompositorNodeRLayers')
    subtract = nodes.new('ShaderNodeMath')
    subtract.operation = 'SUBTRACT'
    subtract.inputs[1].default_value = 0.035
    divide = nodes.new('ShaderNodeMath')
    divide.operation = 'DIVIDE'
    divide.inputs[1].default_value = 0.965
    divide.use_clamp = True
    alpha = nodes.new('CompositorNodeSetAlpha')
    alpha.mode = 'REPLACE_ALPHA'
    output = nodes.new('CompositorNodeComposite')
    links.new(render.outputs['Alpha'], subtract.inputs[0])
    links.new(subtract.outputs[0], divide.inputs[0])
    links.new(render.outputs['Image'], alpha.inputs['Image'])
    links.new(divide.outputs[0], alpha.inputs['Alpha'])
    links.new(alpha.outputs[0], output.inputs[0])
    scene.render.filepath = str(DEST / 'shadow.png')
    bpy.ops.render.render(write_still=True)

if PREVIEW:
    # Preview blend is optional working evidence, never a runtime dependency.
    bpy.ops.wm.save_as_mainfile(filepath=str(Path(bpy.app.tempdir) / 'space-elevator-preview.blend'))
else:
    manifest = {
        'schema_version': 1, 'frame_count': COUNT, 'fps': 12,
        'frame_size': [WIDTH, HEIGHT], 'reference_footprint_tiles': [20, 20],
        'body_rect_normalized': [-0.19, -0.78, 1.38, 1.84],
        'frames': [f'res://assets/ui/factory/space_elevator/frames/{i:03}.png' for i in range(COUNT)],
        'shadow': 'res://assets/ui/factory/space_elevator/shadow.png',
        'source': 'FUE5BASE/FUE5; Earendel original model; Hurricane textures/materials; user-supplied DSP planetary logistics docking crown',
        'animation': 'Original antenna rotation; repeated original spire lift translation; no train or launch simulation',
        'renderer': 'Blender 4.5 Cycles, 64 samples, orthographic, transparent RGBA',
    }
    (DEST / 'manifest.json').write_text(json.dumps(manifest, indent=2), encoding='utf8')
