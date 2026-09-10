#!/usr/bin/env node
/*
 * Imports the user-authorized DSPONLINE mining/production catalog into the
 * CoreGameplayLab content-shard schema.  It reads only the four literal data
 * tables declared in the local source file and writes JSON to stdout; callers
 * deliberately choose whether and where to persist that generated output.
 */
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

const DEFAULT_SOURCE = "/Volumes/T9/Developer/projects/DSPONLINE/src/game/content.ts";
const cliArguments = process.argv.slice(2);
const sourceArgument = cliArguments.find((argument) => !argument.startsWith("--"));
const sourcePath = resolve(sourceArgument ?? process.env.DSPONLINE_CONTENT_PATH ?? DEFAULT_SOURCE);
const sourceText = readFileSync(sourcePath, "utf8");
const SOURCE_SHA256 = createHash("sha256").update(sourceText).digest("hex");

function extractLiteral(constantName) {
  const declaration = new RegExp(`export\\s+const\\s+${constantName}[^=]*=`).exec(sourceText);
  if (!declaration) throw new Error(`Missing export const ${constantName}`);
  let start = declaration.index + declaration[0].length;
  while (/\s/.test(sourceText[start])) start += 1;
  const opener = sourceText[start];
  const closer = opener === "{" ? "}" : opener === "[" ? "]" : "";
  if (!closer) throw new Error(`${constantName} is not an object or array literal`);
  let depth = 0;
  let quote = "";
  let escaped = false;
  let lineComment = false;
  let blockComment = false;
  for (let index = start; index < sourceText.length; index += 1) {
    const char = sourceText[index];
    const next = sourceText[index + 1] ?? "";
    if (lineComment) {
      if (char === "\n") lineComment = false;
      continue;
    }
    if (blockComment) {
      if (char === "*" && next === "/") {
        blockComment = false;
        index += 1;
      }
      continue;
    }
    if (quote) {
      if (!escaped && char === quote) quote = "";
      escaped = !escaped && char === "\\";
      if (char !== "\\") escaped = false;
      continue;
    }
    if (char === "/" && next === "/") {
      lineComment = true;
      index += 1;
      continue;
    }
    if (char === "/" && next === "*") {
      blockComment = true;
      index += 1;
      continue;
    }
    if (["'", '"', "`"].includes(char)) {
      quote = char;
      continue;
    }
    if (char === opener) depth += 1;
    if (char === closer) {
      depth -= 1;
      if (depth === 0) return sourceText.slice(start, index + 1);
    }
  }
  throw new Error(`Unterminated ${constantName} literal`);
}

function readTable(name) {
  // The authorized tables contain data-only object/array literals.  Evaluating
  // the extracted literal avoids an added TypeScript parser dependency while
  // keeping the importer deterministic and limited to the local source scope.
  return Function(`"use strict"; return (${extractLiteral(name)});`)();
}

