--[[
  roblox_modPack | REALISM v3.0 (LOCAL + DYNAMIC WEATHER)
  Originales, neutrales Profil: kein Neon, keine fremden Assets, keine Remote-Requests.

  ECHTE AENDERUNGEN (wenn der Client sie erlaubt):
  * LightingStyle Realistic (Versuch + Readback, moeglicherweise gesperrt)
  * Schatten / Umgebungsreflexion / helligkeitsadaptive Beleuchtung
  * Atmosphaere, Wolken, Sonne/Mond, Film-Colorgrading
  * Terrainfarben, Wasser, Gras
  * Grosse statische Plastikflaechen -> Beton, natuerliche Strukturfarben
  * Vorhandene lokale Lichtquellen erhalten Schatten
  * Lokaler 3D-Regen / 3D-Schnee mit Dach-Raycast, Aufprall, Wind, Flocken
    (visuell simuliert; keine echten Fluids und kein Serverwetter)

  F8 = AN/AUS  |  F6 = Diagnose  |  F7 = Regen/Schnee/Aus  |  F9 = Intensitaet
  Wiederholtes Ausfuehren stoppt die aeltere Instanz und stellt Werte wieder her.
  Alle Aenderungen sind nur lokal und NICHT echte neue PBR-/Shader-Assets.
  Verwende dieses Skript nur, wo du zur lokalen Modifikation berechtigt bist.
--]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")
local UserInputService = game:GetService("UserInputService")
local LocalPlayer = Players.LocalPlayer

if not LocalPlayer then
    warn("[RM v3] Kein LocalPlayer. Dieses Skript benoetigt einen Client-Kontext.")
    return
end

local CONFIG = {
    -- Beide Varianten sind neutral und fotografisch, NICHT neonfarbig.
    Atmosphere = true,
    Clouds = true,
    SkyDiscSize = true,
    TerrainColors = true,
    TerrainWater = true,
    StaticWorldMaterials = true,
    NaturalSurfaceColors = true,
    StructuralShadows = true,
    ExistingLightShadows = true,
    DepthOfField = false,             -- unscharfe Distanz stoert viele Spiele
    ReapplyLightingEvery = 14,        -- nicht pro Frame, daher keine Dauer-Last
    MaxWorldPartsChanged = 2300,      -- FPS-/Speicher-Schutz
    MaxLightSourcesChanged = 50,
    ScanBatch = 120,
    Hotkey = Enum.KeyCode.F8,
    DetailHotkey = Enum.KeyCode.F6,
    WeatherHotkey = Enum.KeyCode.F7,
    WeatherIntensityHotkey = Enum.KeyCode.F9,
    RainDrops = 170,          -- 3D, gepoolt, nicht 2D-HUD
    SnowFlakes = 125,
    MaxSplashParts = 44,
    MaxSettledSnow = 80,
    MaxImpactsPerStep = 6,
    SnowAccumulation = true, -- lokale, zeitlich begrenzte Mini-Ablagerungen
}

local environment = _G
pcall(function()
    if type(getgenv) == "function" then
        local candidate = getgenv()
        if type(candidate) == "table" then environment = candidate end
    end
end)

if type(environment.roblox_modPack_Realism_v3) == "table" then
    local old = environment.roblox_modPack_Realism_v3
    if type(old.Stop) == "function" then pcall(old.Stop) end
end
-- Vorversion v2 stoppen: sonst laufen zwei Render-/Wetterprofile nebeneinander.
if type(environment.roblox_modPack_Realism_v2) == "table" then
    local oldV2 = environment.roblox_modPack_Realism_v2
    if type(oldV2.Stop) == "function" then pcall(oldV2.Stop) end
end
-- Alte v1 ebenfalls stoppen, sonst kaempfen zwei Grafik-Profile gegeneinander.
if type(environment.roblox_modPack_LocalRealism) == "table" then
    local oldV1 = environment.roblox_modPack_LocalRealism
    if type(oldV1.Stop) == "function" then pcall(oldV1.Stop) end
end

local SECTIONS = {"Lighting", "PostFX", "Atmosphere", "SkyClouds", "Terrain", "World", "LocalLights"}
local state = {
    running = true,
    enabled = false,
    generation = 0,
    scanning = false,
    scanComplete = false,
    worldVisited = 0,
    worldChanged = 0,
    lightsChanged = 0,
    currentMode = "NEUTRAL REALISM",
    writes = 0,
    errors = 0,
    sections = {},
    failures = {},
    lightingStyle = "nicht geprueft",
}
for _, section in ipairs(SECTIONS) do
    state.sections[section] = {changed = 0, rejected = 0}
end
environment.roblox_modPack_Realism_v3 = state

-- Originalwerte nur nach erfolgreichem Schreiben merken: kein Fake-Zaehler.
local original = {}
local terrainOriginal = {}
local created = {}
local connections = {}
local blockedProperties = {}
local graphicUi = nil
local statusButton = nil
local detailsPanel = nil
local detailsLabel = nil
local detailsVisible = false

local function formatValue(value)
    if typeof(value) == "Color3" then
        return string.format("RGB(%d,%d,%d)", value.R * 255, value.G * 255, value.B * 255)
    end
    return tostring(value)
end

local function equivalent(a, b)
    if typeof(a) ~= typeof(b) then return false end
    if typeof(a) == "number" then return math.abs(a - b) < 0.0005 end
    if typeof(a) == "Color3" then
        return math.abs(a.R - b.R) < 0.003
            and math.abs(a.G - b.G) < 0.003
            and math.abs(a.B - b.B) < 0.003
    end
    return a == b
end

local function readProperty(object, prop, fallback)
    local ok, value = pcall(function() return object[prop] end)
    if ok then return value end
    return fallback
end

local function baseline(object, prop, fallback)
    local values = original[object]
    if values and values[prop] ~= nil then return values[prop] end
    return readProperty(object, prop, fallback)
end

local function rejected(section, property, message)
    state.errors += 1
    local stats = state.sections[section]
    if stats then stats.rejected += 1 end
    if #state.failures < 12 then
        state.failures[#state.failures + 1] = section .. "." .. property .. ": " .. tostring(message)
    end
end

local function setProperty(object, prop, desired, section)
    if not object then return false end
    local blockKey = section .. ":" .. prop
    if blockedProperties[blockKey] then return false end
    local okRead, old = pcall(function() return object[prop] end)
    if not okRead then
        rejected(section, prop, "Lesen verweigert")
        blockedProperties[blockKey] = true
        return false
    end
    if equivalent(old, desired) then return true end
    local okWrite, err = pcall(function() object[prop] = desired end)
    if not okWrite then
        rejected(section, prop, err)
        blockedProperties[blockKey] = true
        return false
    end
    local okVerify, actual = pcall(function() return object[prop] end)
    if not okVerify or not equivalent(actual, desired) then
        rejected(section, prop, "Readback weicht ab (" .. formatValue(actual) .. ")")
        -- Auch bei Rundung/Clamping muss der vorherige Wert restauriert werden.
        blockedProperties[blockKey] = true
    end
    if not original[object] then original[object] = {} end
    if original[object][prop] == nil then original[object][prop] = old end
    local verified = okVerify and equivalent(actual, desired)
    if verified then
        state.writes += 1
        local bucket = state.sections[section]
        if bucket then bucket.changed += 1 end
    end
    return verified
end

local function ensureOwned(className, name, parent)
    -- Niemals eine vorhandene, spiel-eigene Instanz anhand des Namens uebernehmen.
    local success, object = pcall(function()
        local instance = Instance.new(className)
        instance.Name = name
        instance.Parent = parent
        return instance
    end)
    if success and object then
        created[#created + 1] = object
        return object
    end
    rejected("PostFX", className, object)
    return nil
end

local function safeLerp(a, b, amount)
    return a:Lerp(b, math.clamp(amount, 0, 1))
end

local function getDayWeight()
    local clock = readProperty(Lighting, "ClockTime", 12)
    -- 0 = Nacht; 1 = heller Tag; Dazwischen weicher Morgen/Abend.
    local height = math.sin((clock - 6) * math.pi / 12)
    return math.clamp((height + 0.18) / 1.1, 0, 1)
end

local function naturalLight()
    local daylight = getDayWeight()
    local indoorBase = baseline(Lighting, "Ambient", Color3.fromRGB(76, 78, 80))
    local outdoorBase = baseline(Lighting, "OutdoorAmbient", Color3.fromRGB(128, 132, 136))
    local indoorTarget = safeLerp(Color3.fromRGB(30, 34, 40), Color3.fromRGB(70, 72, 73), daylight)
    local outdoorTarget = safeLerp(Color3.fromRGB(56, 64, 79), Color3.fromRGB(145, 147, 148), daylight)

    -- Bewahrt den Charakter von Spielen; reduziert nur flaches, unphysikalisches Licht.
    setProperty(Lighting, "GlobalShadows", true, "Lighting")
    setProperty(Lighting, "ShadowSoftness", 0.25, "Lighting")
    setProperty(Lighting, "EnvironmentDiffuseScale", 0.83, "Lighting")
    setProperty(Lighting, "EnvironmentSpecularScale", 0.95, "Lighting")
    setProperty(Lighting, "Ambient", safeLerp(indoorBase, indoorTarget, 0.68), "Lighting")
    setProperty(Lighting, "OutdoorAmbient", safeLerp(outdoorBase, outdoorTarget, 0.65), "Lighting")
    setProperty(Lighting, "ExposureCompensation", math.clamp(baseline(Lighting, "ExposureCompensation", 0), -0.55, 0.45), "Lighting")

    -- Diese beiden Eigenschaften sind je nach Engine-/Sicherheitskontext gesperrt.
    -- Ein Fehlschlag steht sichtbar im Report. Kein heimlicher Erfolgsanspruch.
    if Enum.LightingStyle and Enum.LightingStyle.Realistic then
        setProperty(Lighting, "LightingStyle", Enum.LightingStyle.Realistic, "Lighting")
    end
    setProperty(Lighting, "PrioritizeLightingQuality", true, "Lighting")
    state.lightingStyle = formatValue(readProperty(Lighting, "LightingStyle", "nicht zugreifbar"))

    -- Bestehende Sonne und Zeit des Spiels bleiben erhalten.
    return daylight
end

local postEffects = {}
local function installPostFX()
    postEffects.grade = ensureOwned("ColorCorrectionEffect", "RM2_NeutralGrade", Lighting)
    if postEffects.grade then
        setProperty(postEffects.grade, "Enabled", true, "PostFX")
        setProperty(postEffects.grade, "Brightness", 0.0, "PostFX")
        setProperty(postEffects.grade, "Contrast", 0.085, "PostFX")
        setProperty(postEffects.grade, "Saturation", -0.06, "PostFX")
        setProperty(postEffects.grade, "TintColor", Color3.fromRGB(255, 254, 252), "PostFX")
    end
    postEffects.bloom = ensureOwned("BloomEffect", "RM2_OpticBloom", Lighting)
    if postEffects.bloom then
        setProperty(postEffects.bloom, "Enabled", true, "PostFX")
        setProperty(postEffects.bloom, "Intensity", 0.09, "PostFX")
        setProperty(postEffects.bloom, "Threshold", 1.75, "PostFX")
        setProperty(postEffects.bloom, "Size", 12, "PostFX")
    end
    postEffects.rays = ensureOwned("SunRaysEffect", "RM2_SoftRays", Lighting)
    if postEffects.rays then
        setProperty(postEffects.rays, "Enabled", true, "PostFX")
        setProperty(postEffects.rays, "Intensity", 0.045, "PostFX")
        setProperty(postEffects.rays, "Spread", 0.70, "PostFX")
    end
    if CONFIG.DepthOfField then
        postEffects.dof = ensureOwned("DepthOfFieldEffect", "RM2_PhotoDOF", Lighting)
        if postEffects.dof then
            setProperty(postEffects.dof, "Enabled", true, "PostFX")
            setProperty(postEffects.dof, "FarIntensity", 0.025, "PostFX")
            setProperty(postEffects.dof, "NearIntensity", 0, "PostFX")
            setProperty(postEffects.dof, "FocusDistance", 90, "PostFX")
            setProperty(postEffects.dof, "InFocusRadius", 70, "PostFX")
        end
    end
end

local function applyAtmosphere()
    if not CONFIG.Atmosphere then return end
    local atmosphere = Lighting:FindFirstChildOfClass("Atmosphere")
    if not atmosphere then
        atmosphere = ensureOwned("Atmosphere", "RM2_PhotographicAir", Lighting)
    end
    if not atmosphere then return end
    local density = baseline(atmosphere, "Density", 0.25)
    local haze = baseline(atmosphere, "Haze", 0.6)
    local glare = baseline(atmosphere, "Glare", 0.0)
    local daytime = getDayWeight()
    setProperty(atmosphere, "Density", math.clamp(density * 0.65 + 0.085, 0.12, 0.35), "Atmosphere")
    setProperty(atmosphere, "Haze", math.clamp(haze * 0.6 + 0.52, 0.4, 1.5), "Atmosphere")
    setProperty(atmosphere, "Glare", math.clamp(glare * 0.4 + 0.035, 0.025, 0.15), "Atmosphere")
    setProperty(atmosphere, "Offset", 0.03, "Atmosphere")
    local sunAir = safeLerp(Color3.fromRGB(167, 178, 194), Color3.fromRGB(206, 214, 220), daytime)
    setProperty(atmosphere, "Color", safeLerp(baseline(atmosphere, "Color", sunAir), sunAir, 0.45), "Atmosphere")
    -- Keine pinken/violetten Himmel; vorhandene Wettereffekte bleiben erkennbar.
    local decay = safeLerp(Color3.fromRGB(82, 91, 109), Color3.fromRGB(116, 125, 136), daytime)
    setProperty(atmosphere, "Decay", safeLerp(baseline(atmosphere, "Decay", decay), decay, 0.35), "Atmosphere")
end

local function applySkyAndClouds()
    local sky = Lighting:FindFirstChildOfClass("Sky")
    if sky and CONFIG.SkyDiscSize then
        -- Reale Sonne und realer Mond erscheinen klein; keine gigantischen Glows.
        setProperty(sky, "SunAngularSize", 3, "SkyClouds")
        setProperty(sky, "MoonAngularSize", 3.5, "SkyClouds")
    end
    if not CONFIG.Clouds then return end
    local terrain = Workspace:FindFirstChildOfClass("Terrain")
    if not terrain then return end
    local clouds = terrain:FindFirstChildOfClass("Clouds")
    if not clouds then clouds = ensureOwned("Clouds", "RM2_RealClouds", terrain) end
    if not clouds then return end
    setProperty(clouds, "Enabled", true, "SkyClouds")
    local oldCover = baseline(clouds, "Cover", 0.30)
    setProperty(clouds, "Cover", math.clamp(oldCover * 0.6 + 0.16, 0.22, 0.65), "SkyClouds")
    setProperty(clouds, "Density", math.clamp(baseline(clouds, "Density", 0.4) * 0.6 + 0.20, 0.31, 0.65), "SkyClouds")
    local day = getDayWeight()
    local cloudColor = safeLerp(Color3.fromRGB(167, 175, 188), Color3.fromRGB(235, 236, 237), day)
    setProperty(clouds, "Color", safeLerp(baseline(clouds, "Color", cloudColor), cloudColor, 0.6), "SkyClouds")
end

local TERRAIN_PALETTE = {
    Grass = Color3.fromRGB(89, 111, 74),
    LeafyGrass = Color3.fromRGB(82, 106, 74),
    Ground = Color3.fromRGB(119, 109, 94),
    Sand = Color3.fromRGB(177, 163, 133),
    Mud = Color3.fromRGB(93, 82, 70),
    Rock = Color3.fromRGB(105, 109, 108),
    Slate = Color3.fromRGB(99, 106, 107),
    Basalt = Color3.fromRGB(69, 71, 72),
    Limestone = Color3.fromRGB(174, 168, 148),
    Concrete = Color3.fromRGB(155, 156, 153),
    Pavement = Color3.fromRGB(124, 126, 126),
    Snow = Color3.fromRGB(234, 237, 238),
    Ice = Color3.fromRGB(185, 207, 213),
    WoodPlanks = Color3.fromRGB(141, 113, 83),
}

local function applyTerrain()
    local terrain = Workspace:FindFirstChildOfClass("Terrain")
    if not terrain then return end
    if CONFIG.TerrainWater then
        local naturalWater = Color3.fromRGB(44, 91, 102)
        setProperty(terrain, "WaterColor", safeLerp(baseline(terrain, "WaterColor", naturalWater), naturalWater, 0.78), "Terrain")
        setProperty(terrain, "WaterReflectance", 0.46, "Terrain")
        setProperty(terrain, "WaterTransparency", 0.38, "Terrain")
        setProperty(terrain, "WaterWaveSize", 0.16, "Terrain")
        setProperty(terrain, "WaterWaveSpeed", 10, "Terrain")
        setProperty(terrain, "GrassLength", 0.55, "Terrain")
    end
    if not CONFIG.TerrainColors then return end
    for name, target in pairs(TERRAIN_PALETTE) do
        local material = Enum.Material[name]
        if material then
            local ok, old = pcall(function() return terrain:GetMaterialColor(material) end)
            if ok then
                local baseColor = terrainOriginal[name] or old
                local newColor = baseColor:Lerp(target, 0.42)
                if not equivalent(newColor, old) then
                    local okWrite, err = pcall(function() terrain:SetMaterialColor(material, newColor) end)
                    if okWrite then
                        local key = name
                        if terrainOriginal[key] == nil then terrainOriginal[key] = old end
                        local okCheck, current = pcall(function() return terrain:GetMaterialColor(material) end)
                        if okCheck and equivalent(current, newColor) then
                            state.sections.Terrain.changed += 1
                            state.writes += 1
                        else
                            rejected("Terrain", "SetMaterialColor(" .. name .. ")", "Readback weicht ab")
                        end
                    else
                        rejected("Terrain", "SetMaterialColor(" .. name .. ")", err)
                    end
                end
            else
                rejected("Terrain", "GetMaterialColor(" .. name .. ")", old)
            end
        end
    end
end

local function isInCharacterOrTool(inst)
    local ancestor = inst.Parent
    local levels = 0
    while ancestor and ancestor ~= Workspace and levels < 8 do
        if ancestor:IsA("Tool") or ancestor:IsA("Accessory") then return true end
        if ancestor:IsA("Model") and ancestor:FindFirstChildOfClass("Humanoid") then return true end
        ancestor = ancestor.Parent
        levels += 1
    end
    return false
end

local function hasArtwork(part)
    for _, child in ipairs(part:GetChildren()) do
        if child:IsA("Texture") or child:IsA("Decal") or child:IsA("SurfaceAppearance")
            or child:IsA("SurfaceGui") or child:IsA("SpecialMesh") then
            return true
        end
    end
    return false
end

local function staticGeometry(part)
    if not part:IsA("Part") or not part.Anchored or not part.CanCollide then return false end
    if part.Transparency > 0.08 or isInCharacterOrTool(part) then return false end
    if part.Shape ~= Enum.PartType.Block or hasArtwork(part) then return false end
    if part.Material == Enum.Material.Neon or part.Material == Enum.Material.Glass then return false end
    local s = part.Size
    if s.Magnitude < 9 then return false end
    return true
end

local function photographicSurface(part)
    if not state.running or not state.enabled then return end
    if state.worldChanged >= CONFIG.MaxWorldPartsChanged then return end
    if not staticGeometry(part) then return end

    local changed = false
    local h, saturation, value = part.Color:ToHSV()
    local size = part.Size
    local largest = math.max(size.X, size.Y, size.Z)
    local isStructure = largest >= 9 and (size.Y >= 5 or (size.X >= 9 and size.Z >= 9))
    local neutral = saturation < 0.22 and value > 0.15 and value < 0.98

    -- Grosse glatte, graue Plastik-Waende und Boeden sind ein haeufiges
    -- Roblox-Problem: sie erhalten eine echte Engine-Betonmaterialstruktur.
    -- Keine Neonschilder, Spielmechanik, Terrainvoxel oder Custom-Meshes.
    if CONFIG.StaticWorldMaterials and isStructure and neutral and (
        part.Material == Enum.Material.Plastic or part.Material == Enum.Material.SmoothPlastic
    ) then
        local before = readProperty(part, "Material", nil)
        setProperty(part, "Material", Enum.Material.Concrete, "World")
        if before ~= readProperty(part, "Material", nil) then changed = true end
    end

    -- Statisch gerenderte Geometrie soll Schatten werfen.
    if CONFIG.StructuralShadows and isStructure and not part.CastShadow then
        if setProperty(part, "CastShadow", true, "World") then changed = true end
    end

    -- Stark uebersaettigte GROSSE Wandfarben werden leicht entsaettigt.
    -- Nicht bei interaktiven, bewegten, transparenten oder texturierten Objekten.
    if CONFIG.NaturalSurfaceColors and isStructure and saturation > 0.74 and value > 0.4
        and part.Material ~= Enum.Material.Neon then
        local softer = Color3.fromHSV(h, math.max(0.48, saturation * 0.78), value)
        if setProperty(part, "Color", softer, "World") then changed = true end
    end

    -- Kleine Reflexionswerte nur an bereits vom Spiel als Metall/Ice
    -- markierten soliden Oberflaechen. Keine Fake-Spiegel.
    if part.Material == Enum.Material.Metal or part.Material == Enum.Material.DiamondPlate then
        local originalReflectance = baseline(part, "Reflectance", 0)
        if originalReflectance < 0.055 then
            if setProperty(part, "Reflectance", 0.055, "World") then changed = true end
        end
    end
    if changed then state.worldChanged += 1 end
end

local function improveLight(instance)
    if not CONFIG.ExistingLightShadows or state.lightsChanged >= CONFIG.MaxLightSourcesChanged then return end
    if instance:IsA("PointLight") or instance:IsA("SpotLight") or instance:IsA("SurfaceLight") then
        if instance.Enabled and instance.Brightness > 0.2 and instance.Range > 3 then
            if not instance.Shadows then
                local success = setProperty(instance, "Shadows", true, "LocalLights")
                if success then state.lightsChanged += 1 end
            end
        end
    end
end

local function scanWorldAsync()
    if not state.enabled or not state.running or state.scanning then return end
    state.scanning = true
    state.scanComplete = false
    state.generation += 1
    local scanGeneration = state.generation

    task.spawn(function()
        local ok, descendants = pcall(function() return Workspace:GetDescendants() end)
        if not ok then
            rejected("World", "GetDescendants", descendants)
            state.scanning = false
            return
        end
        for index, instance in ipairs(descendants) do
            if not state.running or not state.enabled or state.generation ~= scanGeneration then break end
            state.worldVisited += 1
            if instance:IsA("BasePart") then photographicSurface(instance) end
            if instance:IsA("Light") then improveLight(instance) end
            if index % CONFIG.ScanBatch == 0 then task.wait() end
            if state.worldChanged >= CONFIG.MaxWorldPartsChanged
                and state.lightsChanged >= CONFIG.MaxLightSourcesChanged then break end
        end
        if state.generation == scanGeneration then
            state.scanComplete = true
            state.scanning = false
            print(string.format(
                "[RM v3] Scan: %d Instanzen, %d Weltoberflaechen, %d Lichtquellen geaendert.",
                state.worldVisited, state.worldChanged, state.lightsChanged
            ))
        end
    end)
end

local function applyAll()
    naturalLight()
    installPostFX()
    applyAtmosphere()
    applySkyAndClouds()
    applyTerrain()
    scanWorldAsync()
end

--[[
  WEATHER v3: RAIN / SNOW / OFF. Client-only 3D geometry (not a screen overlay).
  The visual droplets/flakes and splashes are local visual simulations; no
  server weather, physical flooding, or actual water/snow accumulation physics.
  Raycast-based ceilings/impacts; pooled non-colliding parts; 30 Hz update cap.
--]]
local weather = {
    mode = "OFF", folder = nil, droplets = {}, impacts = {}, deposits = {}, buildToken = 0,
    rayParams = nil, stepTime = 0, skyTime = 0, indoorTime = 0,
    indoor = false, hits = 0, roofs = 0, failedSpawns = 0,
    totalSpawned = 0, impactIndex = 0, depositIndex = 0,
}
state.weatherMode = "RAIN" -- Standard; F7: RAIN -> SNOW -> OFF
state.weatherIntensity = 1.0
state.weatherIndoor = false
state.weatherLiveParticles = 0
state.weatherImpacts = 0

local rainColor = Color3.fromRGB(181, 196, 204)
local snowColor = Color3.fromRGB(230, 235, 238)
local weatherButton = nil
local rng = Random.new()
local function rand(a, b) return rng:NextNumber(a, b) end

local function weatherWind(t, snow)
    local worldWind = readProperty(Workspace, "GlobalWind", Vector3.zero)
    if typeof(worldWind) ~= "Vector3" then worldWind = Vector3.zero end
    local raw = Vector3.new(worldWind.X, 0, worldWind.Z)
    if raw.Magnitude > 18 then raw = raw.Unit * 18 end
    local gust = Vector3.new(math.sin(t * 0.29) * 2.2, 0, math.cos(t * 0.23) * 1.8)
    return (raw * (snow and 0.48 or 0.25)) + gust
end

local function weatherPart(name, shape, size, color, transparency)
    local p = Instance.new("Part")
    p.Name = name
    p.Anchored = true
    p.CanCollide = false
    p.CanTouch = false
    p.CanQuery = false
    p.CastShadow = false
    p.Material = Enum.Material.SmoothPlastic
    p.Shape = shape
    p.Size = size
    p.Color = color
    p.Transparency = transparency
    p.CFrame = CFrame.new(0, -10000, 0)
    p.Parent = weather.folder
    return p
end

local function roofAbove(pos)
    if not weather.rayParams then return false end
    local roof = Workspace:Raycast(pos + Vector3.new(0, 0.3, 0), Vector3.new(0, 180, 0), weather.rayParams)
    return roof ~= nil
end

local function makeImpact(pos, mode)
    if not weather.folder or #weather.impacts == 0 then return end
    local count = mode == "RAIN" and 2 or 1
    for _ = 1, count do
        weather.impactIndex = (weather.impactIndex % #weather.impacts) + 1
        local imp = weather.impacts[weather.impactIndex]
        imp.ttl = rand(0.12, mode == "RAIN" and 0.28 or 0.42)
        imp.maxLife = imp.ttl
        imp.pos = pos + Vector3.new(0, 0.05, 0)
        imp.vel = Vector3.new(rand(-2.5, 2.5), rand(2, 5), rand(-2.5, 2.5))
        imp.part.Color = mode == "RAIN" and rainColor or snowColor
        imp.part.Transparency = 0.24
        local radius = mode == "RAIN" and rand(0.055, 0.095) or rand(0.065, 0.12)
        imp.part.Size = Vector3.new(radius, radius, radius)
    end
    weather.hits += 1
    state.weatherImpacts = weather.hits
end

local function settleFlake(pos, normal)
    if #weather.deposits == 0 or normal.Y < 0.83 or rand(0, 1) > 0.18 then return end
    weather.depositIndex = (weather.depositIndex % #weather.deposits) + 1
    local flake = weather.deposits[weather.depositIndex]
    flake.ttl = rand(18, 32)
    flake.maxLife = flake.ttl
    local size = rand(0.12, 0.28)
    flake.part.Size = Vector3.new(size * 1.4, size * 0.35, size * 1.15)
    flake.part.CFrame = CFrame.new(pos + normal * (size * 0.22)) * CFrame.Angles(0, rand(0, math.pi * 2), 0)
    flake.part.Transparency = 0.16
end

local function resetDroplet(drop, center, timeNow)
    if not weather.folder or not center then return end
    drop.age = 0
    drop.active = false
    drop.cooldown = 0.0
    drop.part.Transparency = 1
    local isSnow = weather.mode == "SNOW"
    local wind = weatherWind(timeNow, isSnow)

    -- Not at the top of the camera: varied depths make the volume look natural.
    for _ = 1, 6 do
        local rad = isSnow and 39 or 43
        local x = rand(-rad, rad)
        local z = rand(-rad, rad)
        -- Near the player, prefer open sky. Outside the building still visible.
        if weather.indoor and x * x + z * z < 90 then
            x += (x >= 0 and 12 or -12)
        end
        local y = rand(isSnow and 9 or 13, isSnow and 36 or 43)
        local origin = center + Vector3.new(x, y, z)
        if not roofAbove(origin) then
            drop.pos = origin
            drop.vel = isSnow
                and Vector3.new(wind.X + rand(-2.8, 2.8), -rand(5.5, 11), wind.Z + rand(-2.8, 2.8))
                or Vector3.new(wind.X + rand(-1.0, 1.0), -rand(90, 121), wind.Z + rand(-1.0, 1.0))
            local rayLength = isSnow and 100 or 160
            drop.hit = Workspace:Raycast(origin, Vector3.new(drop.vel.X * 0.60, -rayLength, drop.vel.Z * 0.60), weather.rayParams)
            drop.age = 0
            drop.recast = rand(0.28, 0.8)
            drop.active = true
            local size = isSnow and rand(0.115, 0.25) or rand(0.03, 0.055)
            if isSnow then
                drop.part.Shape = Enum.PartType.Ball
                drop.part.Size = Vector3.new(size, size, size)
                drop.part.Color = snowColor
                drop.part.Transparency = rand(0.07, 0.27)
            else
                drop.part.Shape = Enum.PartType.Block
                drop.part.Size = Vector3.new(size, rand(0.95, 2.1), size)
                drop.part.Color = rainColor
                drop.part.Transparency = rand(0.4, 0.67)
            end
            drop.visible = drop.part.Transparency
            weather.totalSpawned += 1
            return
        end
        weather.roofs += 1
    end
    drop.cooldown = rand(0.16, 0.45)
    weather.failedSpawns += 1
end

local function weatherSky()
    if not state.enabled or state.weatherMode == "OFF" then return end
    local rain = state.weatherMode == "RAIN"
    local clouds = Workspace.Terrain and Workspace.Terrain:FindFirstChildOfClass("Clouds")
    if clouds then
        setProperty(clouds, "Enabled", true, "SkyClouds")
        setProperty(clouds, "Cover", rain and 0.85 or 0.88, "SkyClouds")
        setProperty(clouds, "Density", rain and 0.73 or 0.68, "SkyClouds")
        setProperty(clouds, "Color", rain and Color3.fromRGB(158, 166, 169) or Color3.fromRGB(204, 208, 211), "SkyClouds")
    end
    local atmosphere = Lighting:FindFirstChildOfClass("Atmosphere")
    if atmosphere then
        setProperty(atmosphere, "Haze", rain and 2.2 or 1.55, "Atmosphere")
        setProperty(atmosphere, "Density", rain and 0.31 or 0.26, "Atmosphere")
        setProperty(atmosphere, "Glare", 0.01, "Atmosphere")
        setProperty(atmosphere, "Color", rain and Color3.fromRGB(190, 201, 208) or Color3.fromRGB(215, 225, 232), "Atmosphere")
    end
    local base = baseline(Lighting, "ExposureCompensation", 0)
    setProperty(Lighting, "ExposureCompensation", math.clamp(base - (rain and 0.16 or 0.06), -1, 0.7), "Lighting")
end

local function destroyWeather()
    weather.mode = "OFF"
    weather.buildToken += 1
    weather.droplets = {}
    weather.impacts = {}
    weather.deposits = {}
    weather.rayParams = nil
    if weather.folder then
        pcall(function() weather.folder:Destroy() end)
        weather.folder = nil
    end
    state.weatherLiveParticles = 0
    state.weatherIndoor = false
end

local function buildWeather()
    destroyWeather()
    if not state.running or not state.enabled or state.weatherMode == "OFF" then return end
    weather.mode = state.weatherMode
    local myBuildToken = weather.buildToken
    weather.folder = Instance.new("Folder")
    weather.folder.Name = "RM3_LOCAL_WEATHER_VISUALS"
    weather.folder.Parent = Workspace
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = { weather.folder, LocalPlayer.Character }
    params.IgnoreWater = false
    params.RespectCanCollide = true
    weather.rayParams = params
    weather.stepTime = 0
    weather.indoorTime = 1
    weather.hits = 0
    state.weatherImpacts = 0
    weather.roofs = 0
    weather.failedSpawns = 0
    local snow = weather.mode == "SNOW"
    local count = math.floor((snow and CONFIG.SnowFlakes or CONFIG.RainDrops) * state.weatherIntensity)
    count = math.clamp(count, 50, 250)
    for i = 1, count do
        local part = weatherPart(snow and "SnowFlake" or "RainDrop", snow and Enum.PartType.Ball or Enum.PartType.Block,
            snow and Vector3.new(0.16, 0.16, 0.16) or Vector3.new(0.035, 1.5, 0.035),
            snow and snowColor or rainColor, 1)
        weather.droplets[#weather.droplets + 1] = {part = part, age = 0, cooldown = rand(0, 0.9), active = false}
        if i % 35 == 0 then task.wait() end
        if not state.running or not state.enabled or not weather.folder or state.weatherMode ~= weather.mode or myBuildToken ~= weather.buildToken then return end
    end
    for i = 1, CONFIG.MaxSplashParts do
        local part = weatherPart("WaterSplash", Enum.PartType.Ball, Vector3.new(0.06, 0.06, 0.06), rainColor, 1)
        weather.impacts[#weather.impacts + 1] = {part = part, ttl = 0, maxLife = 1}
    end
    if snow and CONFIG.SnowAccumulation then
        for i = 1, CONFIG.MaxSettledSnow do
            local part = weatherPart("SettledSnow", Enum.PartType.Block, Vector3.new(0.2, 0.035, 0.2), snowColor, 1)
            weather.deposits[#weather.deposits + 1] = {part = part, ttl = 0, maxLife = 1}
        end
    end
    weatherSky()
end

local function setWeatherMode(mode)
    if mode ~= "RAIN" and mode ~= "SNOW" and mode ~= "OFF" then return end
    state.weatherMode = mode
    if state.enabled then
        buildWeather()
        if mode == "OFF" then
            -- Revert to neutral v2 sky, without removing user-defined sky objects.
            naturalLight()
            applyAtmosphere()
            applySkyAndClouds()
        end
    end
    print("[RM v3] Wetter: " .. mode .. " | Intensitaet: " .. tostring(state.weatherIntensity))
end
state.SetWeatherMode = setWeatherMode
local function cycleWeather()
    if state.weatherMode == "RAIN" then
        setWeatherMode("SNOW")
    elseif state.weatherMode == "SNOW" then
        setWeatherMode("OFF")
    else
        setWeatherMode("RAIN")
    end
end
state.CycleWeather = cycleWeather
local function cycleWeatherIntensity()
    if state.weatherIntensity < 0.8 then
        state.weatherIntensity = 1.0
    elseif state.weatherIntensity < 1.3 then
        state.weatherIntensity = 1.5
    else
        state.weatherIntensity = 0.6
    end
    if state.enabled and state.weatherMode ~= "OFF" then buildWeather() end
end
state.CycleWeatherIntensity = cycleWeatherIntensity

local function weatherStep(dt)
    if not state.running or not state.enabled or not weather.folder or not weather.rayParams then return end
    if #weather.droplets == 0 then return end
    local cam = Workspace.CurrentCamera
    if not cam then return end
    local center = cam.CFrame.Position + cam.CFrame.LookVector * 8
    local now = os.clock()
    if weather.indoorTime >= 0.55 then
        weather.indoorTime = 0
        weather.rayParams.FilterDescendantsInstances = { weather.folder, LocalPlayer.Character }
        local top = Workspace:Raycast(cam.CFrame.Position + Vector3.new(0, 1, 0), Vector3.new(0, 185, 0), weather.rayParams)
        weather.indoor = top ~= nil
        state.weatherIndoor = weather.indoor
    end
    local snow = weather.mode == "SNOW"
    local currentWind = weatherWind(now, snow)
    local visible = 0
    local impactsThisStep = 0
    for _, drop in ipairs(weather.droplets) do
        if not drop.active then
            drop.cooldown -= dt
            if drop.cooldown <= 0 then resetDroplet(drop, center, now) end
        else
            drop.age += dt
            local v = drop.vel
            if snow then
                v = Vector3.new(v.X * 0.97 + currentWind.X * 0.03 + math.sin(now * 1.3 + drop.age * 2) * dt,
                    v.Y, v.Z * 0.97 + currentWind.Z * 0.03 + math.cos(now * 1.17 + drop.age * 2) * dt)
                drop.vel = v
                drop.recast -= dt
                if drop.recast <= 0 then
                    drop.recast = rand(0.45, 0.90)
                    drop.hit = Workspace:Raycast(drop.pos, Vector3.new(v.X * 0.8, -75, v.Z * 0.8), weather.rayParams)
                end
            end
            local pos = drop.pos + v * dt
            drop.pos = pos
            local hit = drop.hit
            local collision = hit ~= nil and pos.Y <= hit.Position.Y + (snow and 0.10 or 0.25)
            local distance = pos - cam.CFrame.Position
            local expired = distance.Y < -50 or distance.Y > 64 or math.abs(distance.X) > 62
                or math.abs(distance.Z) > 62 or drop.age > (snow and 10 or 1.7)
            if collision or expired then
                if collision and impactsThisStep < CONFIG.MaxImpactsPerStep and distance.Magnitude < 55 then
                    if hit.Normal.Y > 0.42 then
                        makeImpact(hit.Position, weather.mode)
                        impactsThisStep += 1
                        if snow then settleFlake(hit.Position, hit.Normal) end
                    end
                end
                drop.active = false
                drop.part.Transparency = 1
                drop.cooldown = rand(0, 0.18)
            else
                drop.part.CFrame = snow
                    and CFrame.new(pos)
                    or (CFrame.lookAt(pos, pos + v, Vector3.new(1, 0, 0)) * CFrame.Angles(math.pi / 2, 0, 0))
                -- Proximity falloff and fade near ground (no bright opaque white lines).
                local alpha = math.clamp((distance.Magnitude - 1) / 4, 0, 1)
                drop.part.Transparency = math.clamp(1 - (1 - drop.visible) * alpha, 0, 1)
                visible += 1
            end
        end
    end
    state.weatherLiveParticles = visible

    for _, imp in ipairs(weather.impacts) do
        if imp.ttl > 0 then
            imp.ttl -= dt
            imp.vel += Vector3.new(0, -24 * dt, 0)
            imp.pos += imp.vel * dt
            imp.part.CFrame = CFrame.new(imp.pos)
            imp.part.Transparency = math.clamp(1 - 0.7 * (imp.ttl / imp.maxLife), 0, 1)
            if imp.ttl <= 0 then imp.part.Transparency = 1 end
        end
    end
    for _, d in ipairs(weather.deposits) do
        if d.ttl > 0 then
            d.ttl -= dt
            d.part.Transparency = math.clamp(0.18 + 0.8 * (1 - d.ttl / d.maxLife), 0, 1)
            if d.ttl <= 0 then d.part.Transparency = 1 end
        end
    end
end

connections[#connections + 1] = RunService.Heartbeat:Connect(function(dt)
    if not state.running or not state.enabled or not weather.folder then return end
    -- Limit visual updates to 30Hz, with no physics changes to any game object.
    weather.stepTime += math.min(dt, 0.08)
    weather.indoorTime += math.min(dt, 0.08)
    if weather.stepTime < 1 / 30 then return end
    local elapsed = math.min(weather.stepTime, 0.065)
    weather.stepTime = 0
    weatherStep(elapsed)
end)

local function restore()
    destroyWeather()
    state.generation += 1 -- laufende Scanner abbrechen
    state.scanning = false
    for instance, props in pairs(original) do
        for property, oldValue in pairs(props) do
            pcall(function() instance[property] = oldValue end)
        end
    end
    local terrain = Workspace:FindFirstChildOfClass("Terrain")
    if terrain then
        for materialName, oldColor in pairs(terrainOriginal) do
            pcall(function() terrain:SetMaterialColor(Enum.Material[materialName], oldColor) end)
        end
    end
    for i = #created, 1, -1 do
        pcall(function() created[i]:Destroy() end)
    end
    original = {}
    terrainOriginal = {}
    created = {}
    postEffects = {}
    state.worldChanged = 0
    state.lightsChanged = 0
    state.worldVisited = 0
    state.scanComplete = false
end

local function report()
    local out = {
        "roblox_modPack REALISM v3 | " .. (state.enabled and "AN" or "AUS"),
        "LightingStyle: " .. state.lightingStyle,
        string.format("Wetter: %s | Intensitaet %.1fx | innen: %s", state.weatherMode, state.weatherIntensity, tostring(state.weatherIndoor)),
        string.format("3D-Flocken/Tropfen sichtbar: %d | Kollisionen: %d | Dach-Sperren: %d", state.weatherLiveParticles, state.weatherImpacts, weather.roofs),
        string.format("Erfolgreiche Schreiboperationen: %d", state.writes),
        string.format("Scan: %d Objekte | %d Weltflaechen | %d Lichtquellen", state.worldVisited, state.worldChanged, state.lightsChanged),
    }
    for _, section in ipairs(SECTIONS) do
        local stat = state.sections[section]
        out[#out + 1] = string.format("%s: %d geaendert / %d verweigert", section, stat.changed, stat.rejected)
    end
    if #state.failures > 0 then
        out[#out + 1] = "API-Grenzen/Fehler (erste " .. #state.failures .. "):"
        for _, text in ipairs(state.failures) do out[#out + 1] = " - " .. text end
    end
    out[#out + 1] = "Keine neuen Shader, SSR oder PBR-Texturen in fremden Spielen."
    return table.concat(out, "\n")
end
state.GetReport = report
state.PrintReport = function() print("[RM v3]\n" .. report()) end

local function updateUI()
    if statusButton then
        statusButton.Text = state.enabled and "REALISM  AN  | F8" or "REALISM  AUS  | F8"
        statusButton.BackgroundColor3 = state.enabled and Color3.fromRGB(53, 59, 60) or Color3.fromRGB(44, 45, 47)
    end
    if weatherButton then
        weatherButton.Text = string.format("WETTER %s  %.1fx | F7", state.weatherMode, state.weatherIntensity)
        weatherButton.BackgroundColor3 = Color3.fromRGB(47, 51, 54)
    end
    if detailsPanel then detailsPanel.Visible = detailsVisible end
    if detailsLabel then detailsLabel.Text = report() end
end

local function setEnabled(enabled)
    if not state.running or state.enabled == enabled then return end
    if enabled then
        state.enabled = true
        applyAll()
        buildWeather()
    else
        state.enabled = false
        restore()
    end
    updateUI()
end
state.SetEnabled = setEnabled

function state.Stop()
    if not state.running then return end
    if state.enabled then setEnabled(false) end
    state.running = false
    for _, connection in ipairs(connections) do
        pcall(function() connection:Disconnect() end)
    end
    connections = {}
    if graphicUi then pcall(function() graphicUi:Destroy() end) end
    if environment.roblox_modPack_Realism_v3 == state then
        environment.roblox_modPack_Realism_v3 = nil
    end
end

-- Unsichtbare Mauskontrolle ist bewusst NICHT enthalten. Dezent und lesbar.
local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui") or LocalPlayer:WaitForChild("PlayerGui", 12)
if playerGui then
    graphicUi = Instance.new("ScreenGui")
    graphicUi.Name = "RM2_LocalGraphicsDiagnostics"
    graphicUi.ResetOnSpawn = false
    graphicUi.IgnoreGuiInset = false
    graphicUi.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    graphicUi.DisplayOrder = 20
    graphicUi.Parent = playerGui

    statusButton = Instance.new("TextButton")
    statusButton.Name = "Status"
    statusButton.Size = UDim2.fromOffset(174, 32)
    statusButton.Position = UDim2.new(1, -186, 0, 10)
    statusButton.TextColor3 = Color3.fromRGB(235, 237, 238)
    statusButton.TextSize = 12
    statusButton.Font = Enum.Font.GothamSemibold
    statusButton.BorderSizePixel = 0
    statusButton.BackgroundColor3 = Color3.fromRGB(45, 47, 47)
    statusButton.Parent = graphicUi
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 6)
    corner.Parent = statusButton

    detailsPanel = Instance.new("Frame")
    detailsPanel.Name = "Details"
    detailsPanel.Size = UDim2.fromOffset(340, 403)
    detailsPanel.Position = UDim2.new(1, -352, 0, 87)
    detailsPanel.BackgroundColor3 = Color3.fromRGB(27, 29, 31)
    detailsPanel.BorderSizePixel = 0
    detailsPanel.Visible = false
    detailsPanel.Parent = graphicUi
    local frameCorner = Instance.new("UICorner")
    frameCorner.CornerRadius = UDim.new(0, 7)
    frameCorner.Parent = detailsPanel

    detailsLabel = Instance.new("TextLabel")
    detailsLabel.Name = "ActualChanges"
    detailsLabel.Size = UDim2.new(1, -20, 1, -16)
    detailsLabel.Position = UDim2.fromOffset(10, 8)
    detailsLabel.BackgroundTransparency = 1
    detailsLabel.TextSize = 12
    detailsLabel.TextColor3 = Color3.fromRGB(225, 229, 230)
    detailsLabel.Font = Enum.Font.Code
    detailsLabel.TextXAlignment = Enum.TextXAlignment.Left
    detailsLabel.TextYAlignment = Enum.TextYAlignment.Top
    detailsLabel.TextWrapped = true
    detailsLabel.TextTruncate = Enum.TextTruncate.AtEnd
    detailsLabel.Parent = detailsPanel

    weatherButton = Instance.new("TextButton")
    weatherButton.Name = "Weather"
    weatherButton.Size = UDim2.fromOffset(174, 32)
    weatherButton.Position = UDim2.new(1, -186, 0, 47)
    weatherButton.TextColor3 = Color3.fromRGB(234, 237, 238)
    weatherButton.TextSize = 11
    weatherButton.Font = Enum.Font.GothamSemibold
    weatherButton.BorderSizePixel = 0
    weatherButton.BackgroundColor3 = Color3.fromRGB(47, 51, 54)
    weatherButton.Parent = graphicUi
    local weatherCorner = Instance.new("UICorner")
    weatherCorner.CornerRadius = UDim.new(0, 6)
    weatherCorner.Parent = weatherButton
    connections[#connections + 1] = weatherButton.MouseButton1Click:Connect(function()
        cycleWeather()
        updateUI()
    end)

    connections[#connections + 1] = statusButton.MouseButton1Click:Connect(function()
        detailsVisible = not detailsVisible
        updateUI()
    end)
end

connections[#connections + 1] = UserInputService.InputBegan:Connect(function(input, processed)
    if processed then return end
    if input.KeyCode == CONFIG.Hotkey then
        setEnabled(not state.enabled)
    elseif input.KeyCode == CONFIG.DetailHotkey then
        detailsVisible = not detailsVisible
        updateUI()
    elseif input.KeyCode == CONFIG.WeatherHotkey then
        cycleWeather()
        updateUI()
    elseif input.KeyCode == CONFIG.WeatherIntensityHotkey then
        cycleWeatherIntensity()
        updateUI()
    end
end)

connections[#connections + 1] = Workspace.DescendantAdded:Connect(function(instance)
    if not state.running or not state.enabled then return end
    -- Neu gestreamte Weltinhalte; keine teuren rekursiven Vollscans pro Frame.
    if instance:IsA("BasePart") and state.worldChanged < CONFIG.MaxWorldPartsChanged then
        task.defer(function()
            if state.enabled and instance:IsDescendantOf(Workspace) then photographicSurface(instance) end
        end)
    elseif instance:IsA("Light") and state.lightsChanged < CONFIG.MaxLightSourcesChanged then
        task.defer(function()
            if state.enabled and instance:IsDescendantOf(Workspace) then improveLight(instance) end
        end)
    end
end)

-- Dynamischen Tagesablauf behalten: keine fixe 12-Uhr-Sonne.
-- Bei Spielen, die fremde Lichtwerte sehr oft setzen, kann das Ergebnis variieren.
task.spawn(function()
    local lastSunBucket = -1
    local lastApply = 0
    local lastEnvironmentApply = 0
    while state.running do
        task.wait(2.0)
        if state.running and state.enabled then
            local clock = readProperty(Lighting, "ClockTime", 12)
            local bucket = math.floor(clock * 4)
            local now = os.clock()
            if bucket ~= lastSunBucket or now - lastApply > CONFIG.ReapplyLightingEvery then
                lastSunBucket = bucket
                lastApply = now
                naturalLight()
                weatherSky()
            end
            if now - lastEnvironmentApply > 24 then
                lastEnvironmentApply = now
                applyAtmosphere()
                applySkyAndClouds()
                applyTerrain()
                weatherSky()
            end
        end
        updateUI()
    end
end)

setEnabled(true)
state.PrintReport()
print("[RM v3] F8 an/aus | F6 Bericht | F7 Regen/Schnee/Aus | F9 Wetterstaerke. Nur lokale Grafik.")
