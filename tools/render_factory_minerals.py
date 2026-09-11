#!/usr/bin/env python3
"""Render reproducible Factory iron and copper resource field sprite atlases.

Run with the project-provided Blender installation:

    D:/DevCache/helios-blender/blender-4.5.9-windows-x64/blender.exe \
      --background --python tools/render_factory_minerals.py -- --project-root .

The script opens Poly Haven's CC0 boulder model, renders non-mirrored model
instances under a fixed upper-left light, and composites 8 variations × 4
density stages into each transparent 1024×512 atlas using Blender's image API.
It deliberately does not use Pillow or synthetic debug geometry.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import random
import sys
from pathlib import Path

import bpy
from mathutils import Vector


CELL_PX = 128
COLUMNS = 8
ROWS = 4
ATLAS_WIDTH = CELL_PX * COLUMNS
ATLAS_HEIGHT = CELL_PX * ROWS
SEED = 18473

PROJECT_ROOT = Path(__file__).resolve().parents[1]

RENDER_SETTINGS = {
    "renderer": "Blender 4.5.9 LTS, EEVEE Next",
    "camera": "orthographic, elevated top-down three-quarter view",
    "camera_ortho_scale": 2.85,
    "lighting": "fixed upper-left area key plus soft fill",
    "seed": SEED,
    "mirrored_instances": False,
    "source_model_instances": True,
    "grid": {
        "sheet_width": ATLAS_WIDTH,
        "sheet_height": ATLAS_HEIGHT,
        "cell_px": CELL_PX,
        "columns": COLUMNS,
        "rows": ROWS,
        "density_order": "top row 0 is dense; bottom row 3 is sparse",
    },
    "material_derivation": {
        "iron": "blue-gray mineral screen tint over CC0 boulder albedo",
        "copper": "orange-brown mineral screen tint over CC0 boulder albedo",
    },
}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def receipt_path(path: Path, project_root: Path) -> str:
    try:
        return path.resolve().relative_to(project_root.resolve()).as_posix()
    except ValueError:
        return str(path.resolve())


def blender_arguments() -> argparse.Namespace:
    arguments = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else []
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project-root", type=Path, default=PROJECT_ROOT)
    parser.add_argument("--source-blend", type=Path)
    return parser.parse_args(arguments)


def look_at(camera: bpy.types.Object, target: Vector) -> None:
    direction = target - camera.location
    camera.rotation_euler = direction.to_track_quat("-Z", "Y").to_euler()


def make_material(name: str, albedo: bpy.types.Image, tint: tuple[float, float, float, float]) -> bpy.types.Material:
    material = bpy.data.materials.new(name)
    material.use_nodes = True
    nodes = material.node_tree.nodes
    links = material.node_tree.links
    for node in list(nodes):
        nodes.remove(node)
    output = nodes.new("ShaderNodeOutputMaterial")
    shader = nodes.new("ShaderNodeBsdfPrincipled")
    image = nodes.new("ShaderNodeTexImage")
    multiply = nodes.new("ShaderNodeMixRGB")
    image.image = albedo
    image.interpolation = "Linear"
    # Screen keeps the physical boulder albedo and surface detail while lifting
    # the mineral hue enough to remain readable on the dark Factory ground.
    multiply.blend_type = "SCREEN"
    multiply.inputs[0].default_value = 0.22
    multiply.inputs[2].default_value = tint
    shader.inputs["Roughness"].default_value = 0.48
    if "Metallic" in shader.inputs:
        shader.inputs["Metallic"].default_value = 0.32
    elif "Metallic IOR Level" in shader.inputs:
        shader.inputs["Metallic IOR Level"].default_value = 0.18
    if "Specular IOR Level" in shader.inputs:
        shader.inputs["Specular IOR Level"].default_value = 0.48
    if "Emission Color" in shader.inputs:
        shader.inputs["Emission Color"].default_value = tint
        shader.inputs["Emission Strength"].default_value = 0.045
    links.new(image.outputs["Color"], multiply.inputs[1])
    links.new(multiply.outputs["Color"], shader.inputs["Base Color"])
    links.new(shader.outputs["BSDF"], output.inputs["Surface"])
    return material


def create_scene(source_blend: Path) -> tuple[bpy.types.Scene, bpy.types.Object, bpy.types.Image]:
    bpy.ops.wm.open_mainfile(filepath=str(source_blend))
    source = bpy.data.objects.get("boulder_01_LOD0")
    if source is None or source.type != "MESH":
        raise RuntimeError("Expected boulder_01_LOD0 mesh in %s" % source_blend)
    for object_ in bpy.context.scene.objects:
        object_.hide_render = True
    albedo = bpy.data.images.get("boulder_01_diff_2k.jpg")
    if albedo is None:
        source_texture = source_blend.parent / "textures" / "boulder_01_diff_2k.jpg"
        albedo = bpy.data.images.load(str(source_texture), check_existing=True)

    scene = bpy.context.scene
    scene.render.engine = "BLENDER_EEVEE_NEXT"
    scene.render.resolution_x = CELL_PX
    scene.render.resolution_y = CELL_PX
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = "PNG"
    scene.render.image_settings.color_mode = "RGBA"
    scene.render.image_settings.color_depth = "8"
    scene.render.image_settings.compression = 15
    scene.render.film_transparent = True
    scene.render.use_file_extension = True

    try:
        scene.view_settings.look = "AgX - Medium High Contrast"
    except (TypeError, ValueError):
        pass

    camera_data = bpy.data.cameras.new("FactoryOreCamera")
    camera_data.type = "ORTHO"
    # Dense clusters occupy about 88% of a 128px cell.  The small transparent
    # margin avoids clipping when Factory overlaps neighboring field quads.
    camera_data.ortho_scale = 2.85
    camera = bpy.data.objects.new("FactoryOreCamera", camera_data)
    scene.collection.objects.link(camera)
    camera.location = Vector((4.8, -7.2, 7.6))
    look_at(camera, Vector((0.0, 0.0, 0.25)))
    scene.camera = camera

    key_data = bpy.data.lights.new("OreKeyUpperLeft", "AREA")
    key_data.energy = 850.0
    key_data.shape = "DISK"
    key_data.size = 4.0
    key = bpy.data.objects.new("OreKeyUpperLeft", key_data)
    scene.collection.objects.link(key)
    key.location = Vector((-5.5, -6.0, 9.0))
    look_at(key, Vector((0.0, 0.0, 0.0)))

    fill_data = bpy.data.lights.new("OreSoftFill", "AREA")
    fill_data.energy = 180.0
    fill_data.size = 5.0
    fill = bpy.data.objects.new("OreSoftFill", fill_data)
    scene.collection.objects.link(fill)
    fill.location = Vector((5.0, 2.0, 6.5))
    look_at(fill, Vector((0.0, 0.0, 0.0)))
    scene.world.color = (0.028, 0.034, 0.046)
    return scene, source, albedo


def cell_positions(variation: int, count: int) -> list[tuple[float, float, float, float]]:
    rng = random.Random(SEED + variation * 101)
    positions: list[tuple[float, float, float, float]] = []
    for index in range(count):
        angle = (index * 2.399963229728653 + rng.uniform(-0.28, 0.28)) + variation * 0.13
        ring = 0.15 + 0.84 * math.sqrt((index + 0.35) / max(count, 1))
        x = math.cos(angle) * ring + rng.uniform(-0.10, 0.10)
        y = math.sin(angle) * ring * 0.84 + rng.uniform(-0.10, 0.10)
        scale = rng.uniform(0.25, 0.46) * (1.08 if index < 2 else 1.0)
        yaw = rng.uniform(0.0, math.tau)
        positions.append((x, y, scale, yaw))
    if count >= 10:
        # Camera-space horizontal anchors guarantee a broad, continuous dense
        # field while the remaining positions retain per-variation asymmetry.
        screen_x = (0.83205, 0.55470)
        positions[0] = (-0.98 * screen_x[0], -0.98 * screen_x[1], 0.34, positions[0][3])
        positions[1] = (0.98 * screen_x[0], 0.98 * screen_x[1], 0.34, positions[1][3])
    return positions


def build_cluster(
    scene: bpy.types.Scene,
    source: bpy.types.Object,
    variation: int,
    density_row: int,
    ore_material: bpy.types.Material,
    gangue_material: bpy.types.Material,
) -> list[bpy.types.Object]:
    counts = (11, 8, 5, 3)
    count = counts[density_row]
    objects: list[bpy.types.Object] = []
    for index, (x, y, scale, yaw) in enumerate(cell_positions(variation, count)):
        object_ = source.copy()
        object_.data = source.data.copy()
        object_.name = "OreCluster_%d_%d_%d" % (density_row, variation, index)
        object_.hide_render = False
        object_.location = Vector((x, y, 0.0))
        object_.rotation_euler = (0.0, 0.0, yaw)
        object_.scale = (scale, scale, scale)
        object_.data.materials.clear()
        object_.data.materials.append(ore_material if index < max(2, round(count * 0.64)) else gangue_material)
        scene.collection.objects.link(object_)
        objects.append(object_)
    return objects


def remove_cluster(objects: list[bpy.types.Object]) -> None:
    for object_ in objects:
        mesh = object_.data
        bpy.data.objects.remove(object_, do_unlink=True)
        bpy.data.meshes.remove(mesh, do_unlink=True)


def render_atlas(
    scene: bpy.types.Scene,
    source: bpy.types.Object,
    albedo: bpy.types.Image,
    mineral: str,
    ore_tint: tuple[float, float, float, float],
    gangue_tint: tuple[float, float, float, float],
    output: Path,
    scratch: Path,
) -> None:
    ore_material = make_material("Factory%sOre" % mineral.title(), albedo, ore_tint)
    gangue_material = make_material("Factory%sGangue" % mineral.title(), albedo, gangue_tint)
    atlas = bpy.data.images.new(
        "Factory%sOreAtlas" % mineral.title(),
        width=ATLAS_WIDTH,
        height=ATLAS_HEIGHT,
        alpha=True,
        float_buffer=False,
    )
    atlas.alpha_mode = "STRAIGHT"
    atlas_pixels = [0.0] * (ATLAS_WIDTH * ATLAS_HEIGHT * 4)
    render_pixels = [0.0] * (CELL_PX * CELL_PX * 4)
    scratch.parent.mkdir(parents=True, exist_ok=True)

    for density_row in range(ROWS):
        for variation in range(COLUMNS):
            cluster = build_cluster(
                scene, source, variation, density_row, ore_material, gangue_material
            )
            bpy.ops.render.render(write_still=False)
            render = bpy.data.images.get("Render Result")
            if render is None:
                raise RuntimeError("Blender did not produce a Render Result")
            # Render Result is not a readable Image buffer in every background
            # Blender build.  Saving and reopening through Blender's own image
            # API keeps the atlas composition fully inside Blender.
            render.save_render(filepath=str(scratch), scene=scene)
            cell_image = bpy.data.images.load(str(scratch), check_existing=False)
            if cell_image.size[:] != (CELL_PX, CELL_PX):
                raise RuntimeError("Unexpected mineral cell render size: %s" % (cell_image.size[:],))
            cell_image.pixels.foreach_get(render_pixels)
            bpy.data.images.remove(cell_image)
            destination_x = variation * CELL_PX
            destination_y = (ROWS - 1 - density_row) * CELL_PX
            for y in range(CELL_PX):
                source_start = y * CELL_PX * 4
                target_start = ((destination_y + y) * ATLAS_WIDTH + destination_x) * 4
                atlas_pixels[target_start : target_start + CELL_PX * 4] = render_pixels[
                    source_start : source_start + CELL_PX * 4
                ]
            remove_cluster(cluster)

    atlas.pixels.foreach_set(atlas_pixels)
    atlas.filepath_raw = str(output)
    atlas.file_format = "PNG"
    output.parent.mkdir(parents=True, exist_ok=True)
    atlas.save()
    if scratch.exists():
        scratch.unlink()
    bpy.data.images.remove(atlas)
    bpy.data.materials.remove(ore_material, do_unlink=True)
    bpy.data.materials.remove(gangue_material, do_unlink=True)


def write_render_receipt(
    project_root: Path,
    source_blend: Path,
    albedo: bpy.types.Image,
    output_dir: Path,
) -> Path:
    source_texture = Path(bpy.path.abspath(albedo.filepath)).resolve()
    generator = Path(__file__).resolve()
    inputs = {
        "source_blend": source_blend.resolve(),
        "albedo_texture": source_texture,
    }
    for label, input_path in inputs.items():
        if not input_path.is_file():
            raise RuntimeError("Receipt input is missing (%s): %s" % (label, input_path))

    outputs = {}
    for mineral in ("iron", "copper"):
        output = output_dir / (mineral + "-ore.png")
        if not output.is_file():
            raise RuntimeError("Receipt output is missing: %s" % output)
        outputs[mineral] = {
            "path": receipt_path(output, project_root),
            "sha256": sha256(output),
            "bytes": output.stat().st_size,
        }

    receipt = {
        "schema_version": 1,
        "kind": "factory_natural_mineral_render_receipt",
        "generator": {
            "path": receipt_path(generator, project_root),
            "sha256": sha256(generator),
        },
        "inputs": {
            label: {
                "path": receipt_path(input_path, project_root),
                "sha256": sha256(input_path),
                "bytes": input_path.stat().st_size,
            }
            for label, input_path in inputs.items()
        },
        "settings": RENDER_SETTINGS,
        "outputs": outputs,
    }
    destination = output_dir.parent / "source" / "render-receipt.json"
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_suffix(".json.tmp")
    temporary.write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temporary.replace(destination)
    return destination


def main() -> int:
    args = blender_arguments()
    project_root = args.project_root.resolve()
    source_blend = (
        args.source_blend
        if args.source_blend is not None
        else project_root / "assets" / "ui" / "factory" / "natural" / "source" / "boulder" / "boulder_01_2k.blend"
    ).resolve()
    output_dir = project_root / "assets" / "ui" / "factory" / "natural" / "ores"
    scratch_dir = project_root / "artifacts" / "factory-natural-art"
    if not source_blend.is_file():
        raise FileNotFoundError("Boulder source blend is missing: %s" % source_blend)

    scene, source, albedo = create_scene(source_blend)
    render_atlas(
        scene,
        source,
        albedo,
        "iron",
        (0.24, 0.52, 0.82, 1.0),
        (0.40, 0.33, 0.28, 1.0),
        output_dir / "iron-ore.png",
        scratch_dir / "iron-cell.png",
    )
    render_atlas(
        scene,
        source,
        albedo,
        "copper",
        (0.92, 0.34, 0.08, 1.0),
        (0.46, 0.27, 0.17, 1.0),
        output_dir / "copper-ore.png",
        scratch_dir / "copper-cell.png",
    )
    receipt = write_render_receipt(project_root, source_blend, albedo, output_dir)
    print("Rendered Factory iron and copper ore atlases to %s (receipt: %s)" % (output_dir, receipt))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