const ITEMS = readTable("ITEMS");
const BUILDINGS = readTable("BUILDINGS");
const RECIPES = readTable("RECIPES");
const CONSTRUCTION = readTable("CONSTRUCTION");
const canonicalIds = new Set([
  "iron_ore", "copper_ore", "titanium_ore",
  "iron_ingot", "copper_ingot", "titanium_alloy",
]);
const rawResourceIds = new Set([
  "iron_ore", "copper_ore", "coal", "stone", "crude_oil", "silicon_ore",
  "titanium_ore", "fire_ice", "kimberlite_ore", "fractal_silicon",
  "optical_grating_crystal", "spiniform_stalagmite_crystal", "unipolar_magnet",
  "water", "sulfuric_acid",
]);
const fuelEnergyMj = {
  coal: 2.7,
  fire_ice: 4.8,
  crude_oil: 4,
  energetic_graphite: 6.3,
  refined_oil: 4.4,
  hydrogen: 8,
  hydrogen_fuel_rod: 54,
  deuteron_fuel_rod: 600,
  antimatter_fuel_rod: 7200,
};
// The source's matrix_research recipe deliberately has no I/O because the UI
// selected a matrix type dynamically.  The Factory schema needs an explicit
// consumed matrix.  Preserve the empty source shape in metadata and expose the
// six actual selections as deterministic, one-matrix research variants.
const matrixResearchVariants = [
  { source_recipe_id: "matrix_research", id: "matrix_research", matrix_item_id: "electromagnetic_matrix", research_points: 1 },
  { source_recipe_id: "matrix_research", id: "matrix_research_energy_matrix", matrix_item_id: "energy_matrix", research_points: 2 },
  { source_recipe_id: "matrix_research", id: "matrix_research_structure_matrix", matrix_item_id: "structure_matrix", research_points: 4 },
  { source_recipe_id: "matrix_research", id: "matrix_research_information_matrix", matrix_item_id: "information_matrix", research_points: 8 },
  { source_recipe_id: "matrix_research", id: "matrix_research_gravity_matrix", matrix_item_id: "gravity_matrix", research_points: 16 },
  { source_recipe_id: "matrix_research", id: "matrix_research_universe_matrix", matrix_item_id: "universe_matrix", research_points: 32 },
];
const matrixResearchVariantById = new Map(matrixResearchVariants.map((variant) => [variant.id, variant]));
const sourceTechnologyMap = {
  electromagnetism: "",
  solar_energy: "industrial_coordination",
  geothermal_power: "heavy_industry",
  thermal_power: "industrial_coordination",
  fusion_power: "advanced_propulsion",
  artificial_star: "megastructure_engineering",
  energy_storage: "industrial_coordination",
  plane_smelting: "heavy_industry",
  high_speed_assembling: "industrial_coordination",
  quantum_printing: "advanced_propulsion",
  proliferator_1: "industrial_coordination",
  proliferator_2: "heavy_industry",
  proliferator_3: "advanced_propulsion",
  electromagnetic_matrix: "",
  high_efficiency_plasma_control: "industrial_coordination",
  basic_logistics: "",
  high_speed_logistics: "industrial_coordination",
  super_magnetic_logistics: "heavy_industry",
  material_delivery_logistics: "heavy_industry",
  basic_chemical_engineering: "industrial_coordination",
  quantum_chemical_engineering: "advanced_propulsion",
  fractionation: "industrial_coordination",
  miniature_particle_collider: "advanced_propulsion",
  dyson_swarm: "megastructure_engineering",
  ray_receiver: "megastructure_engineering",
  vertical_launching_silo: "megastructure_engineering",
  planetary_logistics: "heavy_industry",
  interstellar_logistics: "advanced_propulsion",
  orbital_collection: "advanced_propulsion",
  construction_automation: "heavy_industry",
  universe_matrix: "megastructure_engineering",
  micro_black_hole_containment: "exotic_materials",
  time_warp_engineering: "exotic_materials",
  system_space_station_engineering: "megastructure_engineering",
  xray_cracking: "industrial_coordination",
  reforming_refine: "industrial_coordination",
  high_strength_crystal: "industrial_coordination",
  titanium_alloy: "heavy_industry",
  processor: "advanced_propulsion",
  space_warp: "advanced_propulsion",
  rare_resource_utilization: "exotic_materials",
  polymer_chemistry: "industrial_coordination",
  carbon_nanotube: "heavy_industry",
  particle_container: "advanced_propulsion",
  nanomaterials: "heavy_industry",
  deuteron_fuel_rod: "advanced_propulsion",
  casimir_crystal: "advanced_propulsion",
  plane_filter: "advanced_propulsion",
  quantum_chip: "advanced_propulsion",
  strange_matter: "exotic_materials",
  graviton_lens: "exotic_materials",
  photon_combiner: "megastructure_engineering",
  solar_sail: "megastructure_engineering",
  antimatter: "exotic_materials",
  antimatter_fuel_rod: "exotic_materials",
  frame_material: "megastructure_engineering",
  dyson_sphere_component: "megastructure_engineering",
  dyson_sphere_program: "megastructure_engineering",
  small_carrier_rocket: "megastructure_engineering",
  diamond: "industrial_coordination",
  plastic: "industrial_coordination",
  organic_crystal: "industrial_coordination",
  titanium_crystal: "heavy_industry",
  energy_matrix: "industrial_coordination",
  structure_matrix: "heavy_industry",
  information_matrix: "advanced_propulsion",
  gravity_matrix: "exotic_materials",
};

