"""Author and bake the original HELIX-01 miner with Blender 4.5 LTS.

This is original procedural 3D modelling, material authoring and animation.
No reference building meshes or image-generation outputs are used.
Usage: blender --background --python tools/build_helix_miner.py -- --preview
       blender --background --python tools/build_helix_miner.py -- --bake
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import sys

import bpy
from mathutils import Vector
from bpy_extras.object_utils import world_to_camera_view

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "assets/models/helix_miner"
EVIDENCE = ROOT / "artifacts/ui/miner"
FPS = 30
SIZE = 512
MODEL = []
PAINT = []
LIGHT_MESHES = []


def material(name, color, metallic=0.0, roughness=0.5, weather=False, emission=0):
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes.get("Principled BSDF")
    bsdf.inputs["Base Color"].default_value = (*color, 1)
    bsdf.inputs["Metallic"].default_value = metallic
    bsdf.inputs["Roughness"].default_value = roughness
    mat.diffuse_color = (*color, 1)
    if emission:
        bsdf.inputs["Emission Color"].default_value = (*color, 1)
        bsdf.inputs["Emission Strength"].default_value = emission
    if weather:
        nodes, links = mat.node_tree.nodes, mat.node_tree.links
        noise = nodes.new("ShaderNodeTexNoise")
        noise.inputs["Scale"].default_value = 42
        noise.inputs["Detail"].default_value = 3
        ramp = nodes.new("ShaderNodeValToRGB")
        ramp.color_ramp.elements[0].position = 0.25
        ramp.color_ramp.elements[0].color = tuple(c * 0.70 for c in color) + (1,)
        ramp.color_ramp.elements[1].position = 0.65
        ramp.color_ramp.elements[1].color = (*color, 1)
        links.new(noise.outputs["Fac"], ramp.inputs[0])
        geometry = nodes.new("ShaderNodeNewGeometry")
        links.new(geometry.outputs["Position"], noise.inputs["Vector"])
        links.new(ramp.outputs["Color"], bsdf.inputs["Base Color"])
        bump = nodes.new("ShaderNodeBump")
        bump.inputs["Strength"].default_value = 0.08
        bump.inputs["Distance"].default_value = 0.009
        links.new(noise.outputs["Fac"], bump.inputs["Height"])
        links.new(bump.outputs["Normal"], bsdf.inputs["Normal"])
    return mat


def finish(obj, name, mat, parent=None, bevel=0):
    obj.name = name
    if mat:
        obj.data.materials.append(mat)
    if parent:
        obj.parent = parent
    if bevel:
        modifier = obj.modifiers.new("Machined edge radii", "BEVEL")
        modifier.width = bevel
        modifier.segments = 3
        obj.modifiers.new("Weighted face normals", "WEIGHTED_NORMAL")
    MODEL.append(obj)
    return obj


def box(name, loc, dims, mat, parent=None, bevel=0.04):
    bpy.ops.mesh.primitive_cube_add(size=1, location=loc)
    obj = bpy.context.object
    obj.dimensions = dims
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    return finish(obj, name, mat, parent, bevel)


def cylinder(name, loc, radius, depth, mat, parent=None, direction=None, vertices=32):
    bpy.ops.mesh.primitive_cylinder_add(vertices=vertices, radius=radius, depth=depth, location=loc)
    obj = bpy.context.object
    if direction:
        obj.rotation_euler = Vector(direction).to_track_quat("Z", "Y").to_euler()
    for face in obj.data.polygons:
        face.use_smooth = len(face.vertices) == 4
    return finish(obj, name, mat, parent, min(0.012, radius * 0.12))


def beam(name, start, end, width, depth, mat, parent=None):
    a, b = Vector(start), Vector(end)
    obj = box(name, (a+b)/2, (width, depth, (b-a).length), mat, parent, min(width/5, 0.035))
    obj.rotation_euler = (b-a).to_track_quat("Z", "Y").to_euler()
    return obj


def pipe(name, points, radius, mat, parent=None):
    curve = bpy.data.curves.new(name, "CURVE")
    curve.dimensions = "3D"
    curve.bevel_depth = radius
    curve.bevel_resolution = 3
    spline = curve.splines.new("BEZIER")
    spline.bezier_points.add(len(points)-1)
    for p, co in zip(spline.bezier_points, points):
        p.co = co
        p.handle_left_type = "AUTO"
        p.handle_right_type = "AUTO"
    obj = bpy.data.objects.new(name, curve)
    bpy.context.collection.objects.link(obj)
    return finish(obj, name, mat, parent)


def ring(name, loc, major, minor, mat, parent=None, rotation=None):
    bpy.ops.mesh.primitive_torus_add(major_segments=48, minor_segments=10, location=loc, major_radius=major, minor_radius=minor)
    obj = bpy.context.object
    if rotation:
        obj.rotation_euler = rotation
    for p in obj.data.polygons:
        p.use_smooth = True
    return finish(obj, name, mat, parent)


def label(text, loc, size, mat, rotation=(math.pi/2,0,0), parent=None):
    curve = bpy.data.curves.new("Plate lettering", "FONT")
    curve.body, curve.size = text, size
    curve.extrude = 0.0015
    curve.align_x = "CENTER"
    obj = bpy.data.objects.new(text, curve)
    bpy.context.collection.objects.link(obj)
    obj.location, obj.rotation_euler = loc, rotation
    return finish(obj, text, mat, parent)


def empty(name, loc, parent=None):
    obj = bpy.data.objects.new(name, None)
    bpy.context.collection.objects.link(obj)
    obj.location = loc
    obj.parent = parent
    MODEL.append(obj)
    return obj


def auger(parent, steel, chrome):
    cylinder("Hardened drill core", (0,0,-0.60), 0.16, 1.2, chrome, parent)
    vertices, faces = [], []
    count = 216
    # Solid helical cutting ribbon with a tapered toe, not a texture illusion.
    for i in range(count+1):
        f = i/count
        angle = f*math.tau*2.7
        z = -0.04 - f*1.10
        radius = 0.46 * (1-0.48*max(0,(f-0.76)/0.24))
        for r, dz in [(0.16,-0.028),(radius,-0.028),(radius,0.028),(0.16,0.028)]:
            vertices.append((r*math.cos(angle), r*math.sin(angle), z+dz))
    for i in range(count):
        for j in range(4):
            a=i*4+j; b=i*4+(j+1)%4
            faces.append((a,b,b+4,a+4))
    faces.extend([(0,3,2,1),(count*4,count*4+1,count*4+2,count*4+3)])
    mesh=bpy.data.meshes.new("Solid helical cutter")
    mesh.from_pydata(vertices, [], faces)
    mesh.update()
    obj=bpy.data.objects.new("Spiral cutting flights",mesh)
    bpy.context.collection.objects.link(obj)
    finish(obj,obj.name,steel,parent,0.008)
    bpy.ops.mesh.primitive_cone_add(vertices=32, radius1=0.02, radius2=0.25, depth=0.3, location=(0,0,-1.28))
    finish(bpy.context.object,"Tungsten pilot point",chrome,parent,0.012)
    for i in range(12):
        a=i*math.tau/12
        tooth=box("Replaceable cutter tooth",(0.44*math.cos(a),0.44*math.sin(a),-0.05-i/12*1.10),(0.10,0.10,0.065),chrome,parent,0.012)
        tooth.rotation_euler.z=a


def build():
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)
    orange=material("Ochre enamel / fine wear",(0.53,0.205,0.038),0.48,0.42,True)
    ivory=material("Warm ceramic identification",(0.52,0.55,0.47),0.45,0.40,True)
    dark=material("Graphite cast steel",(0.048,0.067,0.073),0.72,0.37,True)
    steel=material("Worn cutting steel",(0.21,0.25,0.27),0.85,0.31,True)
    chrome=material("Hydraulic chrome",(0.48,0.57,0.61),0.92,0.22)
    rubber=material("Rubber / cable insulation",(0.018,0.025,0.026),0.05,0.70)
    yellow=material("Safety amber",(0.9,0.53,0.05),0.2,0.42)
    white=material("Stencilled lettering",(0.88,0.83,0.67),0.05,0.58)
    glow=material("Working indicator glass",(0.12,0.7,0.8),0.15,0.2,emission=3)
    red=material("Amber beacon glass",(1,0.25,0.03),0.05,0.22,emission=2)
    root=empty("HELIX_01_ROOT",(0,0,0))
    # Open-center load-bearing base, stabilized by four outriggers.
    for x in [-1.28,1.28]:
        PAINT.append(box("Longitudinal chassis armour",(x,0,0.43),(0.52,2.65,0.4),orange,root,0.09))
        box("Chassis wear rail",(x,-0.1,0.20),(0.58,2.60,0.11),steel,root)
        for y in [-1.15,1.1]:
            beam("Outrigger shoulder",(x,y,0.48),(x*1.25,y*1.25,0.30),0.34,0.34,dark,root)
            cylinder("Levelling jack",(x*1.25,y*1.25,0.25),0.16,0.43,chrome,root)
            cylinder("Jack dust collar",(x*1.25,y*1.25,0.40),0.22,0.13,dark,root)
            box("Octagonal foot pad",(x*1.25,y*1.25,0.06),(0.65,0.54,0.12),dark,root,0.12)
            for dx in [-0.19,0.19]:
                cylinder("Foot anchor bolt",(x*1.25+dx,y*1.25,0.14),0.035,0.065,chrome,root,vertices=6)
    box("Rear cross member",(0,1.16,0.43),(2.9,0.36,0.37),dark,root)
    box("Front threshold",(0,-1.16,0.37),(2.9,0.25,0.27),steel,root)
    # Gantry, twin guide rods, bolted crosshead and rear diagonal bracing.
    for x in [-0.68,0.68]:
        PAINT.append(box("Portal mast",(x,-0.35,1.98),(0.30,0.45,3.05),orange,root,0.055))
        box("Mast guide seat",(x,-0.615,2.02),(0.22,0.08,2.5),dark,root,0.01)
        cylinder("Polished linear guide",(x,-0.69,2.0),0.065,2.5,chrome,root)
        beam("Rear gantry brace",(x,-0.25,3.22),(x*1.75,1.2,0.55),0.16,0.18,dark,root)
        for z in [0.75,1.15,2.8,3.2]:
            for dx in [-0.085,0.085]:
                cylinder("Gantry hex fastener",(x+dx,-0.595,z),0.038,0.035,chrome,root,(0,-1,0),6)
    PAINT.append(box("Overhead crosshead",(0,-0.35,3.42),(1.9,0.64,0.34),ivory,root,0.08))
    label("HELIX  /  01",(0,-0.684,3.36),0.19,dark,parent=root)
    box("Top cable ladder",(0,-0.3,3.68),(1.1,0.5,0.12),dark,root)
    for x in [-0.8,0.8]:
        cylinder("Crosshead cap",(x,-0.34,3.66),0.075,0.13,steel,root)
    # Sliding rotary head. Only this assembly and the drill rotate/translate.
    carriage=empty("FEED_CARRIAGE",(0,-0.67,2.05),root)
    box("Carriage saddle",(0,0.12,0.15),(1.25,0.28,0.48),dark,carriage)
    for x in [-0.68,0.68]:
        cylinder("Guide slider bush",(x,0,0.08),0.115,0.55,steel,carriage)
    box("Rotary gearbox",(0,-0.04,0.12),(0.85,0.73,0.55),orange,carriage,0.11)
    cylinder("Drive motor housing",(0,0.02,0.56),0.35,0.40,dark,carriage)
    for z in [0.44,0.51,0.58,0.65]:
        ring("Motor cooling fin",(0,0.02,z),0.35,0.027,steel,carriage)
    box("Head identification stripe",(0,-0.423,0.12),(0.61,0.018,0.14),ivory,carriage,0.006)
    cylinder("Lower spindle bearing",(0,0,-0.27),0.29,0.20,steel,carriage)
    ring("Spindle safety ring",(0,0,-0.33),0.31,0.045,yellow,carriage)
    rotor=empty("DRILL_ROTOR",(0,0,-0.38),carriage)
    auger(rotor,steel,chrome)
    # Central feed ram and flexible service loops are visibly attached.
    cylinder("Hydraulic actuator body",(0,0.02,2.77),0.15,1.1,dark,root)
    ram=cylinder("Extending feed piston",(0,0.02,2.00),0.08,0.70,chrome,root)
    for x in [-0.45,0.45]:
        pipe("Flexible rotary-head hose",[(x,0.1,0.45),(x*1.2,0.36,0.9),(x*1.4,0.40,1.16),(x*1.55,0.5,1.3)],0.037,rubber,carriage)
    # Rear power pack and exposed cooling fan: clearly a mining utility rig.
    PAINT.append(box("Electrical compressor enclosure",(0,0.73,1.02),(1.65,1.02,0.85),ivory,root,0.11))
    PAINT.append(box("Side service pod",(1.22,0.26,0.92),(0.62,1.15,0.73),orange,root,0.075))
    box("Vent recessed face",(1.55,0.28,0.92),(0.025,0.86,0.5),dark,root,0.005)
    for y in [i*0.09-0.04 for i in range(8)]:
        box("Radiator louvre",(1.574,y,0.94),(0.035,0.035,0.42),steel,root,0.007)
    cylinder("Rear fan shroud",(0,1.278,1.08),0.35,0.07,dark,root,(0,1,0))
    fan=empty("COOLING_FAN",(0,1.33,1.08),root)
    for i in range(8):
        a=i*math.tau/8
        blade=box("Fan impeller",(math.cos(a)*0.18,0,math.sin(a)*0.18),(0.32,0.035,0.085),steel,fan,0.012)
        blade.rotation_euler.y=-a
    cylinder("Fan center",(0,0,0),0.1,0.09,orange,fan,(0,1,0))
    for z in [0.9,1.02,1.14,1.26]:
        beam("Fan guard",(-0.30,1.39,z),(0.30,1.39,z),0.018,0.018,chrome,root)
    # Hose manifold, pressure tanks and visible flanges.
    for x in [-1.25,-0.91]:
        cylinder("Pressure reservoir",(x,0.56,1.0),0.16,0.95,steel,root)
        ring("Tank strap lower",(x,0.56,0.69),0.164,0.024,ivory,root)
        ring("Tank strap upper",(x,0.56,1.28),0.164,0.024,ivory,root)
        pipe("Manifold return",[(x,0.56,1.48),(x,0.8,1.65),(-0.45,0.92,1.6)],0.046,dark,root)
    pipe("Protected power conduit",[(1.25,0.7,1.4),(1.05,0.74,1.8),(0.75,0.3,2.15),(0.7,0.2,3.3)],0.058,rubber,root)
    pipe("Amber coolant line",[(-1.15,-0.5,0.62),(-1.23,-0.15,0.8),(-1.2,0.3,1.42),(-0.7,0.85,1.46)],0.043,orange,root)
    # Perforated service deck, rails, ladder, warning markings and hardware.
    box("Service deck",(0,1.22,0.7),(2.4,0.45,0.09),dark,root,0.015)
    for x in [i*0.12-1.08 for i in range(19)]:
        box("Deck grating",(x,1.22,0.76),(0.035,0.42,0.02),steel,root,0.004)
    for x in [-1.12,1.12]:
        beam("Handrail upright",(x,1.38,0.73),(x,1.38,1.7),0.045,0.045,yellow,root)
    beam("Upper safety rail",(-1.12,1.38,1.7),(1.12,1.38,1.7),0.05,0.05,yellow,root)
    beam("Intermediate safety rail",(-1.12,1.38,1.3),(1.12,1.38,1.3),0.035,0.035,yellow,root)
    for x in [-0.30,0.30]:
        beam("Access ladder stringer",(x,1.76,0.12),(x,1.47,0.73),0.06,0.065,steel,root)
    for i in range(3):
        box("Ladder tread",(0,1.70-i*0.09,0.22+i*0.18),(0.65,0.18,0.04),steel,root,0.008)
    box("Front safety panel",(0,-1.30,0.49),(1.5,0.04,0.18),yellow,root,0.008)
    for x in [-0.58,-0.3,-0.02,0.26,0.54]:
        stripe=box("Hazard chevron",(x,-1.327,0.49),(0.105,0.012,0.2),dark,root,0.001)
        stripe.rotation_euler.y=-0.38
    label("ELECTRIC  •  400V",(0,0.205,1.12),0.12,dark,parent=root)
    label("H-01",(1.25,-0.335,0.92),0.12,white,parent=root)
    for x in [-1.26,1.26]:
        for y in [-1.0,-0.6,0,0.5,1.0]:
            cylinder("Armour top bolt",(x,y,0.65),0.032,0.04,chrome,root,vertices=6)
    for x in [-0.65,0.65]:
        box("Worklight housing",(x,-0.74,3.25),(0.30,0.14,0.19),dark,root,0.028)
        LIGHT_MESHES.append(box("Worklight lens",(x,-0.823,3.25),(0.22,0.025,0.11),glow,root,0.018))
    cylinder("Beacon pedestal",(0.82,0.82,1.56),0.09,0.14,dark,root)
    LIGHT_MESHES.append(cylinder("Run beacon",(0.82,0.82,1.71),0.08,0.18,red,root))
    setup_scene()
    return root,carriage,rotor,ram,fan


def setup_scene():
    scene=bpy.context.scene
    scene.render.engine="CYCLES"
    scene.cycles.samples=24
    scene.cycles.use_denoising=True
    try:
        prefs=bpy.context.preferences.addons['cycles'].preferences
        prefs.compute_device_type='OPTIX'
        prefs.get_devices()
        for device in prefs.devices:
            device.use=device.type != 'CPU'
        scene.cycles.device='GPU'
    except Exception as exc:
        print("Cycles GPU setup fallback",exc)
    scene.render.resolution_x=SIZE
    scene.render.resolution_y=SIZE
    scene.render.resolution_percentage=100
    scene.render.image_settings.file_format='PNG'
    scene.render.image_settings.color_mode='RGBA'
    scene.render.film_transparent=True
    scene.render.fps=FPS
    scene.world.color=(0.22,0.25,0.29)
    scene.world.use_nodes=True
    scene.world.node_tree.nodes['Background'].inputs['Color'].default_value=(0.37,0.43,0.53,1)
    scene.world.node_tree.nodes['Background'].inputs['Strength'].default_value=0.45
    scene.view_settings.view_transform='AgX'
    scene.view_settings.look='AgX - Medium High Contrast'
    for name,loc,power,size,color in [
        ('Key / northwest',(-5,-7,10),1600,5,(1,0.85,0.66)),
        ('Sky fill',(6,-2,6),1000,5,(0.61,0.77,1)),
        ('Edge rim',(1,5,7),1800,4,(1,0.69,0.40))]:
        data=bpy.data.lights.new(name,'AREA');data.energy=power;data.shape='DISK';data.size=size;data.color=color
        obj=bpy.data.objects.new(name,data);bpy.context.collection.objects.link(obj);obj.location=loc
        obj.rotation_euler=(Vector((0,0,1.2))-obj.location).to_track_quat('-Z','Y').to_euler()
    bpy.ops.object.camera_add(location=(7,-10,8.8))
    camera=bpy.context.object;camera.name='Orthographic sprite camera'
    camera.rotation_euler=(Vector((0,0,1.5))-camera.location).to_track_quat('-Z','Y').to_euler()
    camera.data.type='ORTHO';camera.data.ortho_scale=6.5
    scene.camera=camera
    scene.render.image_settings.compression=30
    scene.render.use_file_extension=True


def pose(rig, clip, f):
    _,carriage,rotor,ram,fan=rig
    if clip=='startup':
        t=f/23
        smooth=t*t*(3-2*t)
        height=2.55-0.74*smooth
        spin=math.tau*2*t*t
    elif clip=='shutdown':
        t=f/23
        smooth=t*t*(3-2*t)
        height=1.81+0.74*smooth
        spin=math.tau*(2*t-t*t)
    else:
        t=f/60
        height=1.81-0.14*(1-math.cos(t*math.tau))
        spin=math.tau*4*t
    carriage.location.z=height
    rotor.rotation_euler.z=spin
    fan.rotation_euler.y=-spin*1.75
    ram.location.z=(height+2.45)*0.5
    ram.scale.z=(2.8-height)/0.70
    bpy.context.view_layer.update()


def render(path):
    bpy.context.scene.render.filepath=str(path)
    bpy.ops.render.render(write_still=True)


def export_model(rig):
    scene=bpy.context.scene
    bpy.context.preferences.filepaths.save_version=0
    # A continuous editable master timeline plus explicit clip markers.
    for clip,start,count in [('startup',1,24),('working',25,60),('shutdown',85,24)]:
        scene.timeline_markers.new(clip.upper(),frame=start)
        for f in range(count):
            pose(rig,clip,f)
            for obj in rig[1:]:
                obj.keyframe_insert('location',frame=start+f)
                obj.keyframe_insert('rotation_euler',frame=start+f)
                obj.keyframe_insert('scale',frame=start+f)
    scene.frame_start=1;scene.frame_end=108
    scene.frame_set(25)
    (OUT/'source').mkdir(parents=True,exist_ok=True)
    (OUT/'source/.gdignore').touch()
    bpy.ops.wm.save_as_mainfile(filepath=str(OUT/'source/helix_miner.blend'))
    # Export only actual model objects. Curve/text conversion is export-local.
    bpy.ops.object.select_all(action='DESELECT')
    for obj in MODEL:
        obj.select_set(True)
    bpy.context.view_layer.objects.active=rig[0]
    bpy.ops.export_scene.gltf(filepath=str(OUT/'helix_miner.glb'),export_format='GLB',use_selection=True,
        export_apply=True,export_animations=True,export_animation_mode='SCENE',export_frame_range=True,
        export_force_sampling=True,export_anim_scene_split_object=False)
    for obj in rig[1:]:
        obj.animation_data_clear()
    scene.frame_set(1)


def bake(rig):
    scene=bpy.context.scene
    light_strengths=[]
    for obj in LIGHT_MESHES:
        for mat in obj.data.materials:
            socket=mat.node_tree.nodes.get('Principled BSDF').inputs['Emission Strength']
            light_strengths.append((socket,socket.default_value))
            socket.default_value=0
    for clip,count in [('startup',24),('working',60),('shutdown',24)]:
        directory=OUT/'sprites'/clip;directory.mkdir(parents=True,exist_ok=True)
        for f in range(count):
            pose(rig,clip,f)
            render(directory/f'{f:04d}.png')
            print(f'HELIX_BAKE {clip} {f+1}/{count}',flush=True)
    pose(rig,'working',0)
    for socket,strength in light_strengths:
        socket.default_value=strength
    # Derive fixed accent and emissive passes with model occlusion preserved.
    saved=[(obj,list(obj.data.materials)) for obj in MODEL if getattr(obj,'data',None) and hasattr(obj.data,'materials')]
    black=material('Pass occluder',(0,0,0),0,1)
    black.node_tree.nodes.clear()
    black_surface=black.node_tree.nodes.new('ShaderNodeEmission')
    black_surface.inputs['Color'].default_value=(0,0,0,1)
    black_out=black.node_tree.nodes.new('ShaderNodeOutputMaterial')
    black.node_tree.links.new(black_surface.outputs[0],black_out.inputs['Surface'])
    for obj,mats in saved:
        obj.data.materials.clear();obj.data.materials.append(black)
    maskmat=material('Accent pass',(1,1,1),0,1,emission=1)
    for obj in PAINT:
        if obj.name.startswith('Portal mast'):
            continue  # moving head occlusion requires an animated mast mask
        obj.data.materials.clear();obj.data.materials.append(maskmat)
    # Black surfaces remain opaque in the render; compositor converts RGB to
    # transparent mask using luminance, without post-processing source bitmaps.
    scene.use_nodes=True
    tree=scene.node_tree;tree.nodes.clear()
    layer=tree.nodes.new('CompositorNodeRLayers')
    bw=tree.nodes.new('CompositorNodeRGBToBW');tree.links.new(layer.outputs['Image'],bw.inputs[0])
    alpha=tree.nodes.new('CompositorNodeSetAlpha');alpha.inputs['Image'].default_value=(1,1,1,1)
    amount=tree.nodes.new('CompositorNodeMath');amount.operation='MULTIPLY';amount.inputs[1].default_value=0.18
    tree.links.new(bw.outputs[0],amount.inputs[0]);tree.links.new(amount.outputs[0],alpha.inputs['Alpha'])
    composite=tree.nodes.new('CompositorNodeComposite');tree.links.new(alpha.outputs[0],composite.inputs[0])
    render(OUT/'sprites/mask.png')
    for obj,mats in saved:
        obj.data.materials.clear();obj.data.materials.append(black)
    for obj,mats in saved:
        if obj in LIGHT_MESHES:
            obj.data.materials.clear()
            for mat in mats:obj.data.materials.append(mat)
    tree.links.new(layer.outputs['Image'],alpha.inputs['Image'])
    tree.links.new(bw.outputs[0],alpha.inputs['Alpha'])
    render(OUT/'sprites/emission.png')
    scene.use_nodes=False
    for obj,mats in saved:
        obj.data.materials.clear()
        for mat in mats:obj.data.materials.append(mat)
    # Cycles shadow catcher: correct soft directional contact shadow, separate RGBA.
    bpy.ops.mesh.primitive_plane_add(size=200,location=(0,0,-0.015))
    floor=bpy.context.object;floor.name='Shadow catcher';floor.is_shadow_catcher=True
    floor.data.materials.append(material('Shadow receiver',(0.5,0.5,0.5),0,1))
    for obj in MODEL:
        obj.visible_camera=False
    scene.cycles.samples=256
    # Clamp only faint Monte Carlo background noise in the shadow-catcher alpha.
    scene.use_nodes=True;tree.nodes.clear()
    layer=tree.nodes.new('CompositorNodeRLayers')
    subtract=tree.nodes.new('CompositorNodeMath');subtract.operation='SUBTRACT';subtract.use_clamp=True;subtract.inputs[1].default_value=0.035
    tree.links.new(layer.outputs['Alpha'],subtract.inputs[0])
    shadow_alpha=tree.nodes.new('CompositorNodeSetAlpha');shadow_alpha.inputs['Image'].default_value=(0,0,0,1)
    tree.links.new(subtract.outputs[0],shadow_alpha.inputs['Alpha'])
    composite=tree.nodes.new('CompositorNodeComposite');tree.links.new(shadow_alpha.outputs[0],composite.inputs[0])
    render(OUT/'sprites/shadow.png')
    scene.use_nodes=False;scene.cycles.samples=24
    for obj in MODEL:
        obj.visible_camera=True
    bpy.data.objects.remove(floor,do_unlink=True)


def manifest():
    scene=bpy.context.scene
    anchor=world_to_camera_view(scene,scene.camera,Vector((0,0,0)))
    pixels_per_tile=SIZE/scene.camera.data.ortho_scale
    shift=[(0.5-anchor.x)*SIZE/pixels_per_tile,(anchor.y-0.5)*SIZE/pixels_per_tile]
    prefix='res://assets/models/helix_miner/'
    clips={clip:dict(textures=[prefix+f'sprites/{clip}/{i:04d}.png' for i in range(count)],fps=30,frame_count=count)
        for clip,count in [('startup',24),('working',60),('shutdown',24)]}
    layers=[]
    for id in ['shadow','base','mask','emission']:
        layer=dict(id=id,frame_size=[SIZE,SIZE],frame_count=60 if id=='base' else 1,columns=1,
            source_scale=1,shift_tiles=shift,fps=30 if id=='base' else 0,
            blend='add' if id=='emission' else 'mix',running_only=id=='emission',provenance_id='helix-original')
        layer.update(textures=clips['working']['textures']) if id=='base' else layer.update(texture=prefix+f'sprites/{id}.png')
        layers.append(layer)
    reference=json.loads((ROOT/'assets/art_calibration/manifest.json').read_text(encoding='utf-8'))
    result=dict(schema_version=1,status='original_model_prototype',building=dict(id='helix_miner_01',footprint_tiles=[4,4],
        source_pixels_per_tile=pixels_per_tile,fit_multiplier=1,anchor='ground_origin',directions=['authored'],layers=layers),
        clips=clips,ground=reference['ground'],ore=reference['ore'],smoke=reference['smoke'],
        provenance=[dict(id='helix-original',author='Original procedural model authored in this project with Codex',
        source_script='tools/build_helix_miner.py',model='source/helix_miner.blend',interchange='helix_miner.glb',
        generator='Blender '+bpy.app.version_string,reference_meshes_used=False,reference_images_used_for_model=False,
        note='Reference sand, ore and smoke in the preview retain their original separate credits.')],
        animation_timeline=dict(fps=30,startup=[1,24],working=[25,84],shutdown=[85,108]),
        geometry=dict(objects=len(MODEL),meshes=sum(1 for x in MODEL if x.type=='MESH')))
    used_reference_ids={reference[key]['provenance_id'] for key in ['ground','ore','smoke']}
    evidence_paths={'polyhaven-aerial-sand':'licenses/polyhaven-evidence.md',
        'malcolm-riley':'licenses/unused-renders-LICENSE.txt','rubberduck-smoke':'licenses/rubberduck-SOURCE.html'}
    result['provenance'].extend({**p,'evidence':'res://assets/art_calibration/'+evidence_paths[p['id']]}
        for p in reference['provenance'] if p['id'] in used_reference_ids)
    (OUT/'manifest.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    paths=[p for p in OUT.rglob('*') if p.is_file() and p.suffix in ['.png','.glb','.blend']]
    record=dict(generation_mode='full_bake',blender_version=bpy.app.version_string,
        generator_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        files=[dict(path=p.relative_to(OUT).as_posix(),sha256=hashlib.sha256(p.read_bytes()).hexdigest()) for p in sorted(paths)])
    (OUT/'provenance.json').write_text(json.dumps(record,indent=2)+'\n',encoding='utf-8')


if __name__=='__main__':
    args=sys.argv[sys.argv.index('--')+1:] if '--' in sys.argv else []
    parser=argparse.ArgumentParser()
    mode=parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--preview',action='store_true')
    mode.add_argument('--bake',action='store_true')
    options=parser.parse_args(args)
    OUT.mkdir(parents=True,exist_ok=True);EVIDENCE.mkdir(parents=True,exist_ok=True)
    rig=build();pose(rig,'working',15)
    if options.preview:
        bpy.context.scene.render.resolution_x=1024;bpy.context.scene.render.resolution_y=1024
        render(EVIDENCE/'model-preview.png')
    else:
        export_model(rig)
        bake(rig)
        # Provenance certifies only this complete model + frame generation.
        # Never re-sign old frames after a script-only or metadata-only change.
        manifest()
    print('HELIX_MODEL_BUILD_PASS',flush=True)