function itemId(sourceId) {
  return canonicalIds.has(sourceId) ? sourceId : `dsp_${sourceId}`;
}
function buildingId(sourceId) {
  return `grid_dsp_${sourceId}`;
}
function recipeId(sourceId) {
  return `dsp_${sourceId}`;
}
function buildingItemId(sourceId) {
  return `building_grid_dsp_${sourceId}`;
}
function manufactureRecipeId(sourceId) {
  return `manufacture_grid_dsp_${sourceId}`;
}
function titleFromId(sourceId) {
  const explicit = {
    em: "EM", mk1: "Mk.I", mk2: "Mk.II", mk3: "Mk.III", xray: "X-Ray",
    oil: "Oil", dyson: "Dyson", quantum: "Quantum", micro: "Micro",
    mj: "MJ", plasma: "Plasma", casimir: "Casimir", graviton: "Graviton",
    deuteron: "Deuteron", antimatter: "Antimatter", galactic: "Galactic",
  };
  return sourceId.split("_").map((part) => explicit[part] ?? `${part[0].toUpperCase()}${part.slice(1)}`).join(" ");
}
function storageProfile(item) {
  if (rawResourceIds.has(item.id)) {
    return item.kind === "fluid"
      ? { category: "Raw Resource", storage_class: "FLUID", storage_units: 2.5, freight_class: "BULK", freight_units: 2.5, cargo_mass: 2.5, cargo_volume: 2.5 }
      : { category: "Raw Resource", storage_class: "BULK", storage_units: 2.5, freight_class: "BULK", freight_units: 2.5, cargo_mass: 2.5, cargo_volume: 2 };
  }
  if (item.kind === "fluid") return { category: "Processed Material", storage_class: "FLUID", storage_units: 1.25, freight_class: "STANDARD", freight_units: 1.25, cargo_mass: 1, cargo_volume: 1.25 };
  if (item.kind === "matrix") return { category: "Special Equipment", storage_class: "SPECIAL", storage_units: 1, freight_class: "PRECISION", freight_units: 1, cargo_mass: 0.5, cargo_volume: 1 };
  return { category: "Component", storage_class: "COMPONENT", storage_units: 0.5, freight_class: "PRECISION", freight_units: 0.5, cargo_mass: 0.25, cargo_volume: 0.5 };
}
function requirementMetadata(sourceTechnologyId) {
  const mappedTechnologyId = sourceTechnologyMap[sourceTechnologyId] ?? "";
  const sourceMetadata = sourceTechnologyId
    ? { required_technology_id: sourceTechnologyId, mapped_technology_id: mappedTechnologyId }
    : {};
  return {
    source_metadata: sourceMetadata,
    ...(mappedTechnologyId ? { requirements: [{ type: "technology", id: mappedTechnologyId }], reveal_requirements: [{ type: "technology", id: mappedTechnologyId }] } : {}),
  };
}
function footprintFor(building) {
  if (building.megastructure) return { width: 32, height: 32 };
  if (["vertical_launching_silo", "em_rail_ejector", "miniature_particle_collider"].includes(building.id)) return { width: 20, height: 20 };
  if (["planetary_logistics_station", "interstellar_logistics_station", "orbital_collector", "energy_exchanger"].includes(building.id)) return { width: 16, height: 16 };
  if (building.kind === "storage" || building.kind === "station" || building.kind === "splitter") return { width: 12, height: 12 };
  if (building.kind === "power") return { width: 10, height: 10 };
  if (building.kind === "miner") return { width: 8, height: 8 };
  return { width: 12, height: 10 };
}
function sourceBuildingKind(building) {
  if (building.kind === "miner" || building.id === "orbital_collector") return "EXTRACTOR";
  if (building.kind === "power" || building.id === "energy_exchanger") return "POWER";
  if (["storage", "station", "splitter"].includes(building.kind)) return "STORAGE";
  return "MACHINE";
}
function storageClassFor(building) {
  if (building.id === "storage_tank") return "FLUID";
  if (building.id === "orbital_cargo_terminal") return "SPECIAL";
  if (building.id === "storage_mk1") return "BULK";
  return "COMPONENT";
}
function extractorMetadata(building) {
  if (building.id === "oil_extractor") return { resource_categories: ["liquid"], allowed_resource_ids: [itemId("crude_oil")] };
  if (building.id === "water_pump") return { resource_categories: ["liquid"], allowed_resource_ids: [itemId("water"), itemId("sulfuric_acid")] };
  if (building.id === "orbital_collector") return { resource_categories: ["gas"], allowed_resource_ids: [itemId("hydrogen"), itemId("deuterium"), itemId("fire_ice")] };
  return {
    resource_categories: ["solid"],
    allowed_resource_ids: [...rawResourceIds].filter((id) => ITEMS[id]?.kind === "solid").map(itemId),
  };
}
function buildingRuntimeMetadata(building) {
  const metadata = { power_mode: "PASSIVE" };
  if (["thermal_power_plant", "mini_fusion_power_plant", "artificial_star"].includes(building.id)) {
    const fuelSourceIds = building.id === "thermal_power_plant"
      ? Object.keys(fuelEnergyMj)
      : building.id === "mini_fusion_power_plant" ? ["deuteron_fuel_rod"] : ["antimatter_fuel_rod"];
    metadata.power_mode = "FUEL_GENERATOR";
    metadata.fuel_item_ids = fuelSourceIds.map(itemId);
    metadata.fuel_energy_mj = Object.fromEntries(fuelSourceIds.map((id) => [itemId(id), fuelEnergyMj[id]]));
    metadata.fuel_efficiency = building.id === "thermal_power_plant" ? 0.8 : 1;
  } else if (building.id === "accumulator") {
    metadata.power_mode = "BATTERY";
    metadata.energy_capacity_mj = building.energyCapacityMj;
    metadata.charge_rate_kw = building.powerChargeKw;
    metadata.discharge_rate_kw = building.powerGenerationKw;
  } else if (building.id === "energy_exchanger") {
    metadata.power_mode = "ENERGY_EXCHANGER";
    metadata.energy_capacity_mj = building.energyCapacityMj;
    metadata.energy_cell_mj = building.energyCapacityMj;
    metadata.charge_rate_kw = building.powerChargeKw;
    metadata.discharge_rate_kw = building.powerGenerationKw;
    metadata.empty_energy_item_id = itemId("accumulator");
    metadata.charged_energy_item_id = itemId("charged_accumulator");
  } else if (building.id === "ray_receiver") {
    metadata.power_mode = "RAY_RECEIVER";
    metadata.discharge_rate_kw = 6000;
  } else if (["em_rail_ejector", "vertical_launching_silo"].includes(building.id)) {
    metadata.power_mode = "LAUNCHER";
    metadata.special_effect_id = building.id === "em_rail_ejector" ? "DYSON_SAIL_LAUNCH" : "DYSON_ROCKET_LAUNCH";
  } else if (building.id === "matrix_lab") {
    metadata.power_mode = "MATRIX_LAB";
  }
  if (building.id === "spray_coater") {
    metadata.special_effect_id = "PROLIFERATOR_SERVICE";
    metadata.source_application_mode = "INLINE_MACHINE_MODIFIER";
    metadata.service_transport_mode = "ROAD_NETWORK";
    metadata.proliferator_tiers = [
      { tier: 1, item_id: itemId("proliferator_mk1"), spray_points: 12, extra_product_bonus: 0.125, speed_bonus: 0.25, power_multiplier: 1.3, required_source_technology_id: "proliferator_1" },
      { tier: 2, item_id: itemId("proliferator_mk2"), spray_points: 24, extra_product_bonus: 0.2, speed_bonus: 0.5, power_multiplier: 1.7, required_source_technology_id: "proliferator_2" },
      { tier: 3, item_id: itemId("proliferator_mk3"), spray_points: 60, extra_product_bonus: 0.25, speed_bonus: 1, power_multiplier: 2.5, required_source_technology_id: "proliferator_3" },
    ];
  }
  const effects = {
    construction_center: "CONSTRUCTION_SUPPLY",
    galactic_material_exporter: "GALACTIC_EXPORT",
    micro_black_hole_connector: "BLACK_HOLE_SINK",
    time_warp_device: "TIME_WARP",
    space_station_construction_launcher: "SYSTEM_SPACE_STATION_CONSTRUCTION",
    orbital_collector: "ORBITAL_GAS_COLLECTION",
  };
  if (effects[building.id]) metadata.special_effect_id = effects[building.id];
  if (["storage", "station", "splitter"].includes(building.kind)) metadata.warehouse_access = true;
  return metadata;
}
function recipeRuntimeMetadata(recipe) {
  if (matrixResearchVariantById.has(recipe.id)) {
    return { recipe_mode: "MATRIX", special_effect_id: "MATRIX_RESEARCH", research_points_per_cycle: matrixResearchVariantById.get(recipe.id).research_points };
  }
  if (recipe.id === "critical_photon") return { recipe_mode: "CRITICAL_PHOTON", special_effect_id: "CRITICAL_PHOTON" };
  if (recipe.id === "solar_sail_launch") return { recipe_mode: "LAUNCH", special_effect_id: "DYSON_SAIL_LAUNCH" };
  if (recipe.id === "carrier_rocket_launch") return { recipe_mode: "LAUNCH", special_effect_id: "DYSON_ROCKET_LAUNCH" };
  if (recipe.id === "ray_power") return { recipe_mode: "RAY_POWER", special_effect_id: "RAY_POWER" };
  return { recipe_mode: "STANDARD" };
}

const sourceItems = Object.values(ITEMS);
const sourceBuildings = Object.values(BUILDINGS);
const sourceRecipes = Object.values(RECIPES);
if (sourceItems.length !== 78 || sourceBuildings.length !== 39 || sourceRecipes.length !== 80 || CONSTRUCTION.length !== 42) {
  throw new Error(`Unexpected source catalog counts: ${sourceItems.length} items, ${sourceBuildings.length} buildings, ${sourceRecipes.length} recipes, ${CONSTRUCTION.length} construction entries`);
}
const constructionByBuildingId = new Map(CONSTRUCTION.map((entry) => [entry.buildingId, entry]));
for (const building of sourceBuildings) {
  if (!constructionByBuildingId.has(building.id)) throw new Error(`Source building ${building.id} has no construction definition`);
}

const factoryRecipesByBuilding = new Map();
for (const recipe of sourceRecipes) {
  const target = buildingId(recipe.buildingId);
  if (!factoryRecipesByBuilding.has(target)) factoryRecipesByBuilding.set(target, []);
  factoryRecipesByBuilding.get(target).push(recipeId(recipe.id));
}
const aliasRecipeSources = {
  assembling_machine_mk2: "assembling_machine_mk1",
  assembling_machine_mk3: "assembling_machine_mk1",
  plane_smelter: "arc_smelter",
  quantum_chemical_plant: "chemical_plant",
};

const items = sourceItems.map((item, artIndex) => ({
  id: itemId(item.id),
  name: titleFromId(item.id),
  ...storageProfile(item),
  source_id: item.id,
  source_family: "dsponline_industry_adaptation",
  art_index: artIndex,
  source_metadata: {
    source_name: item.name,
    symbol: item.symbol,
    color: item.color,
    kind: item.kind,
    description: item.description,
    raw_resource: rawResourceIds.has(item.id),
  },
  ...(fuelEnergyMj[item.id] ? { fuel_energy_mj: fuelEnergyMj[item.id] } : {}),
}));

const factoryBuildings = sourceBuildings.map((building, artIndex) => {
  const kind = sourceBuildingKind(building);
  const directRecipeIds = [...(factoryRecipesByBuilding.get(buildingId(building.id)) ?? [])];
  if (building.id === "matrix_lab") directRecipeIds.push(...matrixResearchVariants.slice(1).map((variant) => recipeId(variant.id)));
  if (building.id === "construction_center") directRecipeIds.push(...sourceBuildings.map((entry) => manufactureRecipeId(entry.id)));
  const aliasSource = aliasRecipeSources[building.id];
  if (aliasSource) directRecipeIds.push(...(factoryRecipesByBuilding.get(buildingId(aliasSource)) ?? []));
  const buildingRecipeIds = [...new Set(directRecipeIds)];
  const construction = constructionByBuildingId.get(building.id);
  const sourceTechnologyId = construction.requiredTechId;
  const result = {
    id: buildingId(building.id),
    name: titleFromId(building.id),
    kind,
    footprint: footprintFor(building),
    deployment_item_id: buildingItemId(building.id),
    source_id: building.id,
    source_family: "dsponline_industry_adaptation",
    art_index: artIndex,
    source_metadata: {
      source_name: building.name,
      short_name: building.shortName,
      source_kind: building.kind,
      description: building.description,
      speed: building.speed,
      input_capacity: building.inputCapacity,
      output_capacity: building.outputCapacity,
      accepts: building.accepts ?? "",
      tier: building.tier ?? 0,
      family: building.family ?? "",
      megastructure: Boolean(building.megastructure),
    },
    runtime_metadata: buildingRuntimeMetadata(building),
    ...requirementMetadata(sourceTechnologyId),
  };
  if (building.powerDemandKw !== undefined) result.power_demand_kw = building.powerDemandKw;
  if (building.powerGenerationKw !== undefined) result.power_generation_kw = building.powerGenerationKw;
  if (building.id === "solar_panel") result.solar_generator = true;
  if (kind === "EXTRACTOR") {
    Object.assign(result, extractorMetadata(building), {
      mining_rate_per_second: building.speed,
      resource_coverage_loss_per_missing_tile: 0.1,
      output_capacity: building.outputCapacity,
    });
  } else if (kind === "MACHINE") {
    Object.assign(result, {
      recipe_ids: buildingRecipeIds,
      speed: building.speed,
      input_capacity: building.inputCapacity || 1,
      output_capacity: building.outputCapacity || 1,
    });
  } else if (kind === "POWER") {
    // Energy exchanger charge/discharge recipes are genuine source recipes.
    // Fuel generators have empty recipe lists: their road-fed fuel behavior is
    // represented by runtime_metadata, not a fake self-manufacture recipe.
    Object.assign(result, {
      recipe_ids: buildingRecipeIds,
      input_capacity: building.inputCapacity || 1,
      output_capacity: building.outputCapacity || 1,
    });
  } else if (kind === "STORAGE") {
    Object.assign(result, {
      storage_class: storageClassFor(building),
      inventory_capacity: Math.max(100, (building.inputCapacity ?? 0) + (building.outputCapacity ?? 0)),
      loading_bays: building.id === "orbital_cargo_terminal" ? 4 : building.id === "material_delivery_hub" ? 3 : 1,
    });
  }
  return result;
});

for (const definition of factoryBuildings) {
  const building = BUILDINGS[definition.source_id];
  definition.source_metadata = {
    ...definition.source_metadata,
    source_name: building.name,
    short_name: building.shortName,
    source_kind: building.kind,
    description: building.description,
    speed: building.speed,
    input_capacity: building.inputCapacity,
    output_capacity: building.outputCapacity,
    accepts: building.accepts ?? "",
    tier: building.tier ?? 0,
    family: building.family ?? "",
    megastructure: Boolean(building.megastructure),
  };
}

const factoryRecipes = sourceRecipes.map((recipe) => {
  const matrixVariant = matrixResearchVariantById.get(recipe.id);
  return {
  id: recipeId(recipe.id),
  name: titleFromId(recipe.id),
  duration_seconds: recipe.duration,
  inputs: matrixVariant
    ? [{ item: itemId(matrixVariant.matrix_item_id), quantity: 1 }]
    : recipe.inputs.map((entry) => ({ item: itemId(entry.itemId), quantity: entry.amount })),
  outputs: recipe.outputs.map((entry) => ({ item: itemId(entry.itemId), quantity: entry.amount })),
  source_id: recipe.id,
  source_family: "dsponline_industry_adaptation",
  source_building_id: buildingId(recipe.buildingId),
  source_metadata: {
    source_name: recipe.name,
    source_building_id: recipe.buildingId,
    recursive_priority: recipe.recursivePriority ?? null,
    ...requirementMetadata(recipe.requiredTechId).source_metadata,
  },
  runtime_metadata: recipeRuntimeMetadata(recipe),
  ...requirementMetadata(recipe.requiredTechId),
  };
});

for (const matrixVariant of matrixResearchVariants.slice(1)) {
  factoryRecipes.push({
    id: recipeId(matrixVariant.id),
    name: `Research ${titleFromId(matrixVariant.matrix_item_id)}`,
    duration_seconds: RECIPES.matrix_research.duration,
    inputs: [{ item: itemId(matrixVariant.matrix_item_id), quantity: 1 }],
    outputs: [],
    source_id: matrixVariant.id,
    source_family: "dsponline_industry_adaptation",
    source_building_id: buildingId("matrix_lab"),
    source_metadata: {
      source_recipe_id: "matrix_research",
      source_name: RECIPES.matrix_research.name,
      source_inputs: RECIPES.matrix_research.inputs,
      source_outputs: RECIPES.matrix_research.outputs,
      adaptation_reason: "explicit_matrix_selection",
      research_points_not_defined_by_source: true,
      matrix_item_id: matrixVariant.matrix_item_id,
    },
    runtime_metadata: { recipe_mode: "MATRIX", special_effect_id: "MATRIX_RESEARCH", research_points_per_cycle: matrixVariant.research_points },
  });
}

for (const building of sourceBuildings) {
  const construction = constructionByBuildingId.get(building.id);
  factoryRecipes.push({
    id: manufactureRecipeId(building.id),
    name: `Manufacture ${titleFromId(building.id)}`,
    duration_seconds: 1,
    inputs: construction.costs.map((entry) => ({ item: itemId(entry.itemId), quantity: entry.amount })),
    outputs: [{ item: buildingItemId(building.id), quantity: 1 }],
    source_id: `manufacture_${building.id}`,
    source_family: "dsponline_industry_adaptation",
    source_building_id: buildingId(building.id),
    source_metadata: {
      construction_source_id: building.id,
      source_output_amount: construction.outputAmount,
      source_duration: null,
      ...requirementMetadata(construction.requiredTechId).source_metadata,
    },
    runtime_metadata: { recipe_mode: "STANDARD", source_duration_unspecified: true },
    ...requirementMetadata(construction.requiredTechId),
  });
}

for (const recipe of factoryRecipes) {
  if (RECIPES[recipe.source_id]) {
    const sourceRecipe = RECIPES[recipe.source_id];
    recipe.source_metadata = {
      ...recipe.source_metadata,
      source_name: sourceRecipe.name,
      source_building_id: sourceRecipe.buildingId,
      recursive_priority: sourceRecipe.recursivePriority ?? null,
      source_inputs: sourceRecipe.inputs,
      source_outputs: sourceRecipe.outputs,
    };
    const matrixVariant = matrixResearchVariantById.get(sourceRecipe.id);
    if (matrixVariant) {
      recipe.source_metadata.adaptation_reason = "explicit_matrix_selection";
      recipe.source_metadata.research_points_not_defined_by_source = true;
      recipe.source_metadata.matrix_item_id = matrixVariant.matrix_item_id;
    }
    continue;
  }
  const sourceBuildingId = String(recipe.source_id).replace(/^manufacture_/, "");
  const construction = constructionByBuildingId.get(sourceBuildingId);
  if (construction) {
    recipe.source_metadata = {
      ...recipe.source_metadata,
      construction_source_id: sourceBuildingId,
      source_name: construction.name,
      source_output_amount: construction.outputAmount,
      source_duration: null,
    };
  }
}

for (const building of sourceBuildings) {
  items.push({
    id: buildingItemId(building.id),
    name: `${titleFromId(building.id)} Kit`,
    category: "Building",
    storage_class: "COMPONENT",
    storage_units: 4,
    freight_class: "OVERSIZED",
    freight_units: 4,
    cargo_mass: 3,
    cargo_volume: 4,
    building_definition_id: buildingId(building.id),
    source_id: building.id,
    source_family: "dsponline_industry_adaptation",
    art_index: sourceBuildings.findIndex((entry) => entry.id === building.id),
    source_metadata: { item_role: "finished_building", source_building_id: building.id, source_name: building.name },
  });
}

const catalog = {
  version: 1,
  content_pack: "planetary_industry_dsponline_adaptation",
  provenance: {
    source_project: "DSPONLINE",
    source_package: "dsp-idle-network@1.1.5",
    source_path: "/Volumes/T9/Developer/projects/DSPONLINE/src/game/content.ts",
    source_sha256: SOURCE_SHA256,
    scope_record: "third_party/dsponline/SOURCE_SCOPE.md",
    import_tool: "tools/import_dsponline_industry.mjs",
    source_counts: { items: sourceItems.length, buildings: sourceBuildings.length, recipes: sourceRecipes.length, construction_references: CONSTRUCTION.length },
  },
  source_item_map: Object.fromEntries(sourceItems.map((item) => [item.id, itemId(item.id)])),
  source_building_map: Object.fromEntries(sourceBuildings.map((building) => [building.id, buildingId(building.id)])),
  source_technology_map: sourceTechnologyMap,
  resource_catalog: [...rawResourceIds].map((sourceId) => ({
    source_id: sourceId,
    item_id: itemId(sourceId),
    resource_category: ITEMS[sourceId].kind === "fluid" ? "liquid" : "solid",
    source_kind: ITEMS[sourceId].kind,
  })),
  construction_catalog: CONSTRUCTION.map((entry) => ({
    source_id: entry.buildingId,
    name: entry.name,
    output_amount: entry.outputAmount,
    costs: entry.costs.map((cost) => ({ item_id: itemId(cost.itemId), amount: cost.amount })),
    required_technology_id: entry.requiredTechId ?? "",
    mapped_technology_id: entry.requiredTechId ? (sourceTechnologyMap[entry.requiredTechId] ?? "") : "",
    represented_building_id: BUILDINGS[entry.buildingId] ? buildingId(entry.buildingId) : "",
  })),
  items,
  factory_buildings: factoryBuildings,
  factory_recipes: factoryRecipes,
};

function labels() {
  return {
    buildings: sourceBuildings.map((building, index) => ({ index, id: building.id, name: building.name, physical_hint: building.description })),
    items: sourceItems.map((item, index) => ({ index, id: item.id, name: item.name, physical_hint: item.description })),
  };
}

function locales() {
  const enContent = {};
  const zhContent = {};
  const enUi = {};
  const zhUi = {};
  for (const item of sourceItems) {
    enContent[itemId(item.id)] = { name: titleFromId(item.id) };
    zhContent[itemId(item.id)] = { name: item.name };
  }
  for (const building of sourceBuildings) {
    enContent[buildingItemId(building.id)] = { name: `${titleFromId(building.id)} Kit` };
    zhContent[buildingItemId(building.id)] = { name: `${building.name}套件` };
    enUi[`factory.building.${buildingId(building.id)}`] = titleFromId(building.id);
    zhUi[`factory.building.${buildingId(building.id)}`] = building.name;
    enUi[`factory.recipe.${manufactureRecipeId(building.id)}`] = `Manufacture ${titleFromId(building.id)}`;
    zhUi[`factory.recipe.${manufactureRecipeId(building.id)}`] = `制造${building.name}`;
  }
  for (const recipe of sourceRecipes) {
    enUi[`factory.recipe.${recipeId(recipe.id)}`] = titleFromId(recipe.id);
    zhUi[`factory.recipe.${recipeId(recipe.id)}`] = recipe.name;
  }
  for (const variant of matrixResearchVariants.slice(1)) {
    enUi[`factory.recipe.${recipeId(variant.id)}`] = `Research ${titleFromId(variant.matrix_item_id)}`;
    zhUi[`factory.recipe.${recipeId(variant.id)}`] = `${ITEMS[variant.matrix_item_id].name}科研`;
  }
  return { en: { content: enContent, ui: enUi }, zh_CN: { content: zhContent, ui: zhUi } };
}

if (cliArguments.includes("--labels")) {
  process.stdout.write(`${JSON.stringify(labels(), null, 2)}\n`);
} else if (cliArguments.includes("--locales")) {
  process.stdout.write(`${JSON.stringify(locales(), null, 2)}\n`);
} else {
  process.stdout.write(`${JSON.stringify(catalog, null, cliArguments.includes("--compact") ? 0 : 2)}\n`);
}
