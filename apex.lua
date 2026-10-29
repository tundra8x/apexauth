--!nocheck
-- Close this build's previous session before constructing a new menu.
do
    local environment = type(getgenv) == "function" and getgenv() or _G
    local previous = environment.ApexSession
    if type(previous) == "table" and type(previous.Unload) == "function" then pcall(previous.Unload) end
end

-- Runtime kept behind a small menu adapter. No downloaded UI, global hooks, or stack offsets.
local function createApexRuntime(api)
    local state, player = api.state, api.player
    local services = {}
    for _, name in ipairs({"Players", "UserInputService", "RunService", "Lighting", "CollectionService", "ReplicatedStorage", "ReplicatedFirst", "TeleportService"}) do services[name] = game:GetService(name) end
    local engine = {active = true, suspended = false, actors = {}, world = {}, pools = {}, overrides = {}, groups = {}, connections = {}, counters = {players = 0, zombies = 0, items = 0}, modules = {}}
    local keyCodes = {}
    for _, key in ipairs(Enum.KeyCode:GetEnumItems()) do keyCodes[key.Name:lower()] = key end
    local input, run, lighting, collection = services.UserInputService, services.RunService, services.Lighting, services.CollectionService
    local nextActors, nextOverlay, nextProperties, nextMovementProbe = 0, 0, 0, 0
    local target, targetPart, triggerTarget, triggerAt, nextTrigger = nil, nil, nil, 0, 0
    local mouseCarry = Vector2.new(0, 0)
    local ownedHighlights, worldSeen = {}, {}
    local drawGui, overlayRoot, circles, hbe, zombieTracker
    local viewmodel, viewmodelParts, viewmodelConnection, viewmodelSeen = nil, {}, nil, {}
    local spinAngle, spinning = 0, false
    local flyAttachment, flyVelocity, flyRoot, movementCache
    local localParts, localPartsModel, localCharacterConnection = {}, nil, nil
    local itemClassById, itemRegistrySource, itemScanBusy, nextItemScan = {}, nil, false, 0
    local itemDiagnostics = {registry = "idle", mapped = 0, scans = 0}
    local itemCategories, itemCategoryByName = {}, {}
    local unsupported = {
        silent = "Silent aim has no verified shot adapter in the supplied sources.",
        ["tgt.resolver"] = "The sources do not supply a resolver.",
        ["gun.recoil"] = "No verified recoil adapter. The supplied code changes every spring globally.",
        ["gun.spread"] = "No verified spread adapter.", ["gun.rapid"] = "No verified fire-rate adapter.",
        ["gun.reload"] = "No verified reload adapter.", ["cam.shake"] = "No verified camera-shake adapter.",
        ["ch.ragdoll"] = "Anti-ragdoll requires a game-specific controller adapter.",
        ["ut.respawn"] = "Automatic respawn requires a game-specific respawn adapter.",
        ["srv.autoRejoin"] = "Automatic rejoin is not configured.",
        ["st.proof"] = "A PlayerGui menu cannot guarantee capture exclusion.",
    }
    engine.unsupported = unsupported
local function createHeadShellExpander(settings, eligible)
    local records, shellOffsets = {}, {}
    local manager = {closed = false, lastError = nil}
    local function offsetsFor(size)
        if shellOffsets[size] then return shellOffsets[size] end
        local offsets, shell = {}, size - 0.5
        for x = -shell, shell do
            for y = -shell, shell do
                for z = -shell, shell do
                    local distance = math.sqrt(x * x + y * y + z * z) - shell
                    if distance <= 0.5 and distance >= -0.5 then offsets[#offsets + 1] = {x, y, z} end
                end
            end
        end
        shellOffsets[size] = offsets
        return offsets
    end
    function manager:Remove(character)
        records[character] = nil
        -- Also removes shells left by the previous implementation on this character.
        for _, object in ipairs(character:GetDescendants()) do
            if object:GetAttribute("FakeHead") then object:Destroy() end
        end
    end
    function manager:Apply(character)
        if self.closed then return false end
        if not settings.hitbox_enabled or not eligible(character) then self:Remove(character); return false end
        local head = character:FindFirstChild("Head")
        if not head or not head:IsA("BasePart") or head:GetAttribute("FakeHead") then
            self:Remove(character); return false
        end
        local size = tonumber(settings.hitbox_size) or 5
        if size ~= size then size = 5 end
        size = math.max(1, math.min(5, math.floor(size + 0.5)))
        local existing = records[character]
        if existing and existing.head == head and existing.size == size then
            local intact = true
            for _, part in ipairs(existing.parts) do if part.Parent ~= character then intact = false; break end end
            if intact then
                existing.visual.Color = settings.hitbox_color
                return true
            end
        end
        self:Remove(character)
        local record = {head = head, size = size, parts = {}}
        records[character] = record
        local ok, reason = pcall(function()
            local neck = head:FindFirstChild("Neck")
            local neckC0 = neck and neck.C0 or CFrame.identity
            local function cloneHead(visible, offset)
                local clone = head:Clone()
                assert(clone, "Head cannot be cloned")
                record.parts[#record.parts + 1] = clone
                local face = clone:FindFirstChild("face")
                if face then face:Destroy() end
                clone.CanCollide = not visible
                clone.CanQuery = not visible
                clone.CanTouch = false
                clone.Massless = true
                clone.CastShadow = false
                clone.Transparency = visible and 0.5 or 1
                clone:SetAttribute("FakeHead", true)
                if visible then
                    if clone:IsA("Part") then clone.Shape = Enum.PartType.Ball end
                    clone.Size = Vector3.new(1, 1, 1) * size * 2
                    clone.Color = settings.hitbox_color
                    clone.Material = Enum.Material.ForceField
                else
                    local cloneNeck = clone:FindFirstChild("Neck")
                    if cloneNeck then cloneNeck.C0 = neckC0 * CFrame.new(offset[1], offset[2], offset[3]) end
                end
                clone.Parent = character
                return clone
            end
            record.visual = cloneHead(true)
            for _, offset in ipairs(offsetsFor(size)) do cloneHead(false, offset) end
        end)
        if not ok then
            -- Include clones that failed before parenting, so partial builds leave no objects behind.
            records[character] = nil
            for _, part in ipairs(record.parts) do part:Destroy() end
            self.lastError = tostring(reason)
            return false
        end
        self.lastError = nil
        return true
    end
    function manager:Clear()
        for character in pairs(records) do self:Remove(character) end
    end
    function manager:Describe()
        local characters, parts = 0, 0
        for _, record in pairs(records) do characters, parts = characters + 1, parts + #record.parts end
        return "Hitbox shells: " .. characters .. " players / " .. parts .. " parts / last error: " .. (self.lastError or "none")
    end
    function manager:Destroy() self.closed = true; self:Clear() end
    return manager
end


local function resolveGroundItemName(value, categories)
    if type(value) == "table" then
        value = rawget(value, "Name") or rawget(value, "ClassName") or rawget(value, "ItemName")
    end
    if type(value) ~= "string" then return nil end
    local name = value:match("^%s*(.-)%s*$")
    local lowered = name:lower()
    if lowered:sub(-9) == ".baseitem" then name = name:sub(1, -10)
    elseif lowered:sub(-5) == ".item" then name = name:sub(1, -6) end
    local category = categories[name] or categories[name:lower()]
    if category then return name, category end
    -- Namespace prefixes are allowed, while literal names such as BackpackTier1.5 win first.
    local shortName = name:match("([^./\\]+)$")
    if shortName then
        category = categories[shortName] or categories[shortName:lower()]
        if category then return shortName, category end
    end
end

local function readGroundItemClassMap(source, categories, onChunk)
    if type(source) ~= "table" then return nil, 0 end
    local result, count, visited = {}, 0, 0
    for key, value in pairs(source) do
        local classId, name = nil, nil
        if type(key) == "number" or (type(key) == "string" and tonumber(key)) then
            classId = tonumber(key)
            name = resolveGroundItemName(value, categories)
        elseif type(key) == "string" and (type(value) == "number" or type(value) == "string") then
            classId = tonumber(value)
            name = classId and resolveGroundItemName(key, categories)
        end
        if classId and name and classId == classId and math.abs(classId) < math.huge then
            if not result[classId] then count = count + 1 end
            result[classId], result[tostring(classId)] = name, name
        end
        visited = visited + 1
        if visited % 128 == 0 and onChunk and onChunk() == false then return nil, 0 end
    end
    if count > 0 then return result, count end
    return nil, 0
end

local function discoverGroundItemRegistry(categories, diagnostics, onChunk, observedIds)
    local functions, tables, seenDeep, seenNamed = {}, {}, {}, {}
    local registryKeys = {"CIDMap", "CIdMap", "ClassIdMap", "ClassIDMap"}
    local probes = {}
    for id in pairs(observedIds or {}) do
        probes[#probes + 1] = id
        if #probes == 16 then break end
    end
    diagnostics.tables, diagnostics.cidMaps, diagnostics.modules, diagnostics.upvalueFunctions = 0, 0, 0, 0
    diagnostics.registrySamples, diagnostics.discoveryErrors = {}, {}
    diagnostics.startedAt = os.clock()
    local upvalues = getupvalues or (debug and debug.getupvalues)
    diagnostics.apis = "getgc=" .. tostring(type(getgc) == "function") .. ", loadedModules="
        .. tostring(type(getloadedmodules) == "function") .. ", upvalues=" .. tostring(type(upvalues) == "function")
    local function chunk() return not onChunk or onChunk() ~= false end
    local function matchesLiveItems(converted)
        if not converted then return false end
        if not observedIds or not next(observedIds) then return true end
        for id in pairs(observedIds) do if converted[id] or converted[tostring(id)] then return true end end
        return false
    end
    local function accept(source, path)
        local converted, matches = readGroundItemClassMap(source, categories, onChunk)
        if matchesLiveItems(converted) then return converted, matches, source, path end
    end
    local function named(object, path)
        if type(object) ~= "table" or seenNamed[object] then return end
        seenNamed[object] = true
        for _, key in ipairs(registryKeys) do
            local source = rawget(object, key)
            if type(source) == "table" then
                diagnostics.cidMaps = diagnostics.cidMaps + 1
                local converted, matches = accept(source, path .. "." .. key)
                if converted then return converted, matches, source, path .. "." .. key end
                if #diagnostics.registrySamples < 4 then
                    local samples = {}
                    for id, value in next, source do
                        samples[#samples + 1] = tostring(id) .. "=" .. (type(value) == "string" and value:sub(1, 80) or type(value))
                        if #samples == 4 then break end
                    end
                    diagnostics.registrySamples[#diagnostics.registrySamples + 1] = path .. "." .. key .. ": " .. table.concat(samples, ", ")
                end
            end
        end
    end
    local function inspect(object, path, depth)
        if type(object) ~= "table" or seenDeep[object] then return end
        seenDeep[object] = true
        if not chunk() then return end
        local converted, matches, source, location = named(object, path)
        if converted then return converted, matches, source, location end
        -- Probe live IDs directly before enumerating a possible map.
        -- Most GC objects are unrelated; avoid parsing dozens of their values.
        for _, id in ipairs(probes) do
            local value = rawget(object, id) or rawget(object, tostring(id))
            if value and resolveGroundItemName(value, categories) then return accept(object, path) end
        end
        local visited, children, candidate = 0, {}, false
        for key, value in next, object do
            if (type(value) == "number" or type(value) == "string") and tonumber(value)
                and type(key) == "string" and resolveGroundItemName(key, categories) then candidate = true end
            if #probes == 0 and (type(key) == "number" or type(key) == "string" and tonumber(key))
                and resolveGroundItemName(value, categories) then candidate = true end
            if depth > 0 and type(key) == "string" and type(value) == "table" then
                local name = key:lower()
                if name:find("class", 1, true) or name:find("item", 1, true) or name:find("registry", 1, true)
                    or name:find("cid", 1, true) then children[#children + 1] = {key, value} end
            end
            visited = visited + 1
            if visited >= 16 then break end
        end
        if candidate then
            converted, matches, source, location = accept(object, path)
            if converted then return converted, matches, source, location end
        end
        for _, child in ipairs(children) do
            converted, matches, source, location = inspect(child[2], path .. "." .. child[1], depth - 1)
            if converted then return converted, matches, source, location end
        end
    end
    local function recordError(api, reason)
        diagnostics.discoveryErrors[#diagnostics.discoveryErrors + 1] = api .. ": " .. tostring(reason):sub(1, 200)
    end
    -- Cached game modules get first priority, before touching the entire GC heap.
    diagnostics.phase = "loaded modules"
    local gotModules = false
    if type(getloadedmodules) == "function" then
        local ok, modules = pcall(getloadedmodules)
        if ok and type(modules) == "table" then
            gotModules = true
            local preferred, others = {}, {}
            for _, module in pairs(modules) do
                local name = module.Name:lower()
                local list = (name:find("class", 1, true) or name:find("item", 1, true)
                    or name:find("registry", 1, true) or name:find("cid", 1, true)) and preferred or others
                list[#list + 1] = module
            end
            for _, list in ipairs({preferred, others}) do
                for _, module in ipairs(list) do
                    if not chunk() then return end
                    diagnostics.modules = diagnostics.modules + 1
                    local loaded, exports = pcall(require, module)
                    if loaded then
                        local converted, matches, source, location = inspect(exports, "Loaded module " .. module.Name, 2)
                        if converted then return converted, matches, source, location end
                    end
                end
            end
        else recordError("getloadedmodules", modules) end
    end
    -- First GC pass performs four raw registry-field lookups, with no recursive scans.
    diagnostics.phase = "GC named registries"
    local gotMemory, memory = false, nil
    if type(getgc) == "function" then gotMemory, memory = pcall(getgc, true) end
    gotMemory = gotMemory and type(memory) == "table"
    if gotMemory then
        for _, object in pairs(memory) do
            if not chunk() then return end
            if type(object) == "function" then functions[#functions + 1] = object
            elseif type(object) == "table" then
                diagnostics.tables = diagnostics.tables + 1; tables[#tables + 1] = object
                local converted, matches, source, location = named(object, "GC")
                if converted then return converted, matches, source, location end
            end
        end
    else recordError("getgc", memory or "unavailable") end
    diagnostics.phase = "function upvalues"
    if type(upvalues) == "function" then
        for _, fn in ipairs(functions) do
            if not chunk() then return end
            diagnostics.upvalueFunctions = diagnostics.upvalueFunctions + 1
            local ok, values = pcall(upvalues, fn)
            if ok and type(values) == "table" then
                for _, value in pairs(values) do
                    local converted, matches, source, location = inspect(value, "Function upvalue", 2)
                    if converted then return converted, matches, source, location end
                end
            end
        end
    end
    diagnostics.phase = "GC direct registries"
    for _, object in ipairs(tables) do
        if not chunk() then return end
        local converted, matches, source, location = inspect(object, "GC", 2)
        if converted then return converted, matches, source, location end
    end
    diagnostics.phase = "complete"
    if not gotMemory and not gotModules then error(table.concat(diagnostics.discoveryErrors, "\n")) end
end

local function getGroundItemPosition(item, attributes)
    local transform = attributes.CFrame
    if typeof(transform) == "CFrame" or type(transform) == "table" then
        local position = transform.Position
        if position and (typeof(position) == "Vector3" or type(position) == "table") then return position end
    end
    local part = item:IsA("BasePart") and item or item:IsA("Model") and item.PrimaryPart
    if not part and type(item.FindFirstChildWhichIsA) == "function" then
        part = item:FindFirstChildWhichIsA("BasePart", true)
    end
    if part then return part.Position, part end
end


local function resolveZombieRigPart(model, names)
    local function physicalPart(object)
        if not object then return nil end
        if not object:IsA("BasePart") then
            object = object:IsA("Model") and object.PrimaryPart or object:FindFirstChildWhichIsA("BasePart", true)
        end
        if object and object:IsA("BasePart") and object:GetAttribute("FakeHead") ~= true then return object end
    end
    for _, name in ipairs(names) do
        local part = physicalPart(model:FindFirstChild(name))
        if part then return part end
    end
    -- Visit rig containers only. Equipment heads must not replace the character's head.
    local containers = {model}
    for index = 1, 32 do
        local container = containers[index]
        if not container then break end
        for _, child in ipairs(container:GetChildren()) do
            if child.Name ~= "Equipment" and child.Name ~= "Inventory" and not child:IsA("Tool") then
                for _, name in ipairs(names) do
                    if child.Name == name then local part = physicalPart(child); if part then return part end end
                end
                if child:IsA("Model") or child:IsA("Folder") then containers[#containers + 1] = child end
            end
        end
    end
end

local function createZombieTracker(playerResolver)
    local players, collection = game:GetService("Players"), game:GetService("CollectionService")
    local assets = workspace:FindFirstChild("game_assets")
    local entities = assets and assets:FindFirstChild("Entities")
    local records, byModel, entries, connections = {}, {}, {}, {}
    local cachedTargets, initialized, cursor, nextClassify, nextLive = {}, false, 1, 0, 0
    local function add(model)
        if not model:IsA("Model") then return end
        local record = byModel[model]
        if record then record.dirty = true; return end
        record = {model = model, dirty = true, checkedAt = -math.huge, index = #records + 1}
        records[record.index], byModel[model] = record, record
        record.attributeConnection = model.AttributeChanged:Connect(function(attribute)
            if attribute == "IsZombie" or attribute == "IsTacticalZombie" or attribute == "ZombieType"
                or attribute == "NPCType" or attribute == "EntityType" or attribute == "Type" or attribute == "Variant" then
                record.dirty = true
            end
        end)
    end
    local function remove(model)
        local record = byModel[model]
        if not record then return end
        if record.attributeConnection then record.attributeConnection:Disconnect() end
        local last = records[#records]
        records[record.index] = last; last.index = record.index; records[#records] = nil
        byModel[model], entries[model], nextLive = nil, nil, 0
    end
    local function changed(object)
        -- Track the outer character model even inside streamed entity folders.
        local current, entityModel = object, nil
        while current and current ~= workspace do
            if entities then
                if current == entities then if entityModel then add(entityModel) end; return end
                if current:IsA("Model") then entityModel = current end
            end
            if not entities and current:IsA("Model") then add(current) end
            current = current.Parent
        end
    end
    local function initialize()
        if initialized then return end
        initialized = true
        if entities then
            local folders = {entities}
            local index = 1
            while folders[index] do
                for _, object in ipairs(folders[index]:GetChildren()) do
                    if object:IsA("Model") then add(object)
                    elseif object:IsA("Folder") then folders[#folders + 1] = object end
                end
                index = index + 1
            end
            connections[#connections + 1] = entities.ChildRemoved:Connect(remove)
            connections[#connections + 1] = entities.DescendantRemoving:Connect(function(object) if byModel[object] then remove(object) end end)
        else
            for _, object in ipairs(workspace:GetDescendants()) do if object:IsA("Model") then add(object) end end
            connections[#connections + 1] = workspace.DescendantRemoving:Connect(function(object)
                if byModel[object] then remove(object) end
            end)
        end
        connections[#connections + 1] = (entities or workspace).DescendantAdded:Connect(changed)
    end
    local function classify(model, playerCharacters)
        if not model.Parent or playerCharacters[model] then return nil end
        local root = resolveZombieRigPart(model, {"ServerCollider", "HumanoidRootPart", "RootPart", "UpperTorso", "Torso"}) or model.PrimaryPart
        local head = resolveZombieRigPart(model, {"Head"})
        if not root or not root:IsA("BasePart") or not head or not head:IsA("BasePart") then return nil end
        if model:GetAttribute("IsZombie") == false then return nil end
        local resolvedNonPlayer = false
        if playerResolver then
            local ok, player = pcall(playerResolver, model)
            if ok and player then return nil end
            resolvedNonPlayer = ok and player == nil
        end
        local markers = model.Name:lower()
        for _, attribute in ipairs({"ZombieType", "NPCType", "EntityType", "Type", "Variant"}) do
            local value = model:GetAttribute(attribute)
            if type(value) == "string" then markers = markers .. " " .. value:lower() end
        end
        local tactical = model:GetAttribute("IsTacticalZombie") == true or collection:HasTag(model, "TacticalZombie")
            or collection:HasTag(model, "Tactical Zombie") or markers:find("tactical", 1, true) ~= nil
        local zombie = model:GetAttribute("IsZombie") == true or collection:HasTag(model, "Zombie")
            or tactical or markers:find("zombie", 1, true) ~= nil
            or model.Parent.Name:lower():find("zombie", 1, true) ~= nil
            or (entities and (model.Parent == entities or model:IsDescendantOf(entities))
                and (resolvedNonPlayer or not model:FindFirstChild("Scripts")))
        if not zombie then return nil end
        local chinese = false
        local equipment = model:FindFirstChild("Equipment")
        -- Classification is cached for five seconds and invalidated by new gear.
        if equipment then
            for _, item in ipairs(equipment:GetDescendants()) do
                if item.Name:lower():find("tactical", 1, true) then tactical = true end
                if item:IsA("MeshPart") and item.MeshId == "rbxassetid://17661257035" then chinese = true end
            end
        end
        return {character = model, kind = "zombie", tactical = tactical, chinese = chinese,
            name = tactical and "Tactical Zombie" or "Zombie", root = root, head = head,
            humanoid = model:FindFirstChildOfClass("Humanoid")}
    end
    local tracker = {}
    function tracker:GetTargets()
        initialize()
        local now = os.clock()
        if now >= nextClassify then
            local playerCharacters = {}
            for _, player in ipairs(players:GetPlayers()) do if player.Character then playerCharacters[player.Character] = true end end
            local deadline = now + 0.001
            for _ = 1, math.min(64, #records) do
                if cursor > #records then cursor = 1 end
                local record = records[cursor]; cursor = cursor + 1
                if record and (record.dirty or now - record.checkedAt >= 5) then
                    record.dirty, record.checkedAt = false, now
                    entries[record.model] = classify(record.model, playerCharacters)
                    nextLive = 0
                end
                if os.clock() >= deadline then break end
            end
            nextClassify = now + 0.1
        end
        if now >= nextLive then
            cachedTargets = {}
            for model, entry in pairs(entries) do
                local health = model:GetAttribute("Health")
                if model.Parent and (entry.head.Parent == model or entry.head:IsDescendantOf(model))
                    and (entry.root.Parent == model or entry.root:IsDescendantOf(model))
                    and (not entry.humanoid or entry.humanoid.Health > 0)
                    and (type(health) ~= "number" or health > 0)
                    and model:GetAttribute("Dead") ~= true and model:GetAttribute("IsDead") ~= true then
                    cachedTargets[#cachedTargets + 1] = entry
                end
            end
            nextLive = now + 0.1
        end
        return cachedTargets
    end
    function tracker:Destroy()
        for _, connection in ipairs(connections) do connection:Disconnect() end
        for _, record in ipairs(records) do if record.attributeConnection then record.attributeConnection:Disconnect() end end
        records, byModel, entries, cachedTargets = {}, {}, {}, {}
    end
    function tracker:GetStatus()
        return {models = #records, zombies = #cachedTargets, initialized = initialized}
    end
    function tracker:Describe()
        local lines = {"Apex zombie ESP", "Models tracked: " .. #records, "Live zombies: " .. #cachedTargets}
        for index = 1, math.min(12, #records) do
            local model = records[index].model
            local head = resolveZombieRigPart(model, {"Head"})
            local root = resolveZombieRigPart(model, {"ServerCollider", "HumanoidRootPart", "RootPart", "UpperTorso", "Torso"}) or model.PrimaryPart
            lines[#lines + 1] = model.Name .. " | head=" .. (head and head.Name or "missing")
                .. " | root=" .. (root and root.Name or "missing")
                .. " | scripts=" .. tostring(model:FindFirstChild("Scripts") ~= nil)
                .. " | zombie=" .. tostring(entries[model] ~= nil)
        end
        return table.concat(lines, "\n")
    end
    return tracker
end


-- All, tactical, and Chinese filters share one pool, so enabling all cannot duplicate labels.


            itemCategories.helmets = {
                flag = "helmettesp",
                color = Color3.new(1, 1, 1),
                items = {
                    "AltynHelmet",
                    "ConstructionHelmet",
                    "ConstructionHelmetClassic",
                    "FootballHelmet",
                    "FootballHelmetNewRed",
                    "HelmetTier1",
                    "HelmetTier2",
                    "KnightHelmet",
                    "MakeshiftHelmet",
                    "MilitaryHelmetBlack",
                    "MilitaryHelmetCamo",
                    "MotorcycleHelmetBlack",
                    "MotorcycleHelmetBlue",
                    "MotorcycleHelmetGray",
                    "MotorcycleHelmetGreen",
                    "MotorcycleHelmetRasta",
                    "MotorcycleHelmetRed",
                    "MotorcycleHelmetWhite",
                    "OperatorHelmetBlack",
                    "OperatorHelmetCamo",
                    "PotHelmet",
                    "SamuraiHelmet",
                    "SpartanHelmet",
                    "UnicornHelmet",
                },
            }
            itemCategories.ammos = {
                flag = "ammoesp",
                color = Color3.new(1, 1, 1),
                items = {
                    "Ammo12Gauge",
                    "Ammo223Rem",
                    "Ammo22LR",
                    "Ammo308Win",
                    "Ammo40mmGrenade",
                    "Ammo44Magnum",
                    "Ammo45ACP",
                    "Ammo50BMG",
                    "Ammo762Soviet",
                    "Ammo762x54MMR",
                    "Ammo9MMParabellum",
                    "Ammo9x39MM",
                    "AmmoArrow",
                    "AmmoItem",
                },
            }
            itemCategories.weapons = {
                flag = "weaponesp",
                color = Color3.new(1, 1, 1),
                items = {
                    "AKM",
                    "AR15",
                    "MK4",
                    "Mossberg",
                    "MosinNagant",
                    "DoubleBarrelShotgunShort",
                    "ASVAL",
                    "Scrap_Sniper",
                    "MK47",
                    "SPAS12",
                    "44Magnum",
                    "SVD",
                    "Barret50",
                    "MK14",
                    "ShotgunMakeshift",
                    "Sporter",
                    "FAL",
                    "M40A1",
                    "UZI",
                    "M249",
                    "PKM",
                    "P90",
                    "M110K",
                    "AWM",
                    "MK18",
                    "DoubleBarrelShotgun",
                    "G36k",
                    "Tec9",
                    "Saiga12",
                    "MRAD",
                    "Scrap_SMG",
                    "SCAR",
                    "SUV",
                    "HuntingRifle",
                    "UMP45",
                    "M4A1",
                    "Glock",
                    "Makarov",
                    "M79",
                    "MP133",
                    "BowAndArrowRecurve",
                    "BowAndArrow",
                    "FNX45",
                    "P226",
                    "M9",
                    "SKS",
                    "RenelliM4",
                    "AK47",
                    "Remington1984",
                    "Remington700",
                    "DesertEagle",
                    "Crossbow",
                    "M1911",
                    "MP5",
                    "Famas",
                },
            }
            itemCategories.medicals = {
                flag = "medicalesp",
                color = Color3.new(1, 1, 1),
                items = {
                    "Antibiotics",
                    "LegSplint",
                    "MedkitOLDGE",
                    "FirstAid",
                    "SmallMedkit",
                    "Bandage",
                    "DressedBandage",
                    "HealingSalve",
                    "Tourniquet",
                    "SalineSolution",
                    "SAMSplint",
                    "Medkit",
                    "MakeshiftTourniquet",
                },
            }
            itemCategories.backpacks = {
                flag = "backpackesp",
                color = Color3.new(1, 1, 1),
                items = {
                    "BackpackTier0.5",
                    "BackpackTier1.5",
                    "BackpackTier1",
                    "BackpackTier2",
                    "BackpackTier3",
                    "BackpackTier4",
                    "BunnyBackpack",
                    "MakeshiftBackpack",
                    "MediumBackpackBlack",
                    "MediumBackpackCamo",
                    "MediumBackpackGhillie",
                    "MediumBackpackGray",
                    "MediumBackpackGreen",
                    "MediumBackpackNavy",
                    "MediumBackpackTan",
                    "SmallBackpack",
                    "SmallBackpackBlack",
                    "SmallBackpackBlue",
                    "SmallBackpackBlueBrown",
                    "SmallBackpackBlueGray",
                    "SmallBackpackBlueOrange",
                    "SmallBackpackGray",
                    "SmallBackpackOrange",
                },
            }
            itemCategories.repairkit = {
                flag = "weprepairkitesp",
                color = Color3.new(1, 1, 1),
                items = {
                    "MakeshiftWeaponRepairKit",
                    "WeaponRepairKit",
                },
            }
            itemCategories.vests = {
                flag = "vestesp",
                color = Color3.new(1, 1, 1),
                items = {
                    "FBIVest",
                    "MakeshiftVest",
                    "MilitaryVestBlack",
                    "MilitaryVestCamo",
                    "PoliceVest",
                    "PressVest",
                    "RatnikVest",
                    "VestTier1.5",
                    "VestTier1",
                    "VestTier2",
                    "VestTier3",
                },
            }

    for category, definition in pairs(itemCategories) do
        for _, name in ipairs(definition.items) do itemCategoryByName[name], itemCategoryByName[name:lower()] = category, category end
    end

    local function finite(value) return type(value) == "number" and value == value and math.abs(value) < math.huge end
    local function path(root, names)
        for _, name in ipairs(names) do root = root and root:FindFirstChild(name); if not root then return nil end end
        return root
    end
    local function connect(signal, callback)
        local connection = signal:Connect(function(...) if engine.active then return callback(...) end end)
        engine.connections[#engine.connections + 1] = connection
        return connection
    end
    local function report(message) if api.log then api.log(message) end end
    local function make(class, properties)
        local object = Instance.new(class)
        for key, value in pairs(properties) do if key ~= "Parent" then object[key] = value end end
        object.Parent = properties.Parent
        return object
    end
    local function allowed() return engine.active and not engine.suspended end
    local function blocked() return not allowed() or api.inputBlocked() or input:GetFocusedTextBox() ~= nil end
    local function color(key, fallback) local value = state[key]; return typeof(value) == "Color3" and value or fallback or Color3.new(1, 1, 1) end
    function engine:Override(object, key, value, group)
        if not object then return end
        local current = object[key]
        local fields = self.overrides[object]
        if not fields then fields = {}; self.overrides[object] = fields end
        local record = fields[key]
        if not record then
            record = {object = object, key = key, original = current, group = group}
            fields[key] = record
            self.groups[group] = self.groups[group] or {}; self.groups[group][record] = true
        end
        if current ~= value then object[key] = value; current = object[key] end
        record.applied = current
    end
    function engine:Restore(group)
        if not group then
            while next(self.groups) do self:Restore(next(self.groups)) end
            return
        end
        local records = self.groups[group]
        if not records then return end
        self.groups[group] = nil
        for record in pairs(records) do
            local object, key = record.object, record.key
            pcall(function() if object[key] == record.applied then object[key] = record.original end end)
            local fields = self.overrides[object]
            if fields then fields[key] = nil; if not next(fields) then self.overrides[object] = nil end end
        end
    end
    function engine:Held(name)
        if blocked() then return false end
        if name == "mouse1" then return input:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) end
        if name == "mouse2" then return input:IsMouseButtonPressed(Enum.UserInputType.MouseButton2) end
        if name == "mouse3" then return input:IsMouseButtonPressed(Enum.UserInputType.MouseButton3) end
        local aliases = {lctrl = "LeftControl", rctrl = "RightControl", lalt = "LeftAlt", ralt = "RightAlt", lshift = "LeftShift", rshift = "RightShift", space = "Space"}
        if type(name) ~= "string" or name == "none" then return false end
        local ok, code = pcall(function() return keyCodes[name] or Enum.KeyCode[aliases[name] or (#name == 1 and name:upper() or name:sub(1, 1):upper() .. name:sub(2))] end)
        return ok and code and input:IsKeyDown(code) or false
    end
    local function worldModel(value)
        if type(value) == "table" and typeof(value) ~= "Instance" then value = value.WorldModel or value.WorldCharacter or value.Model end
        if typeof(value) == "Instance" and value:IsA("Model") and value:IsDescendantOf(workspace) then return value end
    end
    local function playerModel(who)
        local mapped = engine.modelByPlayer and worldModel(engine.modelByPlayer[who])
        if mapped then return mapped end
        if engine.modules.characters and type(engine.modules.characters.GetWorldCharacterFromPlayer) == "function" then
            local ok, model = pcall(engine.modules.characters.GetWorldCharacterFromPlayer, engine.modules.characters, who)
            if ok and worldModel(model) then return worldModel(model) end
        end
        return worldModel(who.Character)
    end
    local function refreshPlayerModels()
        local mapped, registry = {}, engine.modules.characters
        local function add(who, model)
            model = worldModel(model)
            if type(who) == "table" and typeof(who) ~= "Instance" and type(who.Name) == "string" then who = services.Players:FindFirstChild(who.Name) end
            if typeof(who) == "Instance" and who:IsA("Player") and model then mapped[who] = model end
        end
        local function owner(model)
            if registry and type(registry.GetPlayerFromWorldCharacter) == "function" then
                local ok, who = pcall(registry.GetPlayerFromWorldCharacter, registry, model)
                if ok and typeof(who) == "Instance" and who:IsA("Player") then return who end
            end
            local list = engine.modules.playerList
            if registry and list and type(registry.GetCharacterFromWorldCharacter) == "function" and type(list.GetPlayerFromCharacter) == "function" then
                local ok, character = pcall(registry.GetCharacterFromWorldCharacter, registry, model)
                if ok and character then
                    local found, who = pcall(list.GetPlayerFromCharacter, list, character)
                    if found and typeof(who) == "Instance" and who:IsA("Player") then return who end
                    if found and type(who) == "table" and type(who.Name) == "string" then return services.Players:FindFirstChild(who.Name) end
                end
            end
            local id = model:GetAttribute("UserId") or model:GetAttribute("PlayerUserId") or model:GetAttribute("OwnerUserId")
            if finite(id) then return services.Players:GetPlayerByUserId(id) end
            local named = services.Players:FindFirstChild(model.Name)
            if named and named:IsA("Player") then return named end
        end
        if registry then
            for _, method in ipairs({"GetCharacters", "GetWorldCharacters"}) do
                if type(registry[method]) == "function" then
                    local ok, entries = pcall(registry[method], registry)
                    if ok and type(entries) == "table" then
                        for key, value in pairs(entries) do
                            local model = worldModel(value) or worldModel(key)
                            if model then
                                local who = type(value) == "table" and typeof(value) ~= "Instance" and value.Player or nil
                                if not who and typeof(key) == "Instance" and key:IsA("Player") then who = key end
                                add(who or owner(model), model)
                            end
                        end
                    end
                end
            end
        end
        -- Only inspect the game's entity roots, never the full workspace on a frame update.
        local entities = path(workspace, {"game_assets", "Entities"}) or workspace:FindFirstChild("Characters")
        if entities then
            for _, model in ipairs(entities:GetChildren()) do
                if model:IsA("Model") then
                    local who = owner(model)
                    if who and not mapped[who] then add(who, model) end
                end
            end
        end
        engine.modelByPlayer = mapped
    end
    local function localRoot()
        local character = player.Character
        local root = character and (character:FindFirstChild("HumanoidRootPart") or character.PrimaryPart)
        if root and root:IsA("BasePart") and not root.Anchored then return root, character:FindFirstChildOfClass("Humanoid") end
        if movementCache and movementCache.Parent and not movementCache.Anchored then return movementCache end
        return nil
    end
    local function refreshMovementCache()
        movementCache = nil
        local camera = workspace.CurrentCamera
        if camera then
            for _, part in ipairs(camera:GetDescendants()) do
                if part:IsA("BasePart") and not part.Anchored then
                    local size = part.Size
                    if size.X == 2.5 and size.Z == 2.5 and (size.Y == 5 or size.Y == 3.25 or size.Y == 3 or size.Y == 2) then movementCache = part; break end
                end
            end
        end
    end
    local function isTeammate(who)
        if not who then return false end
        local squad, other = player:GetAttribute("SquadName"), who:GetAttribute("SquadName")
        local function validSquad(value)
            if type(value) ~= "string" then return false end
            value = value:lower():match("^%s*(.-)%s*$")
            return value ~= "" and value ~= "none" and value ~= "nil" and value ~= "no squad" and value ~= "unassigned"
        end
        if validSquad(squad) or validSquad(other) then return validSquad(squad) and squad == other end
        if engine.modules.characters or path(workspace, {"game_assets", "Entities"}) then return false end
        return player.Team ~= nil and not player.Neutral and not who.Neutral and player.Team == who.Team
    end
    local function alive(entry)
        local model, owner = entry.character, entry.player
        if not model.Parent or owner and owner:GetAttribute("Dead") == true then return false end
        if model:GetAttribute("Dead") == true or model:GetAttribute("IsDead") == true then return false end
        local humanoid = entry.humanoid
        local health = humanoid and humanoid.Health or model:GetAttribute("Health")
        return not finite(health) or health > 0
    end
    local function resolvePart(entry, requested, camera)
        if requested == "Random" then requested = "Head" end
        if requested == "Head" and entry.head and entry.head.Parent then return entry.head end
        if requested == "Closest Part" then
            local closest, distance = nil, math.huge
            local center = camera.ViewportSize / 2
            for _, name in ipairs({"Head", "UpperTorso", "Torso", "HumanoidRootPart", "LeftUpperArm", "RightUpperArm", "LeftUpperLeg", "RightUpperLeg"}) do
                local part = resolveZombieRigPart(entry.character, {name})
                if part then
                    local point, visible = camera:WorldToViewportPoint(part.Position)
                    local score = (Vector2.new(point.X, point.Y) - center).Magnitude
                    if visible and score < distance then closest, distance = part, score end
                end
            end
            return closest
        end
        return resolveZombieRigPart(entry.character, {requested, requested == "Torso" and "UpperTorso" or requested == "Neck" and "Head" or requested}) or entry.head or entry.root
    end
    local visibilityParams = RaycastParams.new()
    visibilityParams.FilterType = Enum.RaycastFilterType.Exclude
    visibilityParams.IgnoreWater = true
    local function visible(entry, part, camera)
        local excluded = {camera}
        if player.Character then excluded[#excluded + 1] = player.Character end
        local worldCharacter = playerModel(player)
        if worldCharacter and worldCharacter ~= player.Character then excluded[#excluded + 1] = worldCharacter end
        visibilityParams.FilterDescendantsInstances = excluded
        local result = workspace:Raycast(camera.CFrame.Position, part.Position - camera.CFrame.Position, visibilityParams)
        return not result or result.Instance:IsDescendantOf(entry.character)
    end
    function engine:SelectTarget(camera, requested, radius)
        local best, bestPart, bestScore, center = nil, nil, math.huge, camera.ViewportSize / 2
        local prioritized = api.playerState.target
        for _, entry in ipairs(self.actors) do
            local who = entry.player
            if alive(entry) and not (who and api.playerState.white[who.UserId]) and (not entry.kind or state["aim.zombies"])
                and not (state["tgt.team"] and isTeammate(who))
                and not (state["tgt.knock"] and (entry.character:GetAttribute("Knocked") == true or entry.character:GetAttribute("Downed") == true)) then
                local part = resolvePart(entry, requested, camera)
                if part and part.Parent and (part.Position - camera.CFrame.Position).Magnitude <= state["aim.dist"] then
                    local screen, onScreen = camera:WorldToViewportPoint(part.Position)
                    local distance = (Vector2.new(screen.X, screen.Y) - center).Magnitude
                    if onScreen and distance <= radius and (not state["tgt.vis"] or visible(entry, part, camera)) then
                        local score = distance
                        if who and prioritized[who.UserId] then score = score - 10000 end
                        if state["tgt.sticky"] and entry.character == (target and target.character) then score = score - 5000 end
                        if score < bestScore then best, bestPart, bestScore = entry, part, score end
                    end
                end
            end
        end
        return best, bestPart
    end
    local function selectedPosition(entry, part)
        local position = part.Position
        if state["tgt.pred"] then
            local velocity = entry.root and entry.root.AssemblyLinearVelocity or Vector3.zero
            if typeof(velocity) == "Vector3" then
                position = position + Vector3.new(velocity.X * state["tgt.predX"], velocity.Y * state["tgt.predY"], velocity.Z * state["tgt.predX"])
            end
        end
        return position
    end
    local function updateAim(camera, dt)
        local engaged = state.aim and engine:Held(state["aim.hold"])
        if not engaged and not state.trig and not (state.hbe and state["hbe.target"]) then target, targetPart = nil, nil; mouseCarry = Vector2.zero; return end
        target, targetPart = engine:SelectTarget(camera, state["aim.part"], state["aim.fov"])
        if engaged and targetPart then
            local position = selectedPosition(target, targetPart)
            local speed = math.max(1, state["aim.smooth"])
            local alpha = 1 - math.exp(-dt * 60 / speed)
            if state["aim.easing"] == "Ease Out" then alpha = 1 - (1 - alpha) ^ 1.5 end
            if state["aim.method"] == "Camera" then
                camera.CFrame = camera.CFrame:Lerp(CFrame.lookAt(camera.CFrame.Position, position), math.clamp(alpha, 0, 1))
            elseif type(mousemoverel) == "function" then
                local point, onScreen = camera:WorldToViewportPoint(position)
                if not onScreen then point, onScreen = camera:WorldToViewportPoint(targetPart.Position) end
                if onScreen then
                    local delta = (Vector2.new(point.X, point.Y) - camera.ViewportSize / 2) * alpha + mouseCarry
                    local x = delta.X >= 0 and math.floor(delta.X) or math.ceil(delta.X)
                    local y = delta.Y >= 0 and math.floor(delta.Y) or math.ceil(delta.Y)
                    mouseCarry = delta - Vector2.new(x, y)
                    if x ~= 0 or y ~= 0 then
                        local ok, err = pcall(mousemoverel, x, y)
                        if not ok then api.set("aim", false); report("Mouse aim disabled: " .. tostring(err)) end
                    end
                end
            else api.set("aim", false); api.notify("Mouse input unavailable; select Camera aim.") end
        else mouseCarry = Vector2.zero end
        if not state.trig or blocked() or type(mouse1click) ~= "function" then triggerTarget = nil; return end
        local candidate, part = engine:SelectTarget(camera, state["trig.head"] and "Head" or state["aim.part"], 8)
        if not candidate or not part or not visible(candidate, part, camera) then triggerTarget = nil; return end
        local now = os.clock()
        if triggerTarget ~= candidate.character then triggerTarget, triggerAt = candidate.character, now end
        if now >= nextTrigger and now - triggerAt >= state["trig.delay"] / 1000 then
            nextTrigger = now + 0.12
            if math.random(1, 100) <= state["trig.chance"] then pcall(mouse1click) end
        end
    end
    local function releaseFly()
        if flyVelocity then flyVelocity:Destroy(); flyVelocity = nil end
        if flyAttachment then flyAttachment:Destroy(); flyAttachment = nil end
        if flyRoot and flyRoot.Parent then pcall(function() flyRoot.AssemblyLinearVelocity = Vector3.zero end) end
        flyRoot = nil
        engine:Restore("fly")
    end
    local function moveDirection(camera, humanoid)
        if humanoid and humanoid.MoveDirection.Magnitude > 0 then return humanoid.MoveDirection end
        local x, z = 0, 0
        if engine:Held("w") then z = z + 1 end
        if engine:Held("s") then z = z - 1 end
        if engine:Held("d") then x = x + 1 end
        if engine:Held("a") then x = x - 1 end
        local look, right = camera.CFrame.LookVector, camera.CFrame.RightVector
        local direction = Vector3.new(look.X, 0, look.Z) * z + Vector3.new(right.X, 0, right.Z) * x
        return direction.Magnitude > 0 and direction.Unit or Vector3.zero
    end
    local function updateMovement(camera, dt)
        local autoJump = state["mv.bhop"] and path(services.ReplicatedStorage, {"CustomCharacterConfigs", "Configuration", "Client", "cl_auto_jump"}) or nil
        if autoJump and not autoJump:IsA("BoolValue") then autoJump = nil end
        if autoJump and autoJump:IsA("BoolValue") and not blocked() and not state.fly then
            engine:Override(autoJump, "Value", true, "bhop")
            engine.bhopMode = "native auto jump"
        else
            engine:Restore("bhop")
            engine.bhopMode = state["mv.bhop"] and "waiting for character" or "off"
        end
        local root, humanoid = localRoot()
        if not root and os.clock() >= nextMovementProbe and (state.fly or state["mv.speed"] or state["ch.noclip"] or state["ch.spin"]) then
            refreshMovementCache(); root, humanoid = localRoot(); nextMovementProbe = os.clock() + 0.5
        end
        if not root then releaseFly(); return end
        local character = player.Character
        if character ~= localPartsModel then
            localPartsModel, localParts = character, {}
            if character then
                for _, part in ipairs(character:GetDescendants()) do if part:IsA("BasePart") then localParts[#localParts + 1] = part end end
                if localCharacterConnection then localCharacterConnection:Disconnect() end
                localCharacterConnection = character.DescendantAdded:Connect(function(part) if localPartsModel == character and part:IsA("BasePart") then localParts[#localParts + 1] = part end end)
            end
        end
        if state.fly and not blocked() then
            if flyRoot ~= root then releaseFly(); flyRoot = root end
            if humanoid then engine:Override(humanoid, "AutoRotate", false, "fly") end
            local direction = moveDirection(camera, humanoid)
            if engine:Held("space") then direction = direction + Vector3.yAxis end
            if engine:Held("lctrl") then direction = direction - Vector3.yAxis end
            if direction.Magnitude > 1 then direction = direction.Unit end
            if state["fly.mode"] == "CFrame" then
                if flyVelocity then flyVelocity:Destroy(); flyVelocity = nil end
                root.AssemblyLinearVelocity = Vector3.zero
                root.CFrame = root.CFrame + direction * state["fly.speed"] * math.min(dt, 0.05)
            else
                if not flyAttachment then flyAttachment = make("Attachment", {Name = "ApexFlight", Parent = root}) end
                if not flyVelocity then flyVelocity = make("LinearVelocity", {Name = "ApexFlightVelocity", Attachment0 = flyAttachment, MaxForce = math.huge,
                    RelativeTo = Enum.ActuatorRelativeTo.World, VelocityConstraintMode = Enum.VelocityConstraintMode.Vector, Parent = root}) end
                flyVelocity.VectorVelocity = direction * state["fly.speed"]
            end
        else
            if flyRoot then releaseFly() end
            if state["mv.speed"] and not blocked() then
                if humanoid then engine:Override(humanoid, "WalkSpeed", state["mv.speedVal"], "speed")
                else local direction = moveDirection(camera); root.AssemblyLinearVelocity = direction * state["mv.speedVal"] + Vector3.new(0, root.AssemblyLinearVelocity.Y, 0) end
            else engine:Restore("speed") end
        end
        if humanoid then
            if state["mv.jump"] then
                engine:Override(humanoid, humanoid.UseJumpPower and "JumpPower" or "JumpHeight", humanoid.UseJumpPower and state["mv.jumpVal"] or state["mv.jumpVal"] ^ 2 / (2 * workspace.Gravity), "jump")
            else engine:Restore("jump") end
            if state["mv.bhop"] and not state.fly and not autoJump then
                engine.bhopMode = "humanoid"
                if engine:Held("space") and humanoid.FloorMaterial ~= Enum.Material.Air then humanoid:ChangeState(Enum.HumanoidStateType.Jumping) end
            end
        end
        if state["ch.fling"] then
            if root.AssemblyAngularVelocity.Magnitude > 60 then root.AssemblyAngularVelocity = Vector3.zero end
        end
        local clip = state["ch.noclip"] or state.fly and not blocked() and state["fly.noclip"]
        if clip then
            for _, part in ipairs(localParts) do if part.Parent and part:IsA("BasePart") then engine:Override(part, "CanCollide", false, "noclip") end end
            engine:Override(root, "CanCollide", false, "noclip")
        else engine:Restore("noclip") end
    end
    local function updateSpin(camera, dt)
        local controller = engine.modules.characterPlugin
        if state["ch.spin"] and not blocked() then
            spinAngle = (spinAngle + math.min(dt, 0.1) * state["ch.spinSpeed"]) % (2 * math.pi)
            spinning = true
            local controlled = false
            if controller and type(controller.SetYaw) == "function" then
                controlled = pcall(controller.SetYaw, controller, spinAngle)
            end
            local replication = engine.characterReplication
            if replication then engine:Override(replication, "CharacterYaw", spinAngle, "spin") end
            local yaw = path(player, {"CharData", "Yaw"})
            if yaw and yaw:IsA("NumberValue") then engine:Override(yaw, "Value", spinAngle, "spin") end
            local root, humanoid = localRoot()
            if root and not controlled then
                if humanoid then engine:Override(humanoid, "AutoRotate", false, "spin") end
                root.CFrame = CFrame.new(root.Position) * CFrame.Angles(0, spinAngle, 0)
            end
            engine.spinMode = controlled and "character controller" or root and "physical root" or "waiting for character"
        elseif spinning then
            spinning = false; engine.spinMode = "off"; engine:Restore("spin")
            if controller and type(controller.SetYaw) == "function" then
                local look = camera.CFrame.LookVector
                pcall(controller.SetYaw, controller, math.atan2(-look.X, -look.Z))
            end
        end
    end
    local worldRevision, environmentCache, environmentConnection = 0, nil, nil
    local function applyEnvironment(object)
        if not object.Parent then return end
        if object:IsA("BasePart") and object.Anchored then
            if state["env.xray"] then engine:Override(object, "LocalTransparencyModifier", state["env.xrayAlpha"] / 100, "xray") end
            if state["perf.low"] then engine:Override(object, "Material", Enum.Material.SmoothPlastic, "graphics"); engine:Override(object, "CastShadow", false, "graphics") end
        elseif (object:IsA("Decal") or object:IsA("Texture")) and state["env.textures"] then engine:Override(object, "Transparency", 1, "textures")
        elseif (object:IsA("ParticleEmitter") or object:IsA("Trail") or object:IsA("Beam")) and state["perf.particles"] then engine:Override(object, "Enabled", false, "particles") end
    end
    function engine:RefreshEnvironment()
        worldRevision = worldRevision + 1
        local revision = worldRevision
        local wanted = {xray = state["env.xray"], textures = state["env.textures"], particles = state["perf.particles"], graphics = state["perf.low"]}
        for group, enabled in pairs(wanted) do if not enabled or not allowed() then self:Restore(group) end end
        if not allowed() or not (wanted.xray or wanted.textures or wanted.particles or wanted.graphics) then
            if environmentConnection then environmentConnection:Disconnect(); environmentConnection = nil end
            environmentCache = nil
            return
        end
        if not environmentCache then
            local root = workspace:FindFirstChild("world_assets") or workspace
            environmentCache = root:GetDescendants()
            environmentConnection = root.DescendantAdded:Connect(function(object)
                if not allowed() or not environmentCache then return end
                environmentCache[#environmentCache + 1] = object
                applyEnvironment(object)
            end)
        end
        local objects = environmentCache
        task.spawn(function()
            local deadline = os.clock() + 0.001
            for _, object in ipairs(objects) do
                if not allowed() or revision ~= worldRevision then return end
                applyEnvironment(object)
                if os.clock() >= deadline then task.wait(); deadline = os.clock() + 0.001 end
            end
        end)
    end
    local function updateViewmodel(camera)
        local wanted = (state["vm.gun"] or state["vm.arms"]) and camera:FindFirstChild("CurrentWeapon") or nil
        if viewmodel ~= wanted then
            if viewmodelConnection then viewmodelConnection:Disconnect(); viewmodelConnection = nil end
            engine:Restore("viewmodel"); viewmodel, viewmodelParts, viewmodelSeen = wanted, {}, {}
            if wanted then
                local function add(part)
                    if not viewmodelSeen[part] and #viewmodelParts < 1024 and (part:IsA("BasePart") or part:IsA("SpecialMesh") or part:IsA("SurfaceAppearance") or part:IsA("Texture") or part:IsA("Decal")) then
                        local parent, arms, weapon, geometry = part, false, false, nil
                        while parent and parent ~= wanted do
                            if not geometry and parent:IsA("BasePart") then geometry = parent end
                            local name = parent.Name:lower()
                            if name == "weapon" or name:sub(1, 10) == "attachment" then weapon = true end
                            if name == "skin" or name:find("arm", 1, true) or name:find("hand", 1, true) then arms = true end
                            parent = parent.Parent
                        end
                        viewmodelSeen[part] = true
                        viewmodelParts[#viewmodelParts + 1] = {object = part, arms = arms and not weapon, geometry = geometry}
                    end
                end
                for _, part in ipairs(wanted:GetDescendants()) do add(part) end
                viewmodelConnection = wanted.DescendantAdded:Connect(add)
            end
        end
        if not wanted then return end
        local function sourceValue(object, key)
            local record = engine.overrides[object] and engine.overrides[object][key]
            local current = object[key]
            return record and current == record.applied and record.original or current
        end
        local helpers = {aim = true, aimpart = true, aimpoint = true, root = true, rootpart = true, humanoidrootpart = true,
            servercollider = true, camera = true, camerapart = true, cameracollider = true, collision = true, collider = true, hitbox = true, pivot = true, origin = true}
        for _, record in ipairs(viewmodelParts) do
            local part, arms, geometry = record.object, record.arms, record.geometry
            -- Never reveal invisible rig blocks, aiming references, or parts hidden by the game.
            local visibleGeometry = geometry and geometry:IsDescendantOf(wanted) and not helpers[geometry.Name:lower()]
                and sourceValue(geometry, "Transparency") < 1 and geometry.LocalTransparencyModifier < 1
            if visibleGeometry and (part.Parent or part:IsA("SurfaceAppearance")) then
                if (arms and state["vm.arms"]) or (not arms and state["vm.gun"]) then
                    if part:IsA("BasePart") then
                        engine:Override(part, "Color", color(arms and "vm.arms#color" or "vm.gun#color"), "viewmodel")
                        engine:Override(part, "Material", Enum.Material[state["vm.material"]], "viewmodel")
                        engine:Override(part, "Transparency", math.max(sourceValue(part, "Transparency"), state["vm.alpha"] / 100), "viewmodel")
                        if part:IsA("MeshPart") then engine:Override(part, "TextureID", "", "viewmodel") end
                    elseif part:IsA("SpecialMesh") then engine:Override(part, "TextureId", "", "viewmodel")
                    elseif part:IsA("SurfaceAppearance") then engine:Override(part, "Parent", nil, "viewmodel")
                    else engine:Override(part, "Transparency", 1, "viewmodel") end
                end
            end
        end
    end
    local function updateProperties(camera)
        updateViewmodel(camera)
        if state["w.bright"] then
            engine:Override(lighting, "Brightness", 2, "bright"); engine:Override(lighting, "Ambient", Color3.new(1, 1, 1), "bright")
            engine:Override(lighting, "OutdoorAmbient", Color3.new(1, 1, 1), "bright")
        else engine:Restore("bright") end
        if state["w.ambient"] then engine:Override(lighting, "Ambient", color("w.ambient#color"), "ambient") else engine:Restore("ambient") end
        if state["w.fog"] then
            engine:Override(lighting, "FogStart", 100000, "fog"); engine:Override(lighting, "FogEnd", 1000000, "fog")
            local atmosphere = lighting:FindFirstChildOfClass("Atmosphere")
            if atmosphere then engine:Override(atmosphere, "Density", 0, "fog"); engine:Override(atmosphere, "Haze", 0, "fog") end
        else engine:Restore("fog") end
        if state["w.shadows"] then engine:Override(lighting, "GlobalShadows", false, "shadows") else engine:Restore("shadows") end
        if state["w.time"] then engine:Override(lighting, "ClockTime", state["w.clock"], "clock") else engine:Restore("clock") end
        if state["cam.zoom"] then engine:Override(player, "CameraMaxZoomDistance", 1000, "zoom") else engine:Restore("zoom") end
        if state["cam.third"] then
            engine:Override(player, "CameraMode", Enum.CameraMode.Classic, "third")
            engine:Override(player, "CameraMinZoomDistance", 6, "third")
        else engine:Restore("third") end
    end
    local function label(parent)
        return make("TextLabel", {BackgroundTransparency = 1, BorderSizePixel = 0, Font = Enum.Font.Code, TextSize = 12,
            TextColor3 = Color3.new(1, 1, 1), TextStrokeColor3 = Color3.new(0, 0, 0), TextStrokeTransparency = 0,
            AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(300, 18), Parent = parent})
    end
    local function line(parent)
        return make("Frame", {BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5), BackgroundColor3 = Color3.new(1, 1, 1), Parent = parent})
    end
    local function setLine(object, first, second, thickness, tint)
        local delta = second - first
        object.Position = UDim2.fromOffset((first.X + second.X) / 2, (first.Y + second.Y) / 2)
        object.Size = UDim2.fromOffset(math.max(1, delta.Magnitude), thickness)
        object.Rotation = math.deg(math.atan2(delta.Y, delta.X)); object.BackgroundColor3 = tint; object.Visible = true
    end
    local function dot(parent, radius, tint)
        local object = make("Frame", {BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(radius * 2, radius * 2), BackgroundColor3 = tint, Parent = parent})
        make("UICorner", {CornerRadius = UDim.new(0.5, 0), Parent = object})
        return object
    end
    local function circle(parent)
        local object = make("Frame", {Name = "AimRadius", AnchorPoint = Vector2.new(0.5, 0.5), BackgroundTransparency = 1, BorderSizePixel = 0, Visible = false, Parent = parent})
        make("UICorner", {CornerRadius = UDim.new(0.5, 0), Parent = object})
        local outline = make("UIStroke", {Thickness = 1, Color = Color3.new(1, 1, 1), Parent = object})
        return {object = object, outline = outline}
    end
    local function destroyPool(name)
        local pool = engine.pools[name]
        if pool then for _, group in ipairs(pool) do group.root:Destroy() end; engine.pools[name] = nil end
    end
    local function groupAt(name, index)
        local pool = engine.pools[name]
        if not pool then pool = {}; engine.pools[name] = pool end
        local group = pool[index]
        if not group then
            local root = make("Frame", {BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = overlayRoot})
            group = {root = root, lines = {}, labels = {label(root), label(root)}, skeleton = {}, boxLines = {}, fill = make("Frame", {BorderSizePixel = 0, BackgroundTransparency = 0.85, Visible = false, Parent = root})}
            pool[index] = group
        end
        group.root.Visible = true
        return group
    end
    local function trimPool(name, count)
        local pool = engine.pools[name]
        if not pool then return end
        for index = #pool, count + 1, -1 do pool[index].root:Destroy(); pool[index] = nil end
    end
    local function projection(camera, position)
        local point, onScreen = camera:WorldToViewportPoint(position)
        return Vector2.new(point.X, point.Y), onScreen and point.Z > 0
    end
    local function nearest(entries, limit, camera, positionFor, maximum, includeOffscreen)
        local selected = {}
        for _, entry in pairs(entries) do
            local position = positionFor(entry)
            if position then
                local distance = (position - camera.CFrame.Position).Magnitude
                if distance <= maximum and (#selected < limit or distance < selected[#selected].distance) then
                    local point, onScreen = projection(camera, position)
                    if onScreen or includeOffscreen then
                        local item = {entry = entry, point = point, distance = distance}
                        local place = #selected + 1
                        while place > 1 and selected[place - 1].distance > distance do place = place - 1 end
                        if place <= limit then table.insert(selected, place, item); if #selected > limit then selected[#selected] = nil end end
                    end
                end
            end
        end
        return selected
    end
    local skeletonLinks = {{"Head", "UpperTorso"}, {"UpperTorso", "LowerTorso"}, {"UpperTorso", "LeftUpperArm"}, {"LeftUpperArm", "LeftLowerArm"}, {"LeftLowerArm", "LeftHand"},
        {"UpperTorso", "RightUpperArm"}, {"RightUpperArm", "RightLowerArm"}, {"RightLowerArm", "RightHand"}, {"LowerTorso", "LeftUpperLeg"}, {"LeftUpperLeg", "LeftLowerLeg"},
        {"LeftLowerLeg", "LeftFoot"}, {"LowerTorso", "RightUpperLeg"}, {"RightUpperLeg", "RightLowerLeg"}, {"RightLowerLeg", "RightFoot"},
        {"Head", "Torso"}, {"Torso", "Left Arm"}, {"Torso", "Right Arm"}, {"Torso", "Left Leg"}, {"Torso", "Right Leg"}}
    local function renderActor(group, entry, camera, distance, npc)
        for _, object in ipairs(group.skeleton) do object.Visible = false end
        for _, object in ipairs(group.boxLines) do object.Visible = false end
        for _, object in ipairs(group.lines) do object.Visible = false end
        local top, topVisible = projection(camera, entry.head.Position + Vector3.new(0, 0.7, 0))
        local bottom, bottomVisible = projection(camera, entry.root.Position - Vector3.new(0, 3, 0))
        if not topVisible or not bottomVisible then group.root.Visible = false; return end
        local height = math.max(12, math.abs(bottom.Y - top.Y)); local width = height * 0.5
        local left, right = top.X - width / 2, top.X + width / 2
        local y1, y2 = math.min(top.Y, bottom.Y), math.max(top.Y, bottom.Y)
        local tint = npc and color("zesp#color") or color("esp.box#color")
        if not npc and state["esp.teamColor"] and entry.player and entry.player.Team then tint = entry.player.TeamColor.Color end
        local boxEnabled = npc or state["esp.box"]
        if boxEnabled then
            local corners = {{Vector2.new(left, y1), Vector2.new(right, y1)}, {Vector2.new(right, y1), Vector2.new(right, y2)}, {Vector2.new(right, y2), Vector2.new(left, y2)}, {Vector2.new(left, y2), Vector2.new(left, y1)}}
            if not npc and state["esp.boxType"] == "Corner" then
                local length = width * 0.25
                corners = {{Vector2.new(left, y1), Vector2.new(left + length, y1)}, {Vector2.new(left, y1), Vector2.new(left, y1 + length)},
                    {Vector2.new(right, y1), Vector2.new(right - length, y1)}, {Vector2.new(right, y1), Vector2.new(right, y1 + length)},
                    {Vector2.new(left, y2), Vector2.new(left + length, y2)}, {Vector2.new(left, y2), Vector2.new(left, y2 - length)},
                    {Vector2.new(right, y2), Vector2.new(right - length, y2)}, {Vector2.new(right, y2), Vector2.new(right, y2 - length)}}
            end
            for index, endpoints in ipairs(corners) do
                if not group.boxLines[index] then group.boxLines[index] = line(group.root) end
                setLine(group.boxLines[index], endpoints[1], endpoints[2], 1, tint)
            end
        end
        group.fill.Visible = not npc and state["esp.fill"]
        if group.fill.Visible then group.fill.Position = UDim2.fromOffset(left, y1); group.fill.Size = UDim2.fromOffset(width, height); group.fill.BackgroundColor3 = color("esp.fill#color") end
        local name = npc and entry.name or state["st.names"] and "Player " .. entry.player.UserId or entry.player.DisplayName
        group.labels[1].Visible = npc or state["esp.name"]
        group.labels[1].Text, group.labels[1].Position = name, UDim2.fromOffset(top.X, y1 - 9)
        group.labels[1].TextColor3 = npc and tint or color("esp.name#color")
        group.labels[2].Visible = npc and state["zesp.dist"] or not npc and state["esp.dist"]
        group.labels[2].Text, group.labels[2].Position = math.floor(distance) .. "m", UDim2.fromOffset(top.X, y2 + 9)
        for _, textObject in ipairs(group.labels) do textObject.TextSize = state["esp.text"]; textObject.TextStrokeTransparency = state["esp.outline"] and 0 or 1 end
        if not npc and state["esp.hp"] then
            local health = entry.humanoid and entry.humanoid.Health or entry.character:GetAttribute("Health")
            local maximum = entry.humanoid and entry.humanoid.MaxHealth or entry.character:GetAttribute("MaxHealth")
            if finite(health) and health > 0 then
                local ratio = math.clamp(health / (finite(maximum) and maximum > 0 and maximum or 100), 0, 1)
                if not group.lines[1] then group.lines[1] = line(group.root) end
                setLine(group.lines[1], Vector2.new(left - 4, y2), Vector2.new(left - 4, y2 - height * ratio), 2, Color3.fromHSV(ratio / 3, 0.8, 1))
            end
        end
        if not npc and state["esp.tracer"] then
            local start = state["esp.tracerFrom"] == "Mouse" and input:GetMouseLocation() or Vector2.new(camera.ViewportSize.X / 2, state["esp.tracerFrom"] == "Top" and 0 or camera.ViewportSize.Y)
            if not group.lines[2] then group.lines[2] = line(group.root) end
            setLine(group.lines[2], start, Vector2.new(top.X, y2), 1, color("esp.tracer#color"))
        end
        if not npc and state["esp.head"] then
            if not group.headDot then group.headDot = dot(group.root, 2, tint) end
            local point = projection(camera, entry.head.Position); group.headDot.Position = UDim2.fromOffset(point.X, point.Y); group.headDot.BackgroundColor3 = color("esp.head#color"); group.headDot.Visible = true
        elseif group.headDot then group.headDot.Visible = false end
        if not npc and state["esp.skel"] then
            if not entry.bones or os.clock() >= (entry.bonesRefresh or 0) then entry.bones = {}; entry.bonesRefresh = os.clock() + 2 end
            for index, names in ipairs(skeletonLinks) do
                for _, namePart in ipairs(names) do if entry.bones[namePart] == nil or entry.bones[namePart] and not entry.bones[namePart].Parent then entry.bones[namePart] = resolveZombieRigPart(entry.character, {namePart}) or false end end
                local first, second = entry.bones[names[1]], entry.bones[names[2]]
                if first and second then
                    local p1, v1 = projection(camera, first.Position); local p2, v2 = projection(camera, second.Position)
                    if v1 and v2 then if not group.skeleton[index] then group.skeleton[index] = line(group.root) end; setLine(group.skeleton[index], p1, p2, 1, color("esp.skel#color")) end
                end
            end
        end
    end
    local function renderActors(camera)
        local players = state.esp and nearest(engine.actors, state["perf.players"], camera, function(entry)
            if not entry.kind and alive(entry) and not (state["esp.team"] and isTeammate(entry.player)) then return entry.head.Position end
        end, state["esp.max"]) or {}
        local zombies = (state.zesp or state["zesp.tactical"]) and nearest(engine.actors, state["perf.zombies"], camera, function(entry)
            if entry.kind and alive(entry) and (state.zesp or entry.tactical) then return entry.head.Position end
        end, state["zesp.max"]) or {}
        for index, item in ipairs(players) do renderActor(groupAt("players", index), item.entry, camera, item.distance, false) end
        for index, item in ipairs(zombies) do renderActor(groupAt("zombies", index), item.entry, camera, item.distance, true) end
        trimPool("players", #players); trimPool("zombies", #zombies)
        engine.counters.players, engine.counters.zombies = #players, #zombies
        if not state.esp then destroyPool("players") end
        if not state.zesp and not state["zesp.tactical"] then destroyPool("zombies") end
        local wanted, count = {}, 0
        if state.chams then
            local selected = nearest(engine.actors, math.min(31, state["perf.players"]), camera, function(entry)
                if not entry.kind and alive(entry) and not (state["esp.team"] and isTeammate(entry.player)) then return entry.root.Position end
            end, state["esp.max"], true)
            for _, item in ipairs(selected) do
                local entry = item.entry
                if count < math.min(31, state["perf.players"]) then
                    count = count + 1; wanted[entry.character] = true
                    local highlight = ownedHighlights[entry.character]
                    if not highlight then highlight = make("Highlight", {Name = "ApexHighlight", Adornee = entry.character, Parent = entry.character}); ownedHighlights[entry.character] = highlight end
                    highlight.FillColor = color("chams.fill"); highlight.OutlineColor = color("chams.line"); highlight.FillTransparency = state["chams.alpha"] / 100
                    highlight.DepthMode = state["chams.walls"] and Enum.HighlightDepthMode.AlwaysOnTop or Enum.HighlightDepthMode.Occluded
                end
            end
        end
        for model, highlight in pairs(ownedHighlights) do if not wanted[model] then highlight:Destroy(); ownedHighlights[model] = nil end end
    end
    local weaponSignatures, signatureBuilt = {}, false
    local function modelSignature(model)
        local pieces = {}
        for _, object in ipairs(model:GetDescendants()) do
            if object:IsA("MeshPart") then pieces[#pieces + 1] = object.Name .. ":" .. object.MeshId
            elseif object:IsA("SpecialMesh") and object.Parent then pieces[#pieces + 1] = object.Parent.Name .. ":" .. object.MeshId end
        end
        if #pieces == 0 then return nil end
        table.sort(pieces); return table.concat(pieces, "|")
    end
    local function buildSignatures()
        if signatureBuilt then return end
        signatureBuilt = true
        local folder = path(services.ReplicatedStorage, {"GunSystemAssets", "GunData"})
        if not folder then return end
        local deadline = os.clock() + 0.001
        for _, weapon in ipairs(folder:GetChildren()) do
            if not engine.active then return end
            local model = weapon:FindFirstChild("WorldModel")
            local signature = model and modelSignature(model)
            if signature then
                if rawget(weaponSignatures, signature) ~= nil then weaponSignatures[signature] = false else weaponSignatures[signature] = weapon.Name end
            end
            if os.clock() >= deadline then task.wait(); deadline = os.clock() + 0.001 end
        end
    end
    local function classifyName(name)
        local key = type(name) == "string" and name:lower() or ""
        if itemCategoryByName[name] or itemCategoryByName[key] then return itemCategoryByName[name] or itemCategoryByName[key] end
        if key:find("ammo", 1, true) then return "ammos" end
        if key:find("repair", 1, true) then return "repairkit" end
        if key:find("helmet", 1, true) then return "helmets" end
        if key:find("vest", 1, true) then return "vests" end
        if key:find("backpack", 1, true) then return "backpacks" end
    end
    local function addWorld(object, kind)
        if worldSeen[object] then return end
        if not kind then
            local metadata = object:GetAttribute("ItemName") or object:GetAttribute("ClassName")
            local name = object.Name:lower() .. (type(metadata) == "string" and " " .. metadata:lower() or "")
            if name:find("grenade", 1, true) or name:find("pipebomb", 1, true) or name:find("molotov", 1, true) then kind = "grenades"
            elseif object:IsA("Model") and (name:find("grave", 1, true) or name:find("lootbag", 1, true) or name == "default" and object:FindFirstChild("TrashBag", true)) then kind = "graves"
            elseif object:IsA("Model") and object.Name == "WorldModel" and object:FindFirstChildWhichIsA("VehicleSeat", true) then kind = "vehicles" end
        end
        if not kind then return end
        if kind == "grenades" then
            local ancestor = object.Parent
            while ancestor and ancestor ~= workspace do
                if ancestor == workspace.CurrentCamera then return end
                if worldSeen[ancestor] and worldSeen[ancestor].kind == "grenades" then return end
                if ancestor:IsA("Model") and ancestor:FindFirstChild("Head") and (ancestor:FindFirstChild("HumanoidRootPart") or ancestor:FindFirstChild("ServerCollider")) then return end
                ancestor = ancestor.Parent
            end
        end
        local attributes = object:GetAttributes()
        local record = {object = object, kind = kind, attributes = attributes}
        record.connection = object.AttributeChanged:Connect(function() record.attributes = object:GetAttributes() end)
        worldSeen[object] = record; engine.world[#engine.world + 1] = record
    end
    local function removeWorld(object)
        local record = worldSeen[object]
        if record then
            if record.connection then record.connection:Disconnect() end
            worldSeen[object] = nil
            local index = table.find(engine.world, record)
            if index then table.remove(engine.world, index) end
        end
    end
    function engine:DiscoverItemNames(force)
        if itemScanBusy or not state["env.items"] or not self.active then return end
        local now = os.clock()
        if not force and now < nextItemScan then return end
        nextItemScan = now + (itemRegistrySource and 5 or 30)
        itemScanBusy = true
        task.spawn(function()
            local deadline, endAt = os.clock() + 0.001, os.clock() + 8
            local function chunk()
                if not allowed() or not state["env.items"] or os.clock() > endAt then return false end
                if os.clock() >= deadline then task.wait(); deadline = os.clock() + 0.001 end
                return true
            end
            local ok, map, count, registry, location = pcall(function()
                if itemRegistrySource then
                    local refreshed, matches = readGroundItemClassMap(itemRegistrySource, itemCategoryByName, chunk)
                    if refreshed then return refreshed, matches, itemRegistrySource, itemDiagnostics.source end
                end
                itemDiagnostics.scans = itemDiagnostics.scans + 1; itemDiagnostics.registry = "searching"
                local observed = {}
                for _, entry in ipairs(engine.world) do
                    local attributes = entry.attributes
                    local id = attributes.CId or attributes.CID or attributes.ClassId
                    if id then observed[id] = true end
                end
                return discoverGroundItemRegistry(itemCategoryByName, itemDiagnostics, chunk, observed)
            end)
            itemScanBusy = false
            if not engine.active then return end
            if ok and map then
                itemClassById, itemRegistrySource = map, registry
                itemDiagnostics.registry, itemDiagnostics.mapped, itemDiagnostics.source = "ready", count, location
                report("Item names ready: " .. count .. " classes")
            else itemDiagnostics.registry = ok and "not found" or "unavailable"; itemDiagnostics.error = not ok and tostring(map) or nil end
        end)
    end
    local worldIndexStarted, worldIndexRevision, grenadesIndexed = false, 0, false
    local worldConnections = {}
    local function worldConnect(signal, callback)
        local revision = worldIndexRevision
        local connection = signal:Connect(function(...) if engine.active and worldIndexStarted and revision == worldIndexRevision then return callback(...) end end)
        worldConnections[#worldConnections + 1] = connection
        return connection
    end
    local function stopWorldIndex()
        worldIndexStarted = false; worldIndexRevision = worldIndexRevision + 1; grenadesIndexed = false
        for _, connection in ipairs(worldConnections) do connection:Disconnect() end
        worldConnections = {}
        for _, entry in ipairs(engine.world) do if entry.connection then entry.connection:Disconnect() end end
        engine.world, worldSeen = {}, {}
    end
    local function startWorldIndex()
        if worldIndexStarted then return end
        worldIndexStarted = true; worldIndexRevision = worldIndexRevision + 1
        local revision = worldIndexRevision
        for _, object in ipairs(collection:GetTagged("GROUND_ITEMS")) do addWorld(object, "items") end
        worldConnect(collection:GetInstanceAddedSignal("GROUND_ITEMS"), function(object) addWorld(object, "items") end)
        worldConnect(collection:GetInstanceRemovedSignal("GROUND_ITEMS"), removeWorld)
        local misc = path(workspace, {"world_assets", "StaticObjects", "Misc"})
        task.spawn(function()
            buildSignatures()
            if not engine.active or not worldIndexStarted or revision ~= worldIndexRevision then return end
            if misc then
                local deadline = os.clock() + 0.001
                local function dropped(object)
                    if not engine.active or not worldIndexStarted or revision ~= worldIndexRevision or worldSeen[object] or not object:IsA("Model") then return end
                    local signature = modelSignature(object)
                    local name = itemCategoryByName[object.Name] == "weapons" and object.Name or signature and weaponSignatures[signature]
                    if name then addWorld(object, "items"); local entry = worldSeen[object]; if entry then entry.detectedName = name end end
                end
                for _, object in ipairs(misc:GetChildren()) do
                    if not engine.active then return end
                    dropped(object)
                    if os.clock() >= deadline then task.wait(); deadline = os.clock() + 0.001 end
                end
                if engine.active and worldIndexStarted and revision == worldIndexRevision then worldConnect(misc.ChildAdded, function(object) task.defer(dropped, object) end) end
            end
        end)
        for _, object in ipairs(workspace:GetChildren()) do addWorld(object) end
        worldConnect(workspace.ChildAdded, function(object) task.defer(function() if engine.active and worldIndexStarted and revision == worldIndexRevision then addWorld(object) end end) end)
        worldConnect(workspace.DescendantRemoving, function(object) if worldSeen[object] then removeWorld(object) end end)
        for _, tag in ipairs({"Grenade", "GRENADE", "Vehicle", "Grave"}) do
            local kind = tag == "Vehicle" and "vehicles" or tag == "Grave" and "graves" or "grenades"
            for _, object in ipairs(collection:GetTagged(tag)) do addWorld(object, kind) end
            worldConnect(collection:GetInstanceAddedSignal(tag), function(object) addWorld(object, kind) end)
        end
    end
    local function indexGrenades()
        if grenadesIndexed or not worldIndexStarted then return end
        grenadesIndexed = true
        local revision = worldIndexRevision
        local function inspect(object)
            if not engine.active or not worldIndexStarted or revision ~= worldIndexRevision or not state["world.grenades"] then return end
            local name = object.Name:lower()
            if (object:IsA("Model") or object:IsA("BasePart")) and (name:find("grenade", 1, true) or name:find("pipebomb", 1, true) or name:find("molotov", 1, true)) then addWorld(object, "grenades") end
        end
        worldConnect(workspace.DescendantAdded, inspect)
        task.spawn(function()
            local deadline = os.clock() + 0.001
            for _, object in ipairs(workspace:GetDescendants()) do
                if not engine.active or not worldIndexStarted or revision ~= worldIndexRevision then return end
                inspect(object)
                if os.clock() >= deadline then task.wait(); deadline = os.clock() + 0.001 end
            end
        end)
    end
    local function worldPosition(entry)
        if not entry.object.Parent then return nil end
        local position = getGroundItemPosition(entry.object, entry.attributes)
        return position
    end
    local function renderWorld(camera)
        local enabled = state["env.items"] or state["world.vehicles"] or state["world.graves"] or state["world.grenades"]
        if not enabled then destroyPool("items"); engine.counters.items = 0; return end
        startWorldIndex()
        if state["world.grenades"] then indexGrenades() end
        if state["env.items"] then engine:DiscoverItemNames() end
        local function eligible(entry)
            if entry.kind == "items" then
                if not state["env.items"] then return end
                local attributes = entry.attributes
                local id = attributes.CId or attributes.CID or attributes.ClassId
                local name = entry.detectedName or attributes.ItemName or attributes.ClassName or id and (itemClassById[id] or itemClassById[tostring(id)]) or entry.object.Name
                local resolved, category = resolveGroundItemName(name, itemCategoryByName)
                category = category or classifyName(name)
                entry.displayName, entry.category = resolved or name, category
                if category and state["item." .. category] == false then return end
                if not category then
                    if not state["item.unknown"] then return end
                    entry.displayName = "Item " .. tostring(id or "?")
                end
            elseif not state["world." .. entry.kind] then return end
            return worldPosition(entry)
        end
        local selected = nearest(engine.world, state["perf.items"], camera, eligible, state["item.max"])
        for index, item in ipairs(selected) do
            local entry = item.entry
            local group = groupAt("items", index)
            group.labels[2].Visible = false; group.fill.Visible = false
            local isGrenade = entry.kind == "grenades"
            local tint = isGrenade and Color3.fromRGB(255, 45, 65) or color("env.items#color", Color3.fromRGB(245, 183, 59))
            if entry.kind == "items" and not entry.category then tint = Color3.fromRGB(145, 145, 145) end
            local title = entry.kind == "items" and entry.displayName or isGrenade and "GRENADE" or entry.kind == "vehicles" and "Vehicle" or "Grave"
            group.labels[1].Text = tostring(title) .. (state["item.dist"] and "  " .. math.floor(item.distance) .. "m" or "")
            group.labels[1].TextSize = isGrenade and 15 or state["esp.text"]
            group.labels[1].TextColor3 = tint; group.labels[1].Position = UDim2.fromOffset(item.point.X, item.point.Y - (isGrenade and 28 or 0))
            for _, object in ipairs(group.boxLines) do object.Visible = false end
            if isGrenade then
                local p = item.point
                local corners = {{Vector2.new(p.X - 20, p.Y - 20), Vector2.new(p.X + 20, p.Y - 20)}, {Vector2.new(p.X + 20, p.Y - 20), Vector2.new(p.X + 20, p.Y + 20)},
                    {Vector2.new(p.X + 20, p.Y + 20), Vector2.new(p.X - 20, p.Y + 20)}, {Vector2.new(p.X - 20, p.Y + 20), Vector2.new(p.X - 20, p.Y - 20)}}
                for i, endpoints in ipairs(corners) do if not group.boxLines[i] then group.boxLines[i] = line(group.root) end; setLine(group.boxLines[i], endpoints[1], endpoints[2], 3, tint) end
            end
        end
        trimPool("items", #selected); engine.counters.items = #selected
    end
    local function getZombieTracker()
        if not zombieTracker then
            zombieTracker = createZombieTracker(function(model)
                assert(engine.modules.characters, "Character adapter is still loading")
                return engine.modules.characters:GetPlayerFromWorldCharacter(model)
            end)
        end
        return zombieTracker
    end
    local function refreshActors()
        refreshPlayerModels()
        local actors, actorByModel = {}, {}
        for _, who in ipairs(services.Players:GetPlayers()) do
            if who ~= player then
                local model = playerModel(who)
                if model and model.Parent then
                    local head = resolveZombieRigPart(model, {"Head"})
                    local root = resolveZombieRigPart(model, {"HumanoidRootPart", "ServerCollider", "RootPart", "UpperTorso", "Torso"}) or model.PrimaryPart or head
                    if head and root then
                        local previous = engine.actorByModel and engine.actorByModel[model]
                        local entry = previous or {character = model}
                        entry.player, entry.head, entry.root, entry.humanoid = who, head, root, model:FindFirstChildOfClass("Humanoid")
                        entry.kind = nil
                        actors[#actors + 1] = entry; actorByModel[model] = entry
                    end
                end
            end
        end
        if state["aim.zombies"] or state.zesp or state["zesp.tactical"] then
            for _, entry in ipairs(getZombieTracker():GetTargets()) do actors[#actors + 1] = entry; actorByModel[entry.character] = entry end
        end
        engine.actors, engine.actorByModel = actors, actorByModel
        local character = player.Character
        if character ~= localPartsModel then
            localPartsModel, localParts = character, {}
            if character then
                for _, object in ipairs(character:GetDescendants()) do if object:IsA("BasePart") then localParts[#localParts + 1] = object end end
                if localCharacterConnection then localCharacterConnection:Disconnect() end
                localCharacterConnection = character.DescendantAdded:Connect(function(object) if localPartsModel == character and object:IsA("BasePart") then localParts[#localParts + 1] = object end end)
            end
            refreshMovementCache()
        end
        if state.hbe then
            hbe.settings.hitbox_enabled, hbe.settings.hitbox_size, hbe.settings.hitbox_color = true, state["hbe.size"], color("hbe#color")
            local wanted = {}
            for _, entry in ipairs(actors) do
                if entry.player and alive(entry) and (not state["hbe.target"] or target and target.character == entry.character) then wanted[entry.character] = true; hbe.manager:Apply(entry.character) end
            end
            for model in pairs(hbe.applied) do if not wanted[model] then hbe.manager:Remove(model) end end
            hbe.applied = wanted
        else hbe.manager:Clear(); hbe.applied = {} end
    end
    local crosshairLines, crosshairDot, crosshairRing
    local function renderCrosshair(camera)
        if not crosshairLines then
            crosshairLines = {}
            for index = 1, 8 do crosshairLines[index] = line(overlayRoot) end
            crosshairDot = dot(overlayRoot, 1, Color3.new(1, 1, 1)); crosshairRing = circle(overlayRoot)
        end
        for _, object in ipairs(crosshairLines) do object.Visible = false end
        crosshairDot.Visible, crosshairRing.object.Visible = false, false
        if not state.xh then return end
        local center, size, gap, thick, tint = camera.ViewportSize / 2, state["xh.size"], state["xh.gap"], state["xh.thick"], color("xh#color")
        local style = state["xh.style"]
        if style == "Cross" or style == "Cross + Dot" then
            local endpoints = {{center + Vector2.new(-gap - size, 0), center + Vector2.new(-gap, 0)}, {center + Vector2.new(gap, 0), center + Vector2.new(gap + size, 0)},
                {center + Vector2.new(0, -gap - size), center + Vector2.new(0, -gap)}, {center + Vector2.new(0, gap), center + Vector2.new(0, gap + size)}}
            for index, pair in ipairs(endpoints) do
                if state["xh.outline"] then setLine(crosshairLines[index + 4], pair[1], pair[2], thick + 2, Color3.new(0, 0, 0)) end
                setLine(crosshairLines[index], pair[1], pair[2], thick, tint)
            end
        end
        if style == "Dot" or style == "Cross + Dot" then crosshairDot.Visible = true; crosshairDot.Position = UDim2.fromOffset(center.X, center.Y); crosshairDot.BackgroundColor3 = tint end
        if style == "Circle" then
            crosshairRing.object.Visible = true; crosshairRing.object.Position = UDim2.fromOffset(center.X, center.Y); crosshairRing.object.Size = UDim2.fromOffset(size * 2, size * 2)
            crosshairRing.outline.Thickness, crosshairRing.outline.Color = thick, tint
        end
    end
    function engine:Describe()
        local playersTracked = 0
        for _, entry in ipairs(self.actors) do if entry.player then playersTracked = playersTracked + 1 end end
        local mapped = 0
        for who, model in pairs(self.modelByPlayer or {}) do if who ~= player and model.Parent then mapped = mapped + 1 end end
        return table.concat({"Apex runtime / 3.2.2", "Actors tracked: " .. #self.actors, "Players tracked: " .. playersTracked .. " / world models mapped: " .. mapped,
            "Visible players: " .. self.counters.players, "Visible zombies: " .. self.counters.zombies,
            "World records: " .. #self.world, "World labels: " .. self.counters.items,
            "Item registry: " .. itemDiagnostics.registry .. " / classes: " .. itemDiagnostics.mapped .. " / scans: " .. itemDiagnostics.scans,
            "Item registry source: " .. (itemDiagnostics.source or "none"), "Item registry error: " .. (itemDiagnostics.error or "none"),
            "Character adapter: " .. tostring(self.modules.characters ~= nil), "Gun plugin: " .. tostring(self.modules.guns ~= nil),
            "Spin route: " .. (self.spinMode or "off"), "Bunnyhop route: " .. (self.bhopMode or "off"), "Viewmodel records: " .. #viewmodelParts,
            hbe and hbe.manager:Describe() or "Hitbox shells: unavailable", "Target: " .. (target and target.character.Name or "none"),
            "Runtime error: " .. (self.lastError or "none"), "Silent aim: no verified adapter; no shot hooks installed"}, "\n")
    end
    function engine:Action(id, selected)
        if id == "runtime.copy" then
            local reportText = self:Describe()
            if type(setclipboard) == "function" then pcall(setclipboard, reportText) end
            report(reportText); api.notify("Runtime diagnostics printed to Output and copied when supported."); return true
        elseif id == "items.rescan" then nextItemScan = 0; self:DiscoverItemNames(true); api.notify("Item-name discovery requested."); return true
        elseif id == "goto" or id == "ut.spawn" then
            local root = localRoot()
            if not root then api.notify("Local movement root is not available."); return false end
            local destination
            if id == "goto" then
                local model = selected and playerModel(selected)
                local part = model and (model.PrimaryPart or resolveZombieRigPart(model, {"HumanoidRootPart", "ServerCollider", "Head"}))
                destination = part and part.Position
            else
                for _, object in ipairs(workspace:GetDescendants()) do if object:IsA("SpawnLocation") then destination = object.Position; break end end
            end
            if not destination then api.notify("No destination is available in this experience."); return false end
            root.CFrame = CFrame.new(destination + Vector3.new(0, 4, 0)); api.notify("Local position updated."); return true
        elseif id == "ut.reset" then
            local _, humanoid = localRoot()
            if not humanoid then api.notify("Reset requires the game's custom character adapter."); return false end
            humanoid.Health = 0; api.notify("Character reset requested."); return true
        elseif id == "srv.rejoin" then
            local ok, err = pcall(function() services.TeleportService:TeleportToPlaceInstance(game.PlaceId, game.JobId, player) end)
            api.notify(ok and "Rejoin requested." or "Rejoin failed: " .. tostring(err)); return ok
        elseif id == "srv.hop" or id == "srv.small" then
            if self.serverBusy then return false end
            self.serverBusy = true
            task.spawn(function()
                local ok, err = pcall(function()
                    local http = game:GetService("HttpService")
                    local cursorValue, candidates = nil, {}
                    for _ = 1, 3 do
                        if not engine.active then return end
                        local url = "https://games.roblox.com/v1/games/" .. game.PlaceId .. "/servers/Public?sortOrder=Asc&limit=100"
                        if cursorValue then url = url .. "&cursor=" .. http:UrlEncode(cursorValue) end
                        local result = http:JSONDecode(game:HttpGet(url))
                        for _, server in ipairs(result.data or {}) do
                            if server.id ~= game.JobId and server.playing < server.maxPlayers then candidates[#candidates + 1] = server end
                        end
                        cursorValue = result.nextPageCursor
                        if not cursorValue or id == "srv.hop" and #candidates > 0 then break end
                    end
                    if not engine.active then return end
                    if #candidates == 0 then api.notify("No joinable server was found."); return end
                    table.sort(candidates, function(a, b) return a.playing < b.playing end)
                    services.TeleportService:TeleportToPlaceInstance(game.PlaceId, candidates[1].id, player)
                    api.notify("Server transfer requested.")
                end)
                engine.serverBusy = false
                if not ok and engine.active then api.notify("Server search failed: " .. tostring(err)) end
            end)
            return true
        end
        return false
    end
    function engine:Change(key, value)
        if unsupported[key] and value == true then api.set(key, false); api.notify(unsupported[key]); return end
        if key == "vm.gun" or key == "vm.arms" or key == "vm.material" or key == "vm.alpha" or key == "vm.gun#color" or key == "vm.arms#color" then
            self:Restore("viewmodel"); nextProperties = 0
        end
        if key == "hbe" and not value and hbe then hbe.manager:Clear(); hbe.applied = {} end
        if key == "mv.bhop" and not value then self:Restore("bhop"); self.bhopMode = "off" end
        if key == "env.items" or key:sub(1, 6) == "world." then
            if value then startWorldIndex()
            elseif not state["env.items"] and not state["world.vehicles"] and not state["world.graves"] and not state["world.grenades"] then stopWorldIndex() end
        end
        if key == "env.items" and value then self:DiscoverItemNames() end
        if key == "env.xray" or key == "env.textures" or key == "env.xrayAlpha" or key == "perf.low" or key == "perf.particles" then self:RefreshEnvironment() end
        if key == "cam.third" and self.modules.guns and type(self.modules.guns.SetThirdPerson) == "function" then
            if value then
                if not self.thirdPersonChanged then
                    local slot = self.modules.guns.Functions and self.modules.guns.Functions.IsThirdPerson
                    if slot and type(rawget(slot, "_callback")) == "function" then
                        local ok, current = pcall(self.modules.guns.IsThirdPerson, self.modules.guns)
                        if ok and type(current) == "boolean" then self.originalThirdPerson = current end
                    end
                end
                self.thirdPersonChanged = pcall(self.modules.guns.SetThirdPerson, self.modules.guns, true)
            elseif self.thirdPersonChanged then
                pcall(self.modules.guns.SetThirdPerson, self.modules.guns, self.originalThirdPerson or false)
                self.thirdPersonChanged = false
            end
        end
        if key == "perf.unlock" or key == "perf.cap" then
            if type(setfpscap) ~= "function" or type(getfpscap) ~= "function" then
                if state["perf.unlock"] then api.set("perf.unlock", false); api.notify("FPS cap control requires getfpscap and setfpscap.") end
            elseif state["perf.unlock"] then
                if not self.originalCap then local ok, current = pcall(getfpscap); if ok and finite(current) and current >= 0 then self.originalCap = current end end
                if self.originalCap then
                    local ok, err = pcall(setfpscap, state["perf.cap"])
                    if ok then self.appliedCap = state["perf.cap"] else api.set("perf.unlock", false); api.notify("FPS cap could not be changed: " .. tostring(err)) end
                else api.set("perf.unlock", false); api.notify("The original FPS cap could not be read.") end
            elseif self.originalCap then
                local ok, current = pcall(getfpscap)
                if ok and current == self.appliedCap then pcall(setfpscap, self.originalCap) end
                self.originalCap, self.appliedCap = nil, nil
            end
        end
        if (key == "aim.zombies" or key == "zesp" or key == "zesp.tactical") and not state["aim.zombies"] and not state.zesp and not state["zesp.tactical"] then
            if zombieTracker then zombieTracker:Destroy(); zombieTracker = nil end
        end
        if key == "trig" and value and type(mouse1click) ~= "function" then api.set("trig", false); api.notify("Triggerbot requires a click input API.") end
        nextActors, nextOverlay, nextProperties = 0, 0, 0
    end
    function engine:Suspend(value)
        self.suspended = value
        if drawGui then drawGui.Enabled = not value end
        if value then
            if spinning and workspace.CurrentCamera then
                spinning = false; self.spinMode = "off"
                local controller, look = self.modules.characterPlugin, workspace.CurrentCamera.CFrame.LookVector
                if controller and type(controller.SetYaw) == "function" then pcall(controller.SetYaw, controller, math.atan2(-look.X, -look.Z)) end
            end
            worldRevision = worldRevision + 1
            if self.thirdPersonChanged and self.modules.guns then
                pcall(self.modules.guns.SetThirdPerson, self.modules.guns, self.originalThirdPerson or false)
                self.thirdPersonChanged = false
            end
            releaseFly(); self:Restore(); self:RefreshEnvironment(); hbe.manager:Clear(); hbe.applied = {}
            for model, highlight in pairs(ownedHighlights) do highlight:Destroy(); ownedHighlights[model] = nil end
        else
            self:RefreshEnvironment(); nextActors, nextProperties, nextItemScan = 0, 0, 0
            if state["cam.third"] then self:Change("cam.third", true) end
        end
    end
    function engine:Destroy()
        if not self.active then return end
        if spinning and workspace.CurrentCamera then
            local controller, look = self.modules.characterPlugin, workspace.CurrentCamera.CFrame.LookVector
            if controller and type(controller.SetYaw) == "function" then pcall(controller.SetYaw, controller, math.atan2(-look.X, -look.Z)) end
        end
        self.active = false; worldRevision = worldRevision + 1
        releaseFly(); self:Restore()
        if environmentConnection then environmentConnection:Disconnect(); environmentConnection = nil end
        environmentCache = nil
        if self.originalCap and type(getfpscap) == "function" and type(setfpscap) == "function" then
            local ok, current = pcall(getfpscap); if ok and current == self.appliedCap then pcall(setfpscap, self.originalCap) end
        end
        if self.thirdPersonChanged and self.modules.guns then pcall(self.modules.guns.SetThirdPerson, self.modules.guns, self.originalThirdPerson or false) end
        if self.renderBinding then pcall(run.UnbindFromRenderStep, run, self.renderBinding) end
        for _, connection in ipairs(self.connections) do connection:Disconnect() end
        self.connections = {}
        for _, entry in ipairs(self.world) do if entry.connection then entry.connection:Disconnect() end end
        self.world = {}
        if viewmodelConnection then viewmodelConnection:Disconnect() end
        if localCharacterConnection then localCharacterConnection:Disconnect() end
        stopWorldIndex()
        if zombieTracker then zombieTracker:Destroy() end
        if hbe then hbe.manager:Destroy() end
        for model, highlight in pairs(ownedHighlights) do highlight:Destroy(); ownedHighlights[model] = nil end
        if drawGui then drawGui:Destroy() end
        self.actors, self.pools = {}, {}
    end
    function engine:Tick(dt)
        if not allowed() then return end
        local camera = workspace.CurrentCamera
        if not camera then if drawGui then drawGui.Enabled = false end; return end
        if drawGui then drawGui.Enabled = true end
        if state["cam.fovEnabled"] then self:Override(camera, "FieldOfView", state["cam.fov"], "fov") else self:Restore("fov") end
        local now = os.clock()
        local needsActors = state.aim or state.trig or state.esp or state.chams or state.hbe or state.zesp or state["zesp.tactical"] or api.playerState.spec
        if needsActors and now >= nextActors then refreshActors(); nextActors = now + 0.25 end
        updateAim(camera, dt); updateMovement(camera, dt); updateSpin(camera, dt)
        if api.playerState.spec then
            local watched = services.Players:GetPlayerByUserId(api.playerState.spec)
            local model = watched and playerModel(watched)
            local root = model and (model.PrimaryPart or resolveZombieRigPart(model, {"HumanoidRootPart", "Head"}))
            if root then self:Override(camera, "CameraType", Enum.CameraType.Scriptable, "spectate"); camera.CFrame = CFrame.lookAt(root.Position + Vector3.new(0, 4, 9), root.Position)
            else api.playerState.spec = nil; self:Restore("spectate") end
        else self:Restore("spectate") end
        if now >= nextProperties then updateProperties(camera); nextProperties = now + 0.2 end
        if now >= nextOverlay then
            renderActors(camera); renderWorld(camera); renderCrosshair(camera)
            local display = circles.aim
            display.object.Visible = state["aim.circle"]
            display.object.Position = UDim2.fromOffset(camera.ViewportSize.X / 2, camera.ViewportSize.Y / 2)
            display.object.Size = UDim2.fromOffset(state["aim.fov"] * 2, state["aim.fov"] * 2)
            display.object.BackgroundTransparency = state["aim.circleFill"] and 0.93 or 1
            display.object.BackgroundColor3 = color("aim.circle#color"); display.outline.Color = color("aim.circle#color")
            local silentCircle = circles.silent
            silentCircle.object.Visible = state["silent.circle"]
            silentCircle.object.Position = UDim2.fromOffset(camera.ViewportSize.X / 2, camera.ViewportSize.Y / 2)
            silentCircle.object.Size = UDim2.fromOffset(state["silent.fov"] * 2, state["silent.fov"] * 2)
            silentCircle.outline.Color = color("silent.circle#color")
            if self.hitMarker then self.hitMarker.Visible = state["ov.hit"] and now < (self.hitUntil or 0); self.hitMarker.Position = UDim2.fromOffset(camera.ViewportSize.X / 2, camera.ViewportSize.Y / 2); self.hitMarker.TextColor3 = color("ov.hit#color") end
            nextOverlay = now + 1 / state["perf.rate"]
        end
    end
    function engine:Start()
        drawGui = make("ScreenGui", {Name = "ApexOverlays", IgnoreGuiInset = true, ResetOnSpawn = false, DisplayOrder = 20, ZIndexBehavior = Enum.ZIndexBehavior.Sibling, Parent = api.playerGui})
        overlayRoot = make("Frame", {BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = drawGui})
        circles = {aim = circle(overlayRoot), silent = circle(overlayRoot)}
        self.hitMarker = label(overlayRoot); self.hitMarker.Text = "×"; self.hitMarker.TextSize = 24; self.hitMarker.Visible = false
        hbe = {settings = {}, applied = {}}
        hbe.manager = createHeadShellExpander(hbe.settings, function(model)
            local entry = engine.actorByModel and engine.actorByModel[model]
            return allowed() and state.hbe and entry and entry.player and alive(entry) and (not state["hbe.target"] or target and target.character == model)
        end)
        local adapters = {
            {"characters", services.ReplicatedFirst, {"GunSystemPlugins", "CustomMeshCharacter"}},
            {"guns", services.ReplicatedFirst, {"GunSystem", "GunController", "Events", "GunPlugin"}},
            {"characterPlugin", services.ReplicatedFirst, {"CustomCharacter", "CharacterController", "CharacterPlugin"}},
            {"playerList", services.ReplicatedStorage, {"CustomCharacter", "PlayerList"}},
            {"replication", services.ReplicatedStorage, {"CustomCharacter", "CharacterReplication"}},
        }
        for _, spec in ipairs(adapters) do
            task.spawn(function()
                for _ = 1, 60 do
                    if not engine.active then return end
                    local module = path(spec[2], spec[3])
                    if module then
                        local ok, result = pcall(require, module)
                        if ok and type(result) == "table" and engine.active then
                            self.modules[spec[1]] = result; nextActors = 0
                            if spec[1] == "guns" then
                                local slot = result.Functions and result.Functions.IsThirdPerson
                                if slot and type(rawget(slot, "_callback")) == "function" then
                                    local read, value = pcall(result.IsThirdPerson, result); if read then self.originalThirdPerson = value end
                                end
                                local signal = result.Signals and result.Signals.OnHitmarker
                                if signal then connect(signal, function() self.hitUntil = os.clock() + 0.15 end) end
                                if state["cam.third"] and not self.suspended then self:Change("cam.third", true) end
                            elseif spec[1] == "replication" and type(result.WaitForCharacterReplication) == "function" then
                                local found, character = pcall(result.WaitForCharacterReplication, result, player)
                                if found and engine.active then self.characterReplication = character end
                            end
                            report("Loaded " .. spec[1] .. " adapter")
                            return
                        end
                    end
                    task.wait(0.5)
                end
            end)
        end
        refreshMovementCache()
        connect(workspace:GetPropertyChangedSignal("CurrentCamera"), function()
            self:Restore("fov"); self:Restore("spectate"); refreshMovementCache(); nextProperties, nextOverlay = 0, 0
        end)
        connect(input.JumpRequest, function()
            if state["mv.infjump"] and not blocked() then
                local root, humanoid = localRoot()
                if humanoid then humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
                elseif root then root.AssemblyLinearVelocity = Vector3.new(root.AssemblyLinearVelocity.X, state["mv.jumpVal"], root.AssemblyLinearVelocity.Z) end
            end
        end)
        connect(input.InputBegan, function(event, processed)
            if processed or blocked() or not state["ch.clicktp"] or event.UserInputType ~= Enum.UserInputType.MouseButton1 or not engine:Held(state["ch.clicktp#key"]) then return end
            local camera, root = workspace.CurrentCamera, localRoot()
            if not camera or not root then return end
            local mouse = input:GetMouseLocation(); local ray = camera:ViewportPointToRay(mouse.X, mouse.Y)
            visibilityParams.FilterDescendantsInstances = player.Character and {player.Character, camera} or {camera}
            local hit = workspace:Raycast(ray.Origin, ray.Direction * 2000, visibilityParams)
            if hit then root.CFrame = CFrame.new(hit.Position + Vector3.new(0, 4, 0)) end
        end)
        connect(player.Idled, function()
            if allowed() and state["ut.afk"] then
                local ok, virtualUser = pcall(game.GetService, game, "VirtualUser")
                if ok then pcall(function() virtualUser:CaptureController(); virtualUser:ClickButton2(Vector2.zero) end) end
            end
        end)
        local function renderStep(dt)
            local ok, err = pcall(self.Tick, self, dt)
            if not ok then
                self.lastError = tostring(err); report("Runtime update failed: " .. self.lastError)
                self:Suspend(true); api.notify("Runtime paused after an error. Copy diagnostics from Output.")
            end
        end
        if type(run.BindToRenderStep) == "function" then
            self.renderBinding = "ApexClientRuntime"
            run:BindToRenderStep(self.renderBinding, Enum.RenderPriority.Camera.Value + 1, renderStep)
        else connect(run.RenderStepped, renderStep) end
        for key, value in pairs(state) do if unsupported[key] and value then api.set(key, false) end end
        if state["perf.unlock"] then self:Change("perf.unlock", true) end
        if state["env.items"] then startWorldIndex() end
        self:RefreshEnvironment()
    end
    return engine
end

--[[
Apex Aftermath - standalone menu and client runtime.
Insert toggles the menu. End suspends runtime effects and hides overlays.
Authentication belongs to the caller's loader; no authorization claim is made here.
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local VERSION = "3.2.2"

local function enumFont(name, fallback)
	local ok, font = pcall(function()
		return Enum.Font[name]
	end)
	return ok and font or fallback
end

local FONT = enumFont("Arimo", Enum.Font.SourceSans)
local FONT_BOLD = enumFont("ArimoBold", Enum.Font.SourceSansBold)
local MONO = enumFont("RobotoMono", Enum.Font.Code)
local TEXT_SIZE = 13

local THEME = {
	Win = Color3.fromRGB(18, 18, 18),
	Title = Color3.fromRGB(13, 13, 13),
	Child = Color3.fromRGB(22, 22, 22),
	Well = Color3.fromRGB(14, 14, 14),
	List = Color3.fromRGB(16, 16, 16),
	Border = Color3.fromRGB(38, 38, 38),
	Border2 = Color3.fromRGB(49, 49, 49),
	Frame = Color3.fromRGB(35, 35, 35),
	FrameHi = Color3.fromRGB(45, 45, 45),
	RowHover = Color3.fromRGB(31, 31, 31),
	Text = Color3.fromRGB(222, 222, 222),
	Dim = Color3.fromRGB(124, 124, 124),
	Faint = Color3.fromRGB(85, 85, 85),
	Black = Color3.new(0, 0, 0),
	White = Color3.new(1, 1, 1),
}
local RED = Color3.fromHex("e8465e")
local TEAM_BLUE = Color3.fromHex("4da3ff")

local function hpColor(hp)
	return Color3.fromHSV(hp / 100 * 120 / 360, 0.75, 0.9)
end

local function clock(v)
	local h = math.floor(v)
	return string.format("%02d:%02d", h, math.round((v - h) * 60))
end

-- ===== schema =====

local function B(id, label)
	return { id = id, label = label }
end
local TABS
do
local function item(kind, id, label, def, opts)
	local it = { type = kind, id = id, label = label, def = def }
	for k, v in pairs(opts or {}) do
		it[k] = v
	end
	return it
end
local function T(id, label, opts)
	return item("toggle", id, label, false, opts)
end
local function S(id, label, min, max, def, opts)
	local it = item("slider", id, label, def, opts)
	it.min, it.max = min, max
	it.step = it.step or 1
	it.unit = it.unit or ""
	return it
end
local function D(id, label, options, def, opts)
	local it = item("select", id, label, def or options[1], opts)
	it.options = options
	return it
end
local function K(id, label, def)
	return item("keybind", id, label, def or "none")
end
local function C(id, label, def)
	return item("color", id, label, def)
end
local function BUTTONS(...)
	return { type = "buttons", items = { ... } }
end
local function INFO(label, value)
	return { type = "info", label = label, value = value }
end

TABS = {
	{
		id = "aiming",
		label = "Aiming",
		cols = {
			{
				{ title = "Aimbot", items = {
					T("aim", "Enabled", { key = "x" }),
					K("aim.hold", "Aim Key", "mouse2"),
					T("tgt.team", "Team Check", { def = true }),
					T("tgt.vis", "Visible Check", { def = true }),
					T("tgt.knock", "Knocked Check", { help = "Skips players that are downed or ragdolled." }),
					T("tgt.sticky", "Sticky Target", { help = "Keeps the current target until they die or leave your FOV." }),
                    T("aim.zombies", "Target Zombies"),
					D("aim.part", "Hit Part", { "Head", "Neck", "Torso", "HumanoidRootPart", "Closest Part" }),
					D("aim.method", "Aim Type", { "Mouse", "Camera" }),
					S("aim.dist", "Distance", 50, 2000, 800, { step = 10, unit = "m" }),
				} },
				{ title = "Prediction", items = {
					T("tgt.pred", "Velocity Prediction", { help = "Leads the target using their current velocity." }),
					T("tgt.resolver", "Resolver", { help = "Corrects for desynced or spoofed positions." }),
					S("tgt.predX", "Prediction X", 0, 1, 0.135, { step = 0.005 }),
					S("tgt.predY", "Prediction Y", 0, 1, 0.11, { step = 0.005 }),
				} },
				{ title = "Aimbot FOV", items = {
					T("aim.circle", "Draw FOV", { def = true, color = Color3.new(1, 1, 1) }),
					T("aim.circleFill", "Filled"),
					S("aim.fov", "Size", 10, 600, 140, { unit = "px" }),
					S("aim.smooth", "Smoothness", 1, 30, 4.5, { step = 0.5 }),
					D("aim.easing", "Easing", { "Linear", "Ease Out", "Exponential" }, "Ease Out"),
				} },
			},
			{
				{ title = "Silent Aim", items = {
					T("silent", "Enabled", { key = "none" }),
					T("silent.circle", "Draw FOV", { color = RED }),
					D("silent.part", "Hit Part", { "Head", "Torso", "Random" }),
					S("silent.chance", "Hit Chance", 0, 100, 70, { unit = "%" }),
					S("silent.fov", "FOV Size", 10, 600, 90, { unit = "px" }),
				} },
				{ title = "Trigger Bot", items = {
					T("trig", "Enabled", { key = "lalt" }),
					T("trig.head", "Head Only"),
					S("trig.delay", "Delay", 0, 300, 45, { unit = "ms", help = "Time between the crosshair landing on a target and firing." }),
					S("trig.chance", "Hit Chance", 0, 100, 85, { unit = "%" }),
				} },
				{ title = "Weapon", items = {
					T("gun.recoil", "No Recoil"),
					T("gun.spread", "No Spread"),
					T("gun.rapid", "Rapid Fire"),
					T("gun.reload", "Instant Reload"),
				} },
			},
		},
	},
	{
		id = "visuals",
		label = "Visuals",
		cols = {
			{
				{ title = "ESP", items = {
					T("esp", "Enabled", { key = "f4" }),
					T("esp.box", "Box", { def = true, color = RED }),
					T("esp.fill", "Box Fill", { color = RED }),
					T("esp.name", "Names", { def = true, color = Color3.new(1, 1, 1) }),
					T("esp.dist", "Distance", { def = true }),
					T("esp.hp", "Health Bar", { def = true }),
					T("esp.skel", "Skeleton", { color = Color3.new(1, 1, 1) }),
					T("esp.head", "Head Dot", { color = RED }),
					T("esp.tracer", "Tracers", { color = RED }),
					D("esp.boxType", "Box Type", { "2D", "Corner" }, "Corner"),
					D("esp.tracerFrom", "Tracer Origin", { "Bottom", "Top", "Mouse" }),
				} },
				{ title = "Chams", items = {
					T("chams", "Enabled", { key = "none" }),
					T("chams.walls", "Through Walls", { def = true }),
					C("chams.fill", "Fill Color", RED),
					C("chams.line", "Outline Color", Color3.new(1, 1, 1)),
					S("chams.alpha", "Fill Transparency", 0, 100, 45, { unit = "%" }),
				} },
			},
			{
				{ title = "Preview", custom = "espPreview" },
				{ title = "ESP Settings", items = {
					T("esp.team", "Team Check", { def = true }),
					T("esp.teamColor", "Use Team Colors"),
					T("esp.outline", "Text Outline", { def = true }),
					S("esp.max", "Max Distance", 100, 3000, 1500, { step = 50, unit = "m" }),
					S("esp.text", "Text Size", 9, 16, 12, { unit = "px" }),
				} },
			},
		},
	},
	{
		id = "world",
		label = "World",
		cols = {
			{
				{ title = "Lighting", items = {
					T("w.bright", "Fullbright"),
					T("w.fog", "No Fog"),
					T("w.shadows", "No Shadows"),
					T("w.ambient", "Ambient", { color = Color3.fromHex("8b5cf6") }),
					T("w.time", "Custom Time"),
					S("w.clock", "Time of Day", 0, 24, 14, { step = 0.25, fmt = clock }),
				} },
				{ title = "Camera", items = {
					T("cam.third", "Third Person", { key = "v" }),
					T("cam.zoom", "Unlock Zoom"),
					T("cam.shake", "No Camera Shake"),
					T("cam.fovEnabled", "Override FOV"),
                    S("cam.fov", "Field of View", 70, 120, 90, { unit = "°" }),
				} },
			},
			{
				{ title = "Crosshair", custom = "crosshairPreview", items = {
					T("xh", "Enabled", { color = Color3.fromHex("36d77f") }),
					T("xh.outline", "Outline", { def = true }),
					D("xh.style", "Style", { "Cross", "Cross + Dot", "Dot", "Circle" }),
					S("xh.size", "Size", 2, 20, 7, { unit = "px" }),
					S("xh.gap", "Gap", 0, 12, 3, { unit = "px" }),
					S("xh.thick", "Thickness", 1, 4, 2, { unit = "px" }),
				} },
				{ title = "Environment", items = {
					T("env.xray", "X-Ray", { key = "none" }),
					T("env.items", "Item ESP", { color = Color3.fromHex("f5b73b") }),
					T("env.textures", "Hide Textures"),
					S("env.xrayAlpha", "Wall Transparency", 0, 100, 60, { unit = "%" }),
				} },
			},
		},
	},
	{
		id = "movement",
		label = "Movement",
		cols = {
			{
				{ title = "Movement", items = {
					T("mv.speed", "WalkSpeed", { key = "none" }),
					T("mv.jump", "JumpPower"),
					T("mv.infjump", "Infinite Jump"),
					T("mv.bhop", "Bunny Hop", { key = "none", help = "Hold Space to jump again on landing. Uses Aftermath auto jump when available." }),
					S("mv.speedVal", "Speed", 16, 250, 32),
					S("mv.jumpVal", "Power", 50, 300, 75),
				} },
				{ title = "Fly", items = {
					T("fly", "Enabled", { key = "f" }),
					T("fly.noclip", "Noclip While Flying", { def = true }),
					D("fly.mode", "Mode", { "Velocity", "CFrame" }),
					S("fly.speed", "Speed", 1, 200, 60),
				} },
			},
			{
				{ title = "Character", items = {
					T("ch.noclip", "Noclip", { key = "n" }),
					T("ch.clicktp", "Click Teleport", { key = "lctrl", help = "Hold the key and click to teleport to your cursor." }),
					T("ch.ragdoll", "Anti Ragdoll"),
					T("ch.fling", "Anti Fling", { def = true }),
					T("ch.spin", "Spinbot"),
					S("ch.spinSpeed", "Spin Speed", 1, 50, 20),
				} },
				{ title = "Utility", items = {
					T("ut.afk", "Anti AFK", { def = false, help = "Stops Roblox from kicking you after 20 minutes idle." }),
					T("ut.respawn", "Auto Respawn"),
					BUTTONS(B("ut.reset", "Reset Character"), B("ut.spawn", "Go to Spawn")),
				} },
			},
		},
	},
	{
		id = "players",
		label = "Player List",
		cols = {
			{ { title = "Players", custom = "plList" } },
			{ { title = "Selected", custom = "plInfo" } },
		},
	},
	{
		id = "misc",
		label = "Misc",
		cols = {
			{
				{ title = "Overlay", items = {
					T("ov.wm", "Watermark", { def = true }),
					T("ov.kb", "Keybind List", { def = true }),
					T("ov.hit", "Hit Markers", { color = Color3.new(1, 1, 1) }),
					D("ov.wmPos", "Watermark Position", { "Top Left", "Top Right" }),
				} },
				{ title = "Performance", items = {
					T("perf.unlock", "FPS Unlocker"),
					T("perf.low", "Low Graphics"),
					T("perf.particles", "Disable Particles"),
					S("perf.cap", "FPS Cap", 30, 360, 240, { step = 5 }),
				} },
			},
			{
				{ title = "Server", items = {
					T("srv.autoRejoin", "Auto Rejoin on Kick"),
					BUTTONS(B("srv.rejoin", "Rejoin"), B("srv.hop", "Server Hop"), B("srv.small", "Smallest Server"), B("srv.job", "Show Job ID")),
				} },
				{ title = "Streaming", items = {
					T("st.proof", "Streamproof", { help = "Capture exclusion is unavailable for this PlayerGui menu." }),
					T("st.names", "Hide Usernames"),
					K("st.panic", "Panic Key", "end"),
				} },
			},
		},
	},
	{
		id = "configs",
		label = "Configs",
		cols = {
			{ { title = "Configs", custom = "cfgList" } },
			{ { title = "Info", custom = "cfgInfo", items = { T("cl.autoload", "Load Last Config on Start", { def = true }) } } },
		},
	},
	{
		id = "output",
		label = "Output",
		cols = { { { title = "Output", custom = "console" } } },
	},
	{
		id = "options",
		label = "Options",
		cols = {
			{
				{ title = "Menu", items = {
					K("ui.key", "Menu Key", "insert"),
					C("ui.accent", "Accent Color", RED),
					T("ui.toasts", "Notifications", { def = true }),
					T("ui.tips", "Tooltips", { def = true }),
					D("ui.scale", "DPI Scale", { "90%", "100%", "110%", "125%" }, "100%"),
				} },
			},
			{
				{ title = "Client", items = {
					INFO("Version", VERSION),
					INFO("Build", "Oct 29 2026"),
					D("cl.channel", "Branch", { "Stable", "Beta" }),
					BUTTONS(B("cl.update", "Check for Updates"), B("cl.unload", "Unload")),
				} },
			},
		},
	},
}


-- Extra sections share the supplied menu's existing widgets and palette.
local function addSection(tabId, column, section)
    for _, tab in ipairs(TABS) do if tab.id == tabId then table.insert(tab.cols[column], section); return end end
end
addSection("aiming", 2, {title = "Hitbox", items = {
    T("hbe", "Head Expander", {color = RED}), T("hbe.target", "Target Only", {def = true}), S("hbe.size", "Size", 1, 5, 5),
}})
addSection("visuals", 2, {title = "Zombies", items = {
    T("zesp", "All Zombies", {color = Color3.fromHex("e9b872")}), T("zesp.tactical", "Tactical Only"),
    T("zesp.dist", "Distance", {def = true}), S("zesp.max", "Max Distance", 50, 3000, 1500, {step = 50, unit = "m"}),
}})
addSection("world", 2, {title = "Item Filters", items = {
    T("item.weapons", "Weapons", {def = true}), T("item.ammos", "Ammunition", {def = true}),
    T("item.medicals", "Medical", {def = true}), T("item.backpacks", "Backpacks", {def = true}),
    T("item.repairkit", "Repair Kits", {def = true}), T("item.helmets", "Helmets", {def = true}), T("item.vests", "Vests", {def = true}),
    T("item.unknown", "Unclassified Items"), T("item.dist", "Distance", {def = true}),
    S("item.max", "Max Distance", 50, 3000, 1000, {step = 50, unit = "m"}), BUTTONS(B("items.rescan", "Rescan Item Names")),
}})
addSection("world", 1, {title = "World ESP", items = {
    T("world.vehicles", "Vehicles"), T("world.graves", "Graves"), T("world.grenades", "Grenade Warnings"),
}})
addSection("movement", 2, {title = "Viewmodel", items = {
    T("vm.gun", "Gun Chams", {color = RED}), T("vm.arms", "Arm Chams", {color = Color3.new(1, 1, 1)}),
    D("vm.material", "Material", {"ForceField", "Neon", "SmoothPlastic"}, "SmoothPlastic"), S("vm.alpha", "Transparency", 0, 90, 0, {unit = "%"}),
}})
addSection("misc", 1, {title = "Overlay Budget", items = {
    S("perf.rate", "Update Rate", 10, 60, 20, {step = 5, unit = "hz"}), S("perf.players", "Player Limit", 8, 64, 32),
    S("perf.zombies", "Zombie Limit", 8, 64, 24), S("perf.items", "World Label Limit", 16, 128, 64),
    BUTTONS(B("runtime.copy", "Copy Runtime Diagnostics")),
}})

end
-- ===== registry & state =====

local DEFAULTS, CONTROLS, TOGGLES = {}, {}, {}
for _, tab in ipairs(TABS) do
	for _, col in ipairs(tab.cols) do
		for _, g in ipairs(col) do
			for _, it in ipairs(g.items or {}) do
				if it.id then
					it.tab = tab.id
					it.name = string.lower(it.label == "Enabled" and g.title or it.label)
					CONTROLS[it.id] = it
					DEFAULTS[it.id] = it.def
					if it.type == "toggle" then
						table.insert(TOGGLES, it.id)
						if it.key then
							DEFAULTS[it.id .. "#key"] = it.key
						end
						if it.color then
							DEFAULTS[it.id .. "#color"] = it.color
						end
					end
				end
			end
		end
	end
end
CONTROLS["pl.sort"] = { id = "pl.sort", type = "select", options = { "Name", "Display Name", "Team" }, def = "Name" }
DEFAULTS["pl.sort"] = "Name"

-- menu options belong to the client, not to a config
local function isLocal(k)
	return k:match("^ui%.") ~= nil or k:match("^cl%.") ~= nil or k:match("^pl%.") ~= nil
end

local function pick(src)
	local out = {}
	for k, def in pairs(DEFAULTS) do
		if not isLocal(k) then
			local v = src[k]
			if v ~= nil and typeof(v) == typeof(def) then
				out[k] = v
			else
				out[k] = def
			end
		end
	end
	return out
end

local state = table.clone(DEFAULTS)

local PRESETS = {
	legit = { aim = true, ["aim.fov"] = 80, ["aim.smooth"] = 9, ["aim.part"] = "Torso", ["tgt.pred"] = true, trig = true, ["trig.delay"] = 90, ["esp.box"] = false },
	rage = {
		aim = true, ["aim.fov"] = 420, ["aim.smooth"] = 1, silent = true, ["silent.chance"] = 100, ["gun.recoil"] = true, ["gun.spread"] = true,
		["gun.rapid"] = true, ["esp.skel"] = true, ["esp.tracer"] = true, ["esp.head"] = true, chams = true, ["mv.speed"] = true, ["mv.speedVal"] = 90,
	},
}
local function withPreset(preset)
	local t = table.clone(DEFAULTS)
	for k, v in pairs(preset) do
		t[k] = v
	end
	return t
end

local startTime = os.time()
local configs = {
	default = { data = pick(DEFAULTS), updated = startTime },
	legit = { data = pick(withPreset(PRESETS.legit)), updated = startTime },
	rage = { data = pick(withPreset(PRESETS.rage)), updated = startTime },
}
local cfgOrder = { "default", "legit", "rage" }
local active, cfgSel = "default", "default"

-- ===== state changes =====

local watchers, anyWatchers = {}, {}
local runtime
local UNSUPPORTED = {silent = "No verified shot adapter in the supplied source", ["tgt.resolver"] = "No resolver implementation", ["gun.recoil"] = "No verified recoil adapter", ["gun.spread"] = "No verified spread adapter", ["gun.rapid"] = "No verified fire rate adapter", ["gun.reload"] = "No verified reload adapter", ["cam.shake"] = "No verified shake adapter", ["ch.ragdoll"] = "Requires custom character integration", ["ut.respawn"] = "Requires game respawn integration", ["srv.autoRejoin"] = "Automatic rejoin is not configured", ["st.proof"] = "PlayerGui cannot guarantee capture exclusion"}
for key, reason in pairs(UNSUPPORTED) do if CONTROLS[key] then CONTROLS[key].available = false; CONTROLS[key].help = reason; DEFAULTS[key], state[key] = false, false end end
local function watch(key, fn)
	watchers[key] = watchers[key] or {}
	table.insert(watchers[key], fn)
	fn(state[key])
end
local function normalize(key, value)
    local control = CONTROLS[key]
    local default = DEFAULTS[key]
    if default == nil or typeof(value) ~= typeof(default) then return nil end
    if type(value) == "number" then
        if value ~= value or math.abs(value) == math.huge then return nil end
        if control and control.type == "slider" then local step = control.step or 1; value = math.clamp(math.round(value / step) * step, control.min, control.max) end
    end
    if control and control.type == "select" and not table.find(control.options, value) then return nil end
    if type(value) == "string" and #value > 64 then return nil end
    return value
end
local function set(key, value)
    value = normalize(key, value)
    if value == nil then return false end
    if UNSUPPORTED[key] and value == true then
        if runtime then runtime:Change(key, true) end
        return false
    end
    if state[key] == value then return true end
    state[key] = value
    for _, fn in ipairs(watchers[key] or {}) do fn(value) end
    for _, fn in ipairs(anyWatchers) do fn(key, value) end
    return true
end
local function accent()
	return state["ui.accent"]
end
local function onAccent(fn)
	watch("ui.accent", function()
		fn()
	end)
end

local connections = {}
local function connect(signal, fn)
	local c = signal:Connect(fn)
	table.insert(connections, c)
	return c
end

local unloaded, panicked = false, false
local capturing, justCancelled = nil, nil
local dragFn = nil
local LOGS = {}

local notify, log, toggleMenu, closePopup, openCombo, openPalette, startCapture, showTip, hideTip
local renderPlayers, renderPlayerInfo, renderConfigs, cfgAction, playerAction, unload, runAction
local refreshPreview, refreshCrosshair, refreshKeybindList

-- ===== instance helpers =====

local order = 0
local function nextOrder()
	order += 1
	return order
end

local function merge(base, extra)
	for k, v in pairs(extra or {}) do
		base[k] = v
	end
	return base
end

local function new(class, props, children)
	local inst = Instance.new(class)
	local parent = nil
	for k, v in pairs(props or {}) do
		if k == "Parent" then
			parent = v
		else
			inst[k] = v
		end
	end
	for _, child in ipairs(children or {}) do
		child.Parent = inst
	end
	if parent then
		inst.Parent = parent
	end
	return inst
end

local function corner(r)
	return new("UICorner", { CornerRadius = UDim.new(0, r) })
end
local function circle()
	return new("UICorner", { CornerRadius = UDim.new(0.5, 0) })
end
local function stroke(color, thickness)
	return new("UIStroke", { Color = color, Thickness = thickness or 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border })
end
local function pad(t, r, b, l)
	r = r or t
	b = b or t
	l = l or r
	return new("UIPadding", {
		PaddingTop = UDim.new(0, t),
		PaddingRight = UDim.new(0, r),
		PaddingBottom = UDim.new(0, b),
		PaddingLeft = UDim.new(0, l),
	})
end
local function vlist(gap, props)
	return new("UIListLayout", merge({ Padding = UDim.new(0, gap or 0), SortOrder = Enum.SortOrder.LayoutOrder }, props))
end
local function hlist(gap, props)
	return new("UIListLayout", merge({
		Padding = UDim.new(0, gap or 0),
		SortOrder = Enum.SortOrder.LayoutOrder,
		FillDirection = Enum.FillDirection.Horizontal,
		VerticalAlignment = Enum.VerticalAlignment.Center,
	}, props))
end
local function text(props)
	return new("TextLabel", merge({
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Font = FONT,
		TextSize = TEXT_SIZE,
		TextColor3 = THEME.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
	}, props))
end
local function button(props, children)
	return new("TextButton", merge({
		AutoButtonColor = false,
		BorderSizePixel = 0,
		BackgroundColor3 = THEME.Frame,
		Font = FONT,
		TextSize = TEXT_SIZE,
		TextColor3 = THEME.Text,
		Text = "",
	}, props), children)
end
local function textBox(props)
	return new("TextBox", merge({
		BackgroundColor3 = THEME.Frame,
		BorderSizePixel = 0,
		ClearTextOnFocus = false,
		Font = FONT,
		TextSize = TEXT_SIZE,
		TextColor3 = THEME.Text,
		PlaceholderColor3 = THEME.Faint,
		TextXAlignment = Enum.TextXAlignment.Left,
		ClipsDescendants = true,
		Text = "",
	}, props), { corner(3), pad(0, 6, 0, 6) })
end
local function hoverize(b)
	b.MouseEnter:Connect(function()
		if not b:GetAttribute("armed") then
			b.BackgroundColor3 = THEME.FrameHi
		end
	end)
	b.MouseLeave:Connect(function()
		if not b:GetAttribute("armed") then
			b.BackgroundColor3 = THEME.Frame
		end
	end)
end
local function arm(b, armedText, normalText)
	b:SetAttribute("armed", true)
	b.Text = armedText
	b.BackgroundColor3 = accent()
	b.TextColor3 = THEME.White
	task.delay(2.5, function()
		if b.Parent and b:GetAttribute("armed") then
			b:SetAttribute("armed", nil)
			b.Text = normalText
			b.BackgroundColor3 = THEME.Frame
			b.TextColor3 = THEME.Text
		end
	end)
end
local function escapeRich(s)
	return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end
local function timestamp()
	local t = os.date("*t")
	return string.format("%02d:%02d:%02d", t.hour, t.min, t.sec)
end
local function isOver(gui, pos)
	local p, s = gui.AbsolutePosition, gui.AbsoluteSize
	return pos.X >= p.X and pos.X <= p.X + s.X and pos.Y >= p.Y and pos.Y <= p.Y + s.Y
end
local function clearGui(container)
	for _, c in ipairs(container:GetChildren()) do
		if c:IsA("GuiObject") then
			c:Destroy()
		end
	end
end
local function spacer(parent, h)
	return new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, h), LayoutOrder = nextOrder(), Parent = parent })
end
local function separator(parent)
	local holder = spacer(parent, 11)
	new("Frame", { BackgroundColor3 = THEME.Border, BorderSizePixel = 0, Position = UDim2.fromOffset(0, 5), Size = UDim2.new(1, 0, 0, 1), Parent = holder })
end

-- ===== key system =====

-- shows the key window and yields until the right key is entered
-- ===== screen gui & overlays =====

local gui = new("ScreenGui", {
	Name = "ApexMenu",
	ResetOnSpawn = false,
	IgnoreGuiInset = false,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	DisplayOrder = 100,
	Parent = PlayerGui,
})

local watermark = new("Frame", {
	BackgroundColor3 = THEME.Win,
	BorderSizePixel = 0,
	AutomaticSize = Enum.AutomaticSize.X,
	Size = UDim2.fromOffset(0, 20),
	ZIndex = 1,
	Parent = gui,
}, { stroke(THEME.Border) })
local wmBar = new("Frame", { BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 2), Parent = watermark })
local wmText = text({ RichText = true, AutomaticSize = Enum.AutomaticSize.X, Position = UDim2.fromOffset(0, 1), Size = UDim2.new(0, 0, 1, -1), Text = "apex", Parent = watermark })
pad(0, 7, 0, 7).Parent = wmText
onAccent(function()
	wmBar.BackgroundColor3 = accent()
end)

local kbList = new("Frame", {
	BackgroundColor3 = THEME.Win,
	BorderSizePixel = 0,
	AutomaticSize = Enum.AutomaticSize.Y,
	Size = UDim2.fromOffset(170, 0),
	ZIndex = 1,
	Parent = gui,
}, { stroke(THEME.Border), vlist(0) })
local kbBar = new("Frame", { BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 2), LayoutOrder = 1, Parent = kbList })
text({ Text = "keybinds", TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.new(1, 0, 0, 17), LayoutOrder = 2, Parent = kbList })
new("Frame", { BackgroundColor3 = THEME.Border, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 1), LayoutOrder = 3, Parent = kbList })
local kbRows = new("Frame", {
	BackgroundTransparency = 1,
	AutomaticSize = Enum.AutomaticSize.Y,
	Size = UDim2.new(1, 0, 0, 0),
	LayoutOrder = 4,
	Parent = kbList,
}, { vlist(0), pad(2, 6, 4, 6) })
onAccent(function()
	kbBar.BackgroundColor3 = accent()
end)

local function placeOverlays()
	if state["ov.wmPos"] == "Top Right" then
		watermark.AnchorPoint = Vector2.new(1, 0)
		watermark.Position = UDim2.new(1, -10, 0, 10)
	else
		watermark.AnchorPoint = Vector2.new(0, 0)
		watermark.Position = UDim2.fromOffset(10, 10)
	end
	local below = state["ov.wm"] and state["ov.wmPos"] == "Top Left"
	kbList.Position = UDim2.fromOffset(10, below and 38 or 10)
end
watch("ov.wm", function(v)
	watermark.Visible = v
	placeOverlays()
end)
watch("ov.wmPos", placeOverlays)
watch("ov.kb", function(v)
	kbList.Visible = v
end)

local notes = new("Frame", {
	BackgroundTransparency = 1,
	AnchorPoint = Vector2.new(1, 1),
	Position = UDim2.new(1, -10, 1, -10),
	Size = UDim2.fromOffset(420, 200),
	ZIndex = 3,
	Parent = gui,
}, { vlist(4, { VerticalAlignment = Enum.VerticalAlignment.Bottom, HorizontalAlignment = Enum.HorizontalAlignment.Right }) })

local tip = text({
	Visible = false,
	BackgroundTransparency = 0,
	BackgroundColor3 = Color3.fromRGB(21, 21, 21),
	AutomaticSize = Enum.AutomaticSize.XY,
	Size = UDim2.new(),
	TextWrapped = true,
	ZIndex = 6,
	Parent = gui,
})
corner(3).Parent = tip
stroke(THEME.Border2).Parent = tip
pad(3, 6, 4, 6).Parent = tip
new("UISizeConstraint", { MaxSize = Vector2.new(240, 1000) }).Parent = tip

function showTip(message)
	if not state["ui.tips"] then
		return
	end
	tip.Text = message
	tip.Visible = true
end
function hideTip()
	tip.Visible = false
end

local popupScale = new("UIScale")
local popup = new("Frame", {
	Visible = false,
	BackgroundColor3 = Color3.fromRGB(21, 21, 21),
	BorderSizePixel = 0,
	AutomaticSize = Enum.AutomaticSize.Y,
	ZIndex = 5,
	Parent = gui,
}, { corner(3), stroke(THEME.Border2), popupScale })
local popupOwner = nil

-- ===== window chrome =====

local BASE_W, BASE_H = 600, 640
local winSize = Vector2.new(BASE_W, BASE_H)
local collapsed = false

local winScale = new("UIScale")
local window = new("Frame", {
	Name = "Window",
	Active = true,
	BackgroundColor3 = THEME.Win,
	BorderSizePixel = 0,
	Size = UDim2.fromOffset(BASE_W, BASE_H),
	ZIndex = 2,
	Parent = gui,
}, { corner(4), stroke(THEME.Border2), winScale })
-- frees the mouse in first-person / shift-lock games while the menu is open
button({ Modal = true, BackgroundTransparency = 1, Size = UDim2.fromOffset(0, 0), Parent = window })

local titlebar = new("Frame", {
	Active = true,
	BackgroundColor3 = THEME.Title,
	BorderSizePixel = 0,
	Size = UDim2.new(1, 0, 0, 22),
	Parent = window,
}, { corner(4) })
new("Frame", { BackgroundColor3 = THEME.Title, BorderSizePixel = 0, Position = UDim2.new(0, 0, 1, -4), Size = UDim2.new(1, 0, 0, 4), Parent = titlebar })
new("Frame", { BackgroundColor3 = THEME.Border, BorderSizePixel = 0, Position = UDim2.new(0, 0, 1, 0), Size = UDim2.new(1, 0, 0, 1), Parent = titlebar })
local collapseBtn = button({ BackgroundTransparency = 1, Text = "▼", TextSize = 10, Position = UDim2.fromOffset(4, 4), Size = UDim2.fromOffset(14, 14), Parent = titlebar })
local mark = text({ Text = "Λ", Font = FONT_BOLD, TextSize = 13, Position = UDim2.fromOffset(21, 0), Size = UDim2.fromOffset(12, 22), Parent = titlebar })
text({
	RichText = true,
	Text = 'apex <font color="#7c7c7c">- v' .. VERSION .. "</font>",
	Position = UDim2.fromOffset(35, 0),
	Size = UDim2.new(1, -40, 1, 0),
	Parent = titlebar,
})
text({
	Text = LocalPlayer.Name,
	TextColor3 = THEME.Dim,
	TextXAlignment = Enum.TextXAlignment.Right,
	Position = UDim2.fromOffset(0, 0),
	Size = UDim2.new(1, -7, 1, 0),
	Parent = titlebar,
})
onAccent(function()
	mark.TextColor3 = accent()
end)

local tabsBar = new("Frame", {
	BackgroundTransparency = 1,
	Position = UDim2.fromOffset(5, 25),
	Size = UDim2.new(1, -10, 0, 20),
	ZIndex = 2,
	Parent = window,
}, { hlist(2) })
local tabsLine = new("Frame", { BackgroundColor3 = THEME.Border, BorderSizePixel = 0, Position = UDim2.fromOffset(0, 45), Size = UDim2.new(1, 0, 0, 1), Parent = window })

local body = new("Frame", {
	BackgroundTransparency = 1,
	ClipsDescendants = true,
	Position = UDim2.fromOffset(0, 46),
	Size = UDim2.new(1, 0, 1, -46),
	Parent = window,
})

local grip = button({
	BackgroundTransparency = 1,
	AnchorPoint = Vector2.new(1, 1),
	Position = UDim2.fromScale(1, 1),
	Size = UDim2.fromOffset(12, 12),
	ZIndex = 3,
	Parent = window,
})
local gripFill = new("Frame", { BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), Parent = grip }, {
	new("UIGradient", {
		Rotation = 45,
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.5, 1),
			NumberSequenceKeypoint.new(0.51, 0.55),
			NumberSequenceKeypoint.new(1, 0.55),
		}),
	}),
})
onAccent(function()
	gripFill.BackgroundColor3 = accent()
end)

local function viewport()
	local size = gui.AbsoluteSize
	if size.X > 0 then
		return size
	end
	local camera = workspace.CurrentCamera
	return camera and camera.ViewportSize or Vector2.new(1280, 720)
end
local function currentScale()
	local vp = viewport()
	local fit = math.min(1, (vp.X - 16) / BASE_W, (vp.Y - 16) / BASE_H)
	local dpi = (tonumber(state["ui.scale"]:match("%d+")) or 100) / 100
	return math.max(0.4, fit) * dpi
end
local function applySize()
	window.Size = UDim2.fromOffset(winSize.X, collapsed and 22 or winSize.Y)
end
local function clampWindow()
	local vp, s = viewport(), currentScale()
	local p = window.Position
	local x = math.clamp(p.X.Offset, math.min(0, 60 - winSize.X * s), math.max(0, vp.X - 60))
	local y = math.clamp(p.Y.Offset, 0, math.max(0, vp.Y - 22 * s))
	window.Position = UDim2.fromOffset(x, y)
end
local function centerWindow()
	local vp, s = viewport(), currentScale()
	window.Position = UDim2.fromOffset(math.floor((vp.X - winSize.X * s) / 2), math.floor((vp.Y - winSize.Y * s) / 2))
end
watch("ui.scale", function()
	winScale.Scale = currentScale()
	clampWindow()
end)

collapseBtn.MouseButton1Click:Connect(function()
	collapsed = not collapsed
	collapseBtn.Text = collapsed and "▶" or "▼"
	tabsBar.Visible = not collapsed
	tabsLine.Visible = not collapsed
	body.Visible = not collapsed
	grip.Visible = not collapsed
	closePopup()
	applySize()
end)

titlebar.InputBegan:Connect(function(input)
	local t = input.UserInputType
	if t ~= Enum.UserInputType.MouseButton1 and t ~= Enum.UserInputType.Touch then
		return
	end
	if isOver(collapseBtn, input.Position) then
		return
	end
	local start, startPos = input.Position, window.Position
	closePopup()
	dragFn = function(pos)
		window.Position = UDim2.fromOffset(startPos.X.Offset + pos.X - start.X, startPos.Y.Offset + pos.Y - start.Y)
		clampWindow()
	end
end)

grip.InputBegan:Connect(function(input)
	local t = input.UserInputType
	if t ~= Enum.UserInputType.MouseButton1 and t ~= Enum.UserInputType.Touch then
		return
	end
	local start, startSize = input.Position, winSize
	closePopup()
	dragFn = function(pos)
		local s = currentScale()
		winSize = Vector2.new(math.max(420, startSize.X + (pos.X - start.X) / s), math.max(300, startSize.Y + (pos.Y - start.Y) / s))
		applySize()
	end
end)

-- ===== popups =====

function closePopup()
	popup.Visible = false
	popupOwner = nil
	local old = popup:FindFirstChild("Body")
	if old then
		old:Destroy()
	end
end

local function openPopup(owner, width)
	closePopup()
	popupOwner = owner
	local s = currentScale()
	popupScale.Scale = s
	popup.Size = UDim2.fromOffset(width / s, 0)
	local panel = new("Frame", {
		Name = "Body",
		BackgroundTransparency = 1,
		AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2.new(1, 0, 0, 0),
		Parent = popup,
	}, { pad(2), vlist(3) })
	local p = owner.AbsolutePosition
	popup.Position = UDim2.fromOffset(p.X, p.Y + owner.AbsoluteSize.Y + 2)
	popup.Visible = true
	-- flip above the owner when it would run off the bottom of the screen
	task.defer(function()
		if popupOwner == owner and popup.AbsolutePosition.Y + popup.AbsoluteSize.Y > viewport().Y then
			popup.Position = UDim2.fromOffset(p.X, p.Y - popup.AbsoluteSize.Y - 2)
		end
	end)
	return panel
end

function openCombo(owner, key, options)
	if popupOwner == owner then
		closePopup()
		return
	end
	local body = openPopup(owner, owner.AbsoluteSize.X)
	for i, option in ipairs(options) do
		local o = button({
			Text = option,
			BackgroundTransparency = 1,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextColor3 = option == state[key] and accent() or THEME.Text,
			Size = UDim2.new(1, 0, 0, 17),
			LayoutOrder = i,
			Parent = body,
		}, { corner(2), pad(0, 6, 0, 6) })
		o.MouseEnter:Connect(function()
			o.BackgroundColor3 = accent()
			o.BackgroundTransparency = 0.65
		end)
		o.MouseLeave:Connect(function()
			o.BackgroundTransparency = 1
		end)
		o.MouseButton1Click:Connect(function()
			closePopup()
			set(key, option)
		end)
	end
end

local PALETTE = { "ffffff", "bdbdbd", "e8465e", "ff7a1a", "f5c518", "36d77f", "22c3ee", "4f7cff", "8b5cf6", "ec4899", "ff5a5f", "000000" }
function openPalette(owner, key)
	if popupOwner == owner then
		closePopup()
		return
	end
	local s = currentScale()
	local body = openPopup(owner, 138 * s)
	local grid = new("Frame", {
		BackgroundTransparency = 1,
		AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2.new(1, 0, 0, 0),
		LayoutOrder = 1,
		Parent = body,
	}, {
		pad(2),
		new("UIGridLayout", { CellSize = UDim2.fromOffset(18, 18), CellPadding = UDim2.fromOffset(3, 3), SortOrder = Enum.SortOrder.LayoutOrder }),
	})
	for i, hex in ipairs(PALETTE) do
		local color = Color3.fromHex(hex)
		local sw = button({ BackgroundColor3 = color, LayoutOrder = i, Parent = grid }, { corner(2), stroke(THEME.Black) })
		sw.MouseButton1Click:Connect(function()
			set(key, color)
			closePopup()
		end)
	end
	local box = textBox({ Text = "#" .. state[key]:ToHex(), PlaceholderText = "#hex", Size = UDim2.new(1, 0, 0, 18), LayoutOrder = 2, Parent = body })
	box.FocusLost:Connect(function(enter)
		local ok, color = pcall(Color3.fromHex, box.Text)
		if ok and color then
			set(key, color)
		end
		if enter then
			closePopup()
		end
	end)
end

-- ===== widgets =====

local comboButton, checkRow, buttonGrid, listBox, listRow, infoRow, buildItem
do
local function decimals(step)
	local d = tostring(step):match("%.(%d+)$")
	return d and #d or 0
end
local function fmtVal(it, v)
	if it.fmt then
		return it.fmt(v)
	end
	return string.format("%." .. (it.dec or decimals(it.step)) .. "f", v) .. (it.unit or "")
end

local function helpMarker(parent, message)
	local h = text({
		Text = "(?)",
		TextColor3 = THEME.Faint,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.new(0, 0, 1, 0),
		LayoutOrder = 3,
		Parent = parent,
	})
	h.MouseEnter:Connect(function()
		h.TextColor3 = THEME.Dim
		showTip(message)
	end)
	h.MouseLeave:Connect(function()
		h.TextColor3 = THEME.Faint
		hideTip()
	end)
end

local function labelLine(parent, label, help)
	local line = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 17), Parent = parent }, { hlist(4) })
	text({ Text = label, AutomaticSize = Enum.AutomaticSize.X, Size = UDim2.new(0, 0, 1, 0), LayoutOrder = 1, Parent = line })
	if help then
		helpMarker(line, help)
	end
	return line
end

local function keybindButton(parent, key, layoutOrder)
	local b = button({ TextSize = 12, TextColor3 = THEME.Dim, Size = UDim2.fromOffset(54, 15), LayoutOrder = layoutOrder or 1, Parent = parent }, { corner(3) })
	hoverize(b)
	b.MouseButton1Click:Connect(function()
		startCapture(b, key)
	end)
	watch(key, function(v)
		if not (capturing and capturing.button == b) then
			b.Text = v
		end
	end)
	return b
end

local function colorSwatch(parent, key, layoutOrder)
	local sw = button({ Size = UDim2.fromOffset(12, 12), LayoutOrder = layoutOrder or 1, Parent = parent }, { corner(2), stroke(THEME.Black) })
	sw.MouseButton1Click:Connect(function()
		openPalette(sw, key)
	end)
	watch(key, function(c)
		sw.BackgroundColor3 = c
	end)
	return sw
end

local function rightHolder(parent)
	return new("Frame", {
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromScale(0, 1),
		Parent = parent,
	}, { hlist(5, { HorizontalAlignment = Enum.HorizontalAlignment.Right }) })
end

-- a clickable checkbox row; returns the row, a holder for widgets on the right, and a setter for its tick
checkRow = function(parent, label, help)
	local row = button({ BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 19), LayoutOrder = nextOrder(), Parent = parent })
	local left = new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = row }, { hlist(6) })
	local box = new("Frame", { BackgroundColor3 = THEME.Frame, BorderSizePixel = 0, Size = UDim2.fromOffset(11, 11), LayoutOrder = 1, Parent = left }, {
		corner(3),
		stroke(THEME.Black),
	})
	local lbl = text({ Text = label, TextColor3 = THEME.Dim, AutomaticSize = Enum.AutomaticSize.X, Size = UDim2.new(0, 0, 1, 0), LayoutOrder = 2, Parent = left })
	if help then
		helpMarker(left, help)
	end
	local right = rightHolder(row)
	local on, hovered = false, false
	local function paint()
		box.BackgroundColor3 = on and accent() or (hovered and THEME.FrameHi or THEME.Frame)
		lbl.TextColor3 = on and THEME.Text or THEME.Dim
	end
	row.MouseEnter:Connect(function()
		hovered = true
		paint()
	end)
	row.MouseLeave:Connect(function()
		hovered = false
		paint()
	end)
	onAccent(paint)
	return row, right, function(v)
		on = v and true or false
		paint()
	end
end

local function toggleWidget(parent, it)
    local label = it.available == false and it.label .. " [unavailable]" or it.label
	local row, right, setOn = checkRow(parent, label, it.help)
	if it.color then
		colorSwatch(right, it.id .. "#color", 1)
	end
	if it.key then
		keybindButton(right, it.id .. "#key", 2)
	end
	row.MouseButton1Click:Connect(function()
		set(it.id, not state[it.id])
	end)
	watch(it.id, setOn)
end

local function slider(parent, it)
	local wrap = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 36), LayoutOrder = nextOrder(), Parent = parent })
	labelLine(wrap, it.label, it.help)
	local bar = button({ Position = UDim2.fromOffset(0, 18), Size = UDim2.new(1, 0, 0, 14), Parent = wrap }, { corner(3) })
	local fill = new("Frame", { BorderSizePixel = 0, Size = UDim2.fromScale(0.5, 1), Parent = bar }, { corner(3) })
	local value = text({
		TextXAlignment = Enum.TextXAlignment.Center,
		TextSize = 12,
		TextColor3 = THEME.White,
		TextStrokeTransparency = 0.5,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 2,
		Parent = bar,
	})
	onAccent(function()
		fill.BackgroundColor3 = accent()
	end)
	local function update(x)
		local rel = math.clamp((x - bar.AbsolutePosition.X) / bar.AbsoluteSize.X, 0, 1)
		local v = it.min + rel * (it.max - it.min)
		v = math.clamp(math.round(v / it.step) * it.step, it.min, it.max)
		v = tonumber(string.format("%.4f", v))
		if v ~= state[it.id] then
			set(it.id, v)
		end
	end
	bar.InputBegan:Connect(function(input)
		local t = input.UserInputType
		if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch then
			update(input.Position.X)
			dragFn = function(pos)
				update(pos.X)
			end
		end
	end)
	watch(it.id, function(v)
		fill.Size = UDim2.fromScale((v - it.min) / (it.max - it.min), 1)
		value.Text = fmtVal(it, v)
	end)
end

comboButton = function(parent, key, options, props)
	local b = button(merge({ TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, Parent = parent }, props), {
		corner(3),
		pad(0, 20, 0, 6),
	})
	text({
		Text = "▼",
		TextSize = 9,
		TextXAlignment = Enum.TextXAlignment.Right,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 14, 0, 0),
		Size = UDim2.new(0, 12, 1, 0),
		Parent = b,
	})
	hoverize(b)
	b.MouseButton1Click:Connect(function()
		openCombo(b, key, options)
	end)
	watch(key, function(v)
		b.Text = v
	end)
	return b
end

local function combo(parent, it)
	local wrap = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 37), LayoutOrder = nextOrder(), Parent = parent })
	labelLine(wrap, it.label, it.help)
	comboButton(wrap, it.id, it.options, { Position = UDim2.fromOffset(0, 18), Size = UDim2.new(1, 0, 0, 16) })
end

local function plainRow(parent)
	return new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 19), LayoutOrder = nextOrder(), Parent = parent })
end

local function keybindRow(parent, it)
	local row = plainRow(parent)
	text({ Text = it.label, Size = UDim2.fromScale(1, 1), Parent = row })
	keybindButton(rightHolder(row), it.id)
end

local function colorRow(parent, it)
	local row = plainRow(parent)
	text({ Text = it.label, Size = UDim2.fromScale(1, 1), Parent = row })
	colorSwatch(rightHolder(row), it.id)
end

infoRow = function(parent, label, value)
	local row = plainRow(parent)
	text({ Text = label, Size = UDim2.fromScale(1, 1), Parent = row })
	return text({ Text = value, TextColor3 = THEME.Dim, TextXAlignment = Enum.TextXAlignment.Right, Size = UDim2.fromScale(1, 1), Parent = row })
end

buttonGrid = function(parent, items, cols, handler)
	local grid = new("Frame", {
		BackgroundTransparency = 1,
		AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2.new(1, 0, 0, 0),
		LayoutOrder = nextOrder(),
		Parent = parent,
	}, {
		pad(4, 0, 0, 0),
		new("UIGridLayout", {
			CellSize = UDim2.new(1 / cols, -4 * (cols - 1) / cols, 0, 18),
			CellPadding = UDim2.fromOffset(4, 4),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	})
	for i, b in ipairs(items) do
		local btn = button({ Text = b.label, LayoutOrder = i, Parent = grid }, { corner(3) })
		hoverize(btn)
		btn.MouseButton1Click:Connect(function()
			local fn = handler or runAction
			fn(b.id, btn)
		end)
	end
end

listBox = function(parent, height)
	return new("ScrollingFrame", {
		BackgroundColor3 = THEME.List,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, height),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 4,
		ScrollBarImageColor3 = Color3.fromRGB(60, 60, 60),
		LayoutOrder = nextOrder(),
		Parent = parent,
	}, { corner(3), stroke(THEME.Border), pad(2), vlist(0) })
end

listRow = function(parent, layoutOrder, leftText, rightText, selected, swatch)
	local row = button({
		BackgroundColor3 = selected and accent() or THEME.RowHover,
		BackgroundTransparency = selected and 0.7 or 1,
		Size = UDim2.new(1, 0, 0, 17),
		LayoutOrder = layoutOrder,
		Parent = parent,
	}, { corner(2), pad(0, 5, 0, 5) })
	local x = 0
	if swatch then
		new("Frame", {
			BackgroundColor3 = swatch,
			BorderSizePixel = 0,
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.fromScale(0, 0.5),
			Size = UDim2.fromOffset(6, 6),
			Parent = row,
		}, { corner(1) })
		x = 12
	end
	text({ Text = leftText, TextTruncate = Enum.TextTruncate.AtEnd, Position = UDim2.fromOffset(x, 0), Size = UDim2.new(1, -x, 1, 0), Parent = row })
	if rightText then
		text({ Text = rightText, TextColor3 = THEME.Dim, TextXAlignment = Enum.TextXAlignment.Right, Size = UDim2.fromScale(1, 1), Parent = row })
	end
	if not selected then
		row.MouseEnter:Connect(function()
			row.BackgroundTransparency = 0
		end)
		row.MouseLeave:Connect(function()
			row.BackgroundTransparency = 1
		end)
	end
	return row
end

buildItem = function(parent, it)
	if it.type == "toggle" then
		toggleWidget(parent, it)
	elseif it.type == "slider" then
		slider(parent, it)
	elseif it.type == "select" then
		combo(parent, it)
	elseif it.type == "keybind" then
		keybindRow(parent, it)
	elseif it.type == "color" then
		colorRow(parent, it)
	elseif it.type == "info" then
		infoRow(parent, it.label, it.value)
	elseif it.type == "buttons" then
		buttonGrid(parent, it.items, 2)
	end
end

end
-- ===== custom panels =====

local CUSTOM = {}

-- ESP preview: a blocky dummy drawn with frames in a 240x300 space, scaled to fit
local PV = 250 / 300
local pv = {}
local function pvRect(x, y, w, h, props, children)
	return new("Frame", merge({
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(x * PV, y * PV),
		Size = UDim2.fromOffset(w * PV, h * PV),
		Parent = pv.canvas,
	}, props), children)
end
local function pvLine(parent, x1, y1, x2, y2, thickness, color, zIndex)
	local dx, dy = (x2 - x1) * PV, (y2 - y1) * PV
	return new("Frame", {
		BorderSizePixel = 0,
		BackgroundColor3 = color,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset((x1 + x2) / 2 * PV, (y1 + y2) / 2 * PV),
		Size = UDim2.fromOffset(math.sqrt(dx * dx + dy * dy) + thickness, thickness),
		Rotation = math.deg(math.atan2(dy, dx)),
		ZIndex = zIndex or 1,
		Parent = parent,
	})
end

CUSTOM.espPreview = function(g)
	local holder = new("Frame", {
		BackgroundColor3 = THEME.Well,
		BorderSizePixel = 0,
		ClipsDescendants = true,
		Size = UDim2.new(1, 0, 0, 250),
		LayoutOrder = nextOrder(),
		Parent = g,
	}, { corner(3), stroke(THEME.Border) })
	pv.canvas = new("Frame", {
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0),
		Size = UDim2.fromOffset(240 * PV, 250),
		Parent = holder,
	})
	local function layer(z)
		return new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = z, Parent = pv.canvas })
	end

	pv.tracer = layer(1)
	pv.parts = {}
	for _, r in ipairs({ { 101, 60, 38, 36, 6 }, { 96, 100, 48, 62 }, { 74, 100, 20, 62 }, { 146, 100, 20, 62 }, { 96, 164, 23, 62 }, { 121, 164, 23, 62 } }) do
		local outline = stroke(Color3.fromRGB(54, 54, 54))
		local part = pvRect(r[1], r[2], r[3], r[4], { ZIndex = 2 }, { outline })
		if r[5] then
			corner(r[5]).Parent = part
		end
		table.insert(pv.parts, { frame = part, stroke = outline })
	end
	pv.fill = pvRect(66, 52, 108, 182, { BackgroundTransparency = 0.82, ZIndex = 3 })

	pv.skel = layer(4)
	for _, s in ipairs({ { 120, 78, 120, 162 }, { 84, 106, 156, 106 }, { 84, 106, 84, 158 }, { 156, 106, 156, 158 }, { 107, 162, 133, 162 }, { 107, 162, 107, 222 }, { 133, 162, 133, 222 } }) do
		pvLine(pv.skel, s[1], s[2], s[3], s[4], 1, THEME.White)
	end

	pv.box = layer(5)
	pvRect(66, 52, 108, 182, { BackgroundTransparency = 1, Parent = pv.box }, { stroke(THEME.Black, 3) })
	pv.boxStroke = stroke(RED, 1)
	pvRect(66, 52, 108, 182, { BackgroundTransparency = 1, ZIndex = 2, Parent = pv.box }, { pv.boxStroke })

	pv.corner = layer(5)
	pv.cornerLines = {}
	local segments = { { 66, 78, 66, 52 }, { 66, 52, 88, 52 }, { 152, 52, 174, 52 }, { 174, 52, 174, 78 }, { 174, 208, 174, 234 }, { 174, 234, 152, 234 }, { 88, 234, 66, 234 }, { 66, 234, 66, 208 } }
	for _, s in ipairs(segments) do
		pvLine(pv.corner, s[1], s[2], s[3], s[4], 3, THEME.Black, 1)
	end
	for _, s in ipairs(segments) do
		table.insert(pv.cornerLines, pvLine(pv.corner, s[1], s[2], s[3], s[4], 1, RED, 2))
	end

	pv.hp = layer(6)
	pvRect(57, 51, 5, 184, { BackgroundColor3 = THEME.Black, Parent = pv.hp })
	pv.hpFill = pvRect(58, 52 + 182 * 0.28, 3, 182 * 0.72, { BackgroundColor3 = hpColor(72), ZIndex = 2, Parent = pv.hp })

	pv.head = pvRect(116.5, 74.5, 7, 7, { ZIndex = 7 }, { circle() })
	pv.name = text({ TextXAlignment = Enum.TextXAlignment.Center, ZIndex = 8, Parent = pv.canvas })
	pv.dist = text({
		Text = "48m",
		TextColor3 = Color3.fromRGB(207, 207, 207),
		TextXAlignment = Enum.TextXAlignment.Center,
		Position = UDim2.fromOffset(0, 238 * PV),
		Size = UDim2.fromOffset(240 * PV, 14),
		ZIndex = 8,
		Parent = pv.canvas,
	})
end

function refreshPreview()
	if not pv.canvas then
		return
	end
	local esp = state.esp
	local boxColor = state["esp.teamColor"] and TEAM_BLUE or state["esp.box#color"]
	pv.box.Visible = esp and state["esp.box"] and state["esp.boxType"] == "2D"
	pv.corner.Visible = esp and state["esp.box"] and state["esp.boxType"] == "Corner"
	pv.boxStroke.Color = boxColor
	for _, l in ipairs(pv.cornerLines) do
		l.BackgroundColor3 = boxColor
	end
	pv.fill.Visible = esp and state["esp.fill"]
	pv.fill.BackgroundColor3 = state["esp.fill#color"]
	pv.skel.Visible = esp and state["esp.skel"]
	for _, l in ipairs(pv.skel:GetChildren()) do
		l.BackgroundColor3 = state["esp.skel#color"]
	end
	pv.head.Visible = esp and state["esp.head"]
	pv.head.BackgroundColor3 = state["esp.head#color"]
	pv.hp.Visible = esp and state["esp.hp"]

	local size = state["esp.text"]
	local strokeAlpha = state["esp.outline"] and 0 or 1
	pv.name.Visible = esp and state["esp.name"]
	pv.name.Text = state["st.names"] and "Player" or LocalPlayer.Name
	pv.name.TextColor3 = state["esp.name#color"]
	pv.name.TextSize = size
	pv.name.TextStrokeTransparency = strokeAlpha
	pv.name.Size = UDim2.fromOffset(240 * PV, size + 2)
	pv.name.Position = UDim2.fromOffset(0, 48 * PV - size - 2)
	pv.dist.Visible = esp and state["esp.dist"]
	pv.dist.TextSize = size - 1
	pv.dist.TextStrokeTransparency = strokeAlpha

	clearGui(pv.tracer)
	if esp and state["esp.tracer"] then
		local o = ({ Bottom = { 120, 300, 120, 234 }, Top = { 120, 0, 120, 52 }, Mouse = { 206, 284, 120, 234 } })[state["esp.tracerFrom"]]
		pvLine(pv.tracer, o[1], o[2], o[3], o[4], 1, state["esp.tracer#color"])
	end

	for _, p in ipairs(pv.parts) do
		if state.chams then
			p.frame.BackgroundColor3 = state["chams.fill"]
			p.frame.BackgroundTransparency = state["chams.alpha"] / 100
			p.stroke.Color = state["chams.line"]
		else
			p.frame.BackgroundColor3 = Color3.fromRGB(36, 36, 36)
			p.frame.BackgroundTransparency = 0
			p.stroke.Color = Color3.fromRGB(54, 54, 54)
		end
	end
end

local xh = {}
CUSTOM.crosshairPreview = function(g)
	xh.box = new("Frame", {
		BackgroundColor3 = THEME.Well,
		BorderSizePixel = 0,
		ClipsDescendants = true,
		Size = UDim2.new(1, 0, 0, 64),
		LayoutOrder = nextOrder(),
		Parent = g,
	}, { corner(3), stroke(THEME.Border) })
	spacer(g, 3)
end

function refreshCrosshair()
	if not xh.box then
		return
	end
	clearGui(xh.box)
	local color, size, gap, thick, style = state["xh#color"], state["xh.size"], state["xh.gap"], state["xh.thick"], state["xh.style"]
	local alpha = state.xh and 0 or 0.75
	local outline = state["xh.outline"]
	local function r(x, y, w, h)
		local f = new("Frame", {
			BorderSizePixel = 0,
			BackgroundColor3 = color,
			BackgroundTransparency = alpha,
			Position = UDim2.new(0.5, x, 0.5, y),
			Size = UDim2.fromOffset(w, h),
			Parent = xh.box,
		})
		if outline then
			new("UIStroke", { Color = THEME.Black, Transparency = alpha, Parent = f })
		end
	end
	if style:sub(1, 5) == "Cross" then
		r(-gap - size, -thick / 2, size, thick)
		r(gap, -thick / 2, size, thick)
		r(-thick / 2, -gap - size, thick, size)
		r(-thick / 2, gap, thick, size)
	end
	if style == "Dot" or style == "Cross + Dot" then
		local d = style == "Dot" and math.max(thick + 1, math.round(size / 2.5)) or thick
		r(-d / 2, -d / 2, d, d)
	end
	if style == "Circle" then
		local diameter = (gap + size / 2) * 2
		local function ring(c, t, z)
			new("Frame", {
				BackgroundTransparency = 1,
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromOffset(diameter, diameter),
				ZIndex = z,
				Parent = xh.box,
			}, { circle(), new("UIStroke", { Color = c, Thickness = t, Transparency = alpha }) })
		end
		if outline then
			ring(THEME.Black, thick + 2, 1)
		end
		ring(color, thick, 2)
	end
end

-- player list
local plState = { query = "", selected = LocalPlayer, spec = nil, target = {}, white = {} }
local pl = {}

CUSTOM.plList = function(g)
	local top = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 18), LayoutOrder = nextOrder(), Parent = g }, { hlist(4) })
	pl.search = textBox({ PlaceholderText = "Search...", Size = UDim2.new(1, -100, 1, 0), LayoutOrder = 1, Parent = top })
	comboButton(top, "pl.sort", CONTROLS["pl.sort"].options, { Size = UDim2.fromOffset(96, 16), LayoutOrder = 2 })
	spacer(g, 4)
	pl.list = listBox(g, 330)
	pl.search:GetPropertyChangedSignal("Text"):Connect(function()
		plState.query = pl.search.Text
		renderPlayers()
	end)
end

CUSTOM.plInfo = function(g)
	pl.info = {}
	for _, k in ipairs({ "Username", "Display Name", "User ID", "Team", "Account Age", "Membership" }) do
		pl.info[k] = infoRow(g, k, "")
	end
	separator(g)
	pl.checks = {}
	for _, c in ipairs({ { "spec", "Spectate" }, { "target", "Prioritize Target" }, { "white", "Whitelist" } }) do
		local row, _, setOn = checkRow(g, c[2])
		row.MouseButton1Click:Connect(function()
			playerAction(c[1])
		end)
		pl.checks[c[1]] = setOn
	end
	buttonGrid(g, { B("goto", "Teleport To"), B("refresh", "Refresh") }, 2, function(id)
		playerAction(id)
	end)
end

function renderPlayers()
	if not pl.list then
		return
	end
	clearGui(pl.list)
	local q = plState.query:lower()
	local rows = {}
	for _, p in ipairs(Players:GetPlayers()) do
		if q == "" or p.Name:lower():find(q, 1, true) or p.DisplayName:lower():find(q, 1, true) then
			table.insert(rows, p)
		end
	end
	local sort = state["pl.sort"]
	table.sort(rows, function(a, b)
		if sort == "Display Name" then
			return a.DisplayName:lower() < b.DisplayName:lower()
		elseif sort == "Team" then
			local ta, tb = a.Team and a.Team.Name or "~", b.Team and b.Team.Name or "~"
			if ta ~= tb then
				return ta < tb
			end
		end
		return a.Name:lower() < b.Name:lower()
	end)
	if #rows == 0 then
		text({ Text = "no players found", TextColor3 = THEME.Dim, Size = UDim2.new(1, 0, 0, 17), Parent = pl.list })
	end
	for i, p in ipairs(rows) do
		local label = p.Name .. (p == LocalPlayer and " (you)" or "")
		local row = listRow(pl.list, i, label, "@" .. p.DisplayName, p == plState.selected, p.Team and p.TeamColor.Color or THEME.Faint)
		row.MouseButton1Click:Connect(function()
			plState.selected = p
			renderPlayers()
		end)
	end
	renderPlayerInfo()
end

function renderPlayerInfo()
	if not pl.info then
		return
	end
	local p = plState.selected
	if not p or p.Parent ~= Players then
		p = LocalPlayer
		plState.selected = p
	end
	pl.info["Username"].Text = p.Name
	pl.info["Display Name"].Text = "@" .. p.DisplayName
	pl.info["User ID"].Text = tostring(p.UserId)
	pl.info["Team"].Text = p.Team and p.Team.Name or "none"
	pl.info["Team"].TextColor3 = p.Team and p.TeamColor.Color or THEME.Dim
	pl.info["Account Age"].Text = p.AccountAge .. " days"
	pl.info["Membership"].Text = p.MembershipType == Enum.MembershipType.Premium and "Premium" or "None"
	pl.checks.spec(plState.spec == p.UserId)
	pl.checks.target(plState.target[p.UserId] == true)
	pl.checks.white(plState.white[p.UserId] == true)
end

function playerAction(act)
	local p = plState.selected
	if not p then
		return
	end
	local id, name = p.UserId, p.Name
	if act == "spec" then
		plState.spec = plState.spec ~= id and id or nil
		notify(plState.spec and "spectating " .. name or "stopped spectating")
	elseif act == "target" then
		plState.target[id] = not plState.target[id] or nil
		notify(plState.target[id] and "prioritizing " .. name or name .. " is no longer prioritized")
	elseif act == "white" then
		plState.white[id] = not plState.white[id] or nil
		notify(plState.white[id] and name .. " added to whitelist" or name .. " removed from whitelist")
	elseif act == "goto" then
        if runtime then runtime:Action("goto", p) end
	elseif act == "refresh" then
		renderPlayers()
	end
	renderPlayerInfo()
end

-- configs
local cf = {}
local lastCfgClick = { name = nil, at = 0 }

local function ago(ts)
	local s = os.time() - ts
	if s < 60 then
		return "just now"
	elseif s < 3600 then
		return math.floor(s / 60) .. "m ago"
	elseif s < 86400 then
		return math.floor(s / 3600) .. "h ago"
	end
	return math.floor(s / 86400) .. "d ago"
end

local function encodeCfg(data)
	local out = {}
	for k, v in pairs(data) do
		out[k] = typeof(v) == "Color3" and ("#" .. v:ToHex()) or v
	end
	return "apex:" .. HttpService:JSONEncode(out)
end

local function decodeCfg(str)
	if type(str) ~= "string" or str:sub(1, 5) ~= "apex:" then
		return nil
	end
	local ok, obj = pcall(HttpService.JSONDecode, HttpService, str:sub(6))
	if not ok or type(obj) ~= "table" then
		return nil
	end
	local out = {}
	for k, def in pairs(DEFAULTS) do
		if not isLocal(k) then
			local v = obj[k]
			if typeof(def) == "Color3" and type(v) == "string" then
				local okColor, color = pcall(Color3.fromHex, v)
				v = okColor and color or nil
			end
			if v ~= nil and typeof(v) == typeof(def) then
				out[k] = v
			else
				out[k] = def
			end
		end
	end
	return out
end

local function importCfg(data)
	local name, i = "imported", 2
	while configs[name] do
		name = "imported-" .. i
		i += 1
	end
	configs[name] = { data = data, updated = os.time() }
	table.insert(cfgOrder, name)
	cfgSel = name
	notify("imported config '" .. name .. "'")
	renderConfigs()
end

CUSTOM.cfgList = function(g)
	cf.list = listBox(g, 150)
	spacer(g, 4)
	cf.name = textBox({ PlaceholderText = "Config name...", Size = UDim2.new(1, 0, 0, 18), LayoutOrder = nextOrder(), Parent = g })
	buttonGrid(g, {
		B("create", "Create"),
		B("save", "Save"),
		B("load", "Load"),
		B("delete", "Delete"),
		B("export", "Export"),
		B("import", "Import"),
	}, 3, function(id, btn)
		cfgAction(id, btn)
	end)
end

CUSTOM.cfgInfo = function(g)
	cf.info = {}
	for _, k in ipairs({ "Name", "Modified", "Changed Settings", "Status" }) do
		cf.info[k] = infoRow(g, k, "")
	end
	separator(g)
end

function renderConfigs()
	if not cf.list then
		return
	end
	if not configs[cfgSel] then
		cfgSel = active
	end
	clearGui(cf.list)
	for i, name in ipairs(cfgOrder) do
		local row = listRow(cf.list, i, name, name == active and "loaded" or nil, name == cfgSel)
		row.MouseButton1Click:Connect(function()
			local now = os.clock()
			local double = lastCfgClick.name == name and now - lastCfgClick.at < 0.35
			lastCfgClick.name, lastCfgClick.at = name, now
			cfgSel = name
			if double then
				cfgAction("load")
			else
				renderConfigs()
			end
		end)
	end
	local c = configs[cfgSel]
	local changes = 0
	for k, v in pairs(c.data) do
		if v ~= DEFAULTS[k] then
			changes += 1
		end
	end
	cf.info["Name"].Text = cfgSel
	cf.info["Modified"].Text = ago(c.updated)
	cf.info["Changed Settings"].Text = tostring(changes)
	cf.info["Status"].Text = cfgSel == active and "loaded" or "not loaded"
end

function cfgAction(id, btn)
	local name = cfgSel
	if id == "create" then
		local n = cf.name.Text:match("^%s*(.-)%s*$")
		local pasted = decodeCfg(n)
		if pasted then
			cf.name.Text = ""
			importCfg(pasted)
			return
		end
		if #n > 48 then notify("Config names must be 48 characters or fewer."); return end
		if #cfgOrder >= 50 then notify("Config limit reached."); return end
		if n == "" then
			notify("enter a config name first")
			return
		end
		if configs[n] then
			notify("config '" .. n .. "' already exists")
			return
		end
		configs[n] = { data = pick(state), updated = os.time() }
		table.insert(cfgOrder, n)
		active, cfgSel = n, n
		cf.name.Text = ""
		notify("created config '" .. n .. "'")
	elseif id == "save" then
		configs[name] = { data = pick(state), updated = os.time() }
		active = name
		notify("saved config '" .. name .. "'")
	elseif id == "load" then
		for k, v in pairs(configs[name].data) do
			set(k, v)
		end
		active = name
		notify("loaded config '" .. name .. "'")
	elseif id == "export" then
		cf.name.Text = encodeCfg(configs[name].data)
		notify("config string is in the name box, copy it with ctrl+c")
	elseif id == "import" then
		local data = decodeCfg(cf.name.Text)
		if not data then
			notify("paste an apex: config string into the name box first")
			return
		end
		cf.name.Text = ""
		importCfg(data)
		return
	elseif id == "delete" then
		if #cfgOrder == 1 then
			notify("you need at least one config")
			return
		end
		if btn and not btn:GetAttribute("armed") then
			arm(btn, "Confirm", "Delete")
			return
		end
		if btn then
			btn:SetAttribute("armed", nil)
			btn.Text = "Delete"
			btn.BackgroundColor3 = THEME.Frame
			btn.TextColor3 = THEME.Text
		end
		configs[name] = nil
		table.remove(cfgOrder, table.find(cfgOrder, name))
		if active == name then
			active = cfgOrder[1]
		end
		cfgSel = active
		notify("deleted config '" .. name .. "'")
	end
	renderConfigs()
end

-- output console
local con = { count = 0 }
local LOG_COLORS = { ok = "#7bc67e", dim = "#7c7c7c" }

local function addLogLine(l)
	if not con.box then
		return
	end
	con.count += 1
	text({
        Name = "ApexLogLine",
		RichText = true,
		Font = MONO,
		TextSize = 12,
		TextWrapped = true,
		AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2.new(1, 0, 0, 0),
		LayoutOrder = con.count,
		Text = string.format('<font color="#555555">[%s]</font> <font color="%s">%s</font>', l.t, LOG_COLORS[l.kind] or "#bdbdbd", escapeRich(l.msg)),
		Parent = con.box,
	})
	task.defer(function()
		local box = con.box
		if box and box.Parent then
			box.CanvasPosition = Vector2.new(0, math.max(0, box.AbsoluteCanvasSize.Y - box.AbsoluteWindowSize.Y))
		end
	end)
end

function log(msg, kind)
	local l = { t = timestamp(), msg = msg, kind = kind }
	table.insert(LOGS, l)
	if #LOGS > 300 then
		table.remove(LOGS, 1)
        if con.box then local oldest = con.box:FindFirstChild("ApexLogLine"); if oldest then oldest:Destroy() end end
	end
	addLogLine(l)
end

CUSTOM.console = function(g)
	con.box = new("ScrollingFrame", {
		BackgroundColor3 = THEME.Well,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 400),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 4,
		ScrollBarImageColor3 = Color3.fromRGB(60, 60, 60),
		LayoutOrder = nextOrder(),
		Parent = g,
	}, { corner(3), stroke(THEME.Border), pad(4, 6, 4, 6), vlist(1) })
	for _, l in ipairs(LOGS) do
		addLogLine(l)
	end
	buttonGrid(g, { B("con.clear", "Clear"), B("con.dump", "Dump Server Info") }, 2)
end

-- ===== notifications & keybind overlay =====

local noteCount = 0
function notify(msg, kind)
	log(msg, kind)
	if not state["ui.toasts"] or unloaded then
		return
	end
	noteCount += 1
	local note = new("Frame", {
		BackgroundColor3 = THEME.Win,
		BorderSizePixel = 0,
		AutomaticSize = Enum.AutomaticSize.XY,
		Size = UDim2.new(),
		LayoutOrder = noteCount,
		Parent = notes,
	}, { stroke(THEME.Border), pad(3, 8, 4, 10) })
	new("Frame", { BackgroundColor3 = accent(), BorderSizePixel = 0, Position = UDim2.fromOffset(-10, -3), Size = UDim2.new(0, 2, 1, 7), Parent = note })
	text({
		RichText = true,
		AutomaticSize = Enum.AutomaticSize.XY,
		Size = UDim2.new(),
		Text = string.format('<font color="#%s">[apex]</font> %s', accent():ToHex(), escapeRich(msg)),
		Parent = note,
	})
	local shown = {}
	for _, c in ipairs(notes:GetChildren()) do
		if c:IsA("Frame") then
			table.insert(shown, c)
		end
	end
	table.sort(shown, function(a, b)
		return a.LayoutOrder < b.LayoutOrder
	end)
	while #shown > 5 do
		local oldest = table.remove(shown, 1)
		if oldest then
			oldest:Destroy()
		end
	end
	task.delay(3, function()
		if note.Parent then
			note:Destroy()
		end
	end)
end

function refreshKeybindList()
	clearGui(kbRows)
	local count = 0
	for _, id in ipairs(TOGGLES) do
		local key = state[id .. "#key"]
		if key and key ~= "none" then
			count += 1
			local on = state[id]
			local row = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 16), LayoutOrder = count, Parent = kbRows })
			text({ Text = CONTROLS[id].name, TextColor3 = on and THEME.Text or THEME.Dim, Size = UDim2.fromScale(1, 1), Parent = row })
			text({
				Text = "[" .. key .. "]",
				TextColor3 = on and accent() or THEME.Faint,
				TextXAlignment = Enum.TextXAlignment.Right,
				Size = UDim2.fromScale(1, 1),
				Parent = row,
			})
		end
	end
	if count == 0 then
		text({ Text = "none", TextColor3 = THEME.Dim, Size = UDim2.new(1, 0, 0, 16), Parent = kbRows })
	end
end

-- batch redraws so loading a config doesn't rebuild everything once per setting
local dirty, flushQueued = {}, false
local function flush()
	flushQueued = false
	if unloaded then
		return
	end
	local d = dirty
	dirty = {}
	if d.preview then
		refreshPreview()
	end
	if d.xh then
		refreshCrosshair()
	end
	if d.kb then
		refreshKeybindList()
	end
	if d.players then
		renderPlayers()
	end
	if d.cfg then
		renderConfigs()
	end
end
local function markDirty(what)
	dirty[what] = true
	if not flushQueued then
		flushQueued = true
		task.defer(flush)
	end
end
table.insert(anyWatchers, function(key)
	if key == "ui.accent" then
		markDirty("kb")
		markDirty("players")
		markDirty("cfg")
	end
	if key:sub(1, 3) == "esp" or key:sub(1, 5) == "chams" or key == "st.names" then
		markDirty("preview")
	end
	if key:sub(1, 2) == "xh" then
		markDirty("xh")
	end
	if key:find("#key", 1, true) or (CONTROLS[key] and CONTROLS[key].type == "toggle") then
		markDirty("kb")
	end
	if key == "pl.sort" then
		markDirty("players")
	end
end)

-- ===== actions =====

local function busy(btn, label, seconds, done)
	if btn:GetAttribute("busy") then
		return
	end
	local prev = btn.Text
	btn:SetAttribute("busy", true)
	btn.Text = label
	btn.TextColor3 = THEME.Dim
	task.delay(seconds, function()
		if unloaded then
			return
		end
		btn:SetAttribute("busy", nil)
		btn.Text = prev
		btn.TextColor3 = THEME.Text
		done()
	end)
end

local function jobId()
	return game.JobId ~= "" and game.JobId or "none (studio)"
end

local ACTIONS = {
    ["ut.reset"] = function() if runtime then runtime:Action("ut.reset") end end,
    ["ut.spawn"] = function() if runtime then runtime:Action("ut.spawn") end end,
    ["srv.rejoin"] = function() if runtime then runtime:Action("srv.rejoin") end end,
    ["srv.hop"] = function() if runtime then runtime:Action("srv.hop") end end,
    ["srv.small"] = function() if runtime then runtime:Action("srv.small") end end,
    ["runtime.copy"] = function() if runtime then runtime:Action("runtime.copy") end end,
    ["items.rescan"] = function() if runtime then runtime:Action("items.rescan") end end,
	["srv.job"] = function()
		log("job id: " .. jobId())
		notify("job id printed to output")
	end,
	["con.clear"] = function()
		table.clear(LOGS)
		if con.box then
			clearGui(con.box)
		end
	end,
	["con.dump"] = function()
		log("place id: " .. game.PlaceId)
		log("job id: " .. jobId())
		log(string.format("players: %d/%d", #Players:GetPlayers(), Players.MaxPlayers))
	end,
    ["cl.update"] = function() notify("Update checking is not configured for this standalone build.") end,
	["cl.unload"] = function(btn)
		if not btn:GetAttribute("armed") then
			arm(btn, "Confirm", "Unload")
			return
		end
		unload()
	end,
}
function runAction(id, btn)
	local fn = ACTIONS[id]
	if fn then
		fn(btn)
	end
end

-- ===== tabs & pages =====

local tabs, pages = {}, {}
local function selectTab(id)
	closePopup()
	hideTip()
	for tabId, page in pairs(pages) do
		page.Visible = tabId == id
	end
	for tabId, t in pairs(tabs) do
		t.active = tabId == id
		t.button.TextColor3 = t.active and THEME.Text or THEME.Dim
		t.line.Visible = t.active
	end
end

for i, tab in ipairs(TABS) do
	local b = button({
		Text = tab.label,
		BackgroundTransparency = 1,
		TextColor3 = THEME.Dim,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.new(0, 0, 1, 0),
		LayoutOrder = i,
		Parent = tabsBar,
	}, { pad(0, 6, 0, 6) })
	local line = new("Frame", { BorderSizePixel = 0, Position = UDim2.new(0, -3, 1, 0), Size = UDim2.new(1, 6, 0, 1), Visible = false, Parent = b })
	onAccent(function()
		line.BackgroundColor3 = accent()
	end)
	local entry = { button = b, line = line, active = false }
	tabs[tab.id] = entry
	b.MouseEnter:Connect(function()
		if not entry.active then
			b.TextColor3 = Color3.fromRGB(184, 184, 184)
		end
	end)
	b.MouseLeave:Connect(function()
		if not entry.active then
			b.TextColor3 = THEME.Dim
		end
	end)
	b.MouseButton1Click:Connect(function()
		selectTab(tab.id)
	end)

	local page = new("ScrollingFrame", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		VerticalScrollBarInset = Enum.ScrollBarInset.ScrollBar,
		ScrollBarThickness = 4,
		ScrollBarImageColor3 = Color3.fromRGB(60, 60, 60),
		Visible = false,
		Parent = body,
	}, { pad(7) })
	local columns = new("Frame", {
		BackgroundTransparency = 1,
		AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2.new(1, 0, 0, 0),
		Parent = page,
	}, { hlist(7, { VerticalAlignment = Enum.VerticalAlignment.Top }) })
	local count = #tab.cols
	for ci, col in ipairs(tab.cols) do
		local column = new("Frame", {
			BackgroundTransparency = 1,
			AutomaticSize = Enum.AutomaticSize.Y,
			Size = UDim2.new(1 / count, count > 1 and -4 or 0, 0, 0),
			LayoutOrder = ci,
			Parent = columns,
		}, { vlist(7) })
		for _, g in ipairs(col) do
			local group = new("Frame", {
				BackgroundColor3 = THEME.Child,
				BorderSizePixel = 0,
				AutomaticSize = Enum.AutomaticSize.Y,
				Size = UDim2.new(1, 0, 0, 0),
				LayoutOrder = nextOrder(),
				Parent = column,
			}, { corner(4), stroke(THEME.Border), pad(5, 8, 8, 8), vlist(0) })
			text({ Text = g.title, Size = UDim2.new(1, 0, 0, 18), LayoutOrder = nextOrder(), Parent = group })
			if g.custom then
				CUSTOM[g.custom](group)
			end
			for _, it in ipairs(g.items or {}) do
				buildItem(group, it)
			end
		end
	end
	page:GetPropertyChangedSignal("CanvasPosition"):Connect(closePopup)
	pages[tab.id] = page
end

-- ===== input =====

local KEY_NAMES = {
	LeftShift = "lshift", RightShift = "rshift", LeftControl = "lctrl", RightControl = "rctrl",
	LeftAlt = "lalt", RightAlt = "ralt", LeftSuper = "lwin", RightSuper = "rwin", CapsLock = "caps",
	Backquote = "`", Minus = "-", Equals = "=", LeftBracket = "[", RightBracket = "]", BackSlash = "\\",
	Semicolon = ";", Quote = "'", Comma = ",", Period = ".", Slash = "/", PageUp = "pgup", PageDown = "pgdn",
	Return = "enter", Escape = "esc", Space = "space", Tab = "tab",
	Zero = "0", One = "1", Two = "2", Three = "3", Four = "4", Five = "5", Six = "6", Seven = "7", Eight = "8", Nine = "9",
}
local function inputName(input)
	local t = input.UserInputType
	if t == Enum.UserInputType.Keyboard then
		if input.KeyCode == Enum.KeyCode.Unknown then
			return nil
		end
		local n = input.KeyCode.Name
		if KEY_NAMES[n] then
			return KEY_NAMES[n]
		end
		local keypad = n:match("^Keypad(.+)$")
		if keypad then
			return "num" .. string.lower(KEY_NAMES[keypad] or keypad)
		end
		return string.lower(n)
	elseif t == Enum.UserInputType.MouseButton2 then
		return "mouse2"
	elseif t == Enum.UserInputType.MouseButton3 then
		return "mouse3"
	end
	return nil
end

local function endCapture(value)
	local c = capturing
	if not c then
		return
	end
	capturing = nil
	c.button.TextColor3 = THEME.Dim
	if value ~= nil and not (c.key == "ui.key" and value == "none") then
		set(c.key, value)
	else
		c.button.Text = state[c.key]
	end
end

function startCapture(b, key)
	if justCancelled == b then
		justCancelled = nil
		return
	end
	justCancelled = nil
	endCapture()
	capturing = { button = b, key = key }
	b.Text = "..."
	b.TextColor3 = accent()
end

function toggleMenu(show)
	if show == nil then
		show = not window.Visible
	end
	window.Visible = show
	if not show then
		closePopup()
		hideTip()
		endCapture()
	end
end

local function panic()
	panicked = not panicked
	gui.Enabled = not panicked
    if runtime then runtime:Suspend(panicked) end
	if panicked then
		closePopup()
		hideTip()
		endCapture()
	end
end

function unload()
    if unloaded then return end
    if runtime then runtime:Destroy() end
    local environment = type(getgenv) == "function" and getgenv() or _G
    if environment.ApexSession and environment.ApexSession.Runtime == runtime then environment.ApexSession = nil end
	unloaded = true
	for _, c in ipairs(connections) do
		c:Disconnect()
	end
	gui:Destroy()
	print("[apex] unloaded")
end

connect(UserInputService.InputBegan, function(input, processed)
	if unloaded then
		return
	end
	local t = input.UserInputType
	local click = t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch
	if capturing then
		if t == Enum.UserInputType.Keyboard then
			if input.KeyCode == Enum.KeyCode.Escape then
				endCapture()
			elseif input.KeyCode == Enum.KeyCode.Backspace then
				endCapture("none")
			else
				local name = inputName(input)
				if name then
					endCapture(name)
				end
			end
		elseif click then
			justCancelled = capturing.button
			endCapture()
		elseif t == Enum.UserInputType.MouseButton2 or t == Enum.UserInputType.MouseButton3 then
			endCapture(inputName(input))
		end
		return
	end
	if click then
		justCancelled = nil
		if popup.Visible and not isOver(popup, input.Position) and not (popupOwner and isOver(popupOwner, input.Position)) then
			closePopup()
		end
	end
	if processed then
		return
	end
	local name = inputName(input)
	if not name then
		return
	end
	if name == state["st.panic"] then
		panic()
		return
	end
	if panicked then
		return
	end
	if name == state["ui.key"] then
		toggleMenu()
		return
	end
	for _, id in ipairs(TOGGLES) do
		if state[id .. "#key"] == name then
			set(id, not state[id])
			notify(CONTROLS[id].name .. (state[id] and " enabled" or " disabled"))
		end
	end
end)

connect(UserInputService.InputChanged, function(input)
	local t = input.UserInputType
	if t == Enum.UserInputType.MouseMovement or t == Enum.UserInputType.Touch then
		if dragFn then
			dragFn(input.Position)
		end
		if tip.Visible then
			tip.Position = UDim2.fromOffset(input.Position.X + 12, input.Position.Y + 16)
		end
	end
end)

connect(UserInputService.InputEnded, function(input)
	local t = input.UserInputType
	if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch then
		dragFn = nil
	end
end)

watch("ui.tips", function(v)
	if not v then
		hideTip()
	end
end)

local viewportConnection
local function bindViewport()
    if viewportConnection then viewportConnection:Disconnect() end
    local camera = workspace.CurrentCamera
    if camera then viewportConnection = connect(camera:GetPropertyChangedSignal("ViewportSize"), function()
        winScale.Scale = currentScale(); clampWindow()
    end) end
    winScale.Scale = currentScale(); clampWindow()
end
bindViewport()
connect(workspace:GetPropertyChangedSignal("CurrentCamera"), bindViewport)

connect(Players.PlayerAdded, function()
	markDirty("players")
end)
connect(Players.PlayerRemoving, function(p)
	if plState.selected == p then
		plState.selected = LocalPlayer
	end
	task.defer(markDirty, "players")
end)

-- touch screens have no Insert key, so give them a button
if UserInputService.TouchEnabled then
	local toggleButton = button({
		Text = "Λ",
		Font = FONT_BOLD,
		TextSize = 16,
		BackgroundColor3 = THEME.Win,
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 10, 0.5, 0),
		Size = UDim2.fromOffset(34, 34),
		ZIndex = 4,
		Parent = gui,
	}, { corner(4), stroke(THEME.Border2) })
	onAccent(function()
		toggleButton.TextColor3 = accent()
	end)
	toggleButton.MouseButton1Click:Connect(function()
		toggleMenu()
	end)
end

-- ===== live watermark =====

local frames = 0
connect(RunService.RenderStepped, function()
	frames += 1
end)
task.spawn(function()
	local ticks = 0
	while not unloaded do
		task.wait(0.5)
		if unloaded then
			break
		end
		ticks += 1
		local fps = frames * 2
		frames = 0
		local ping = 0
		pcall(function()
			ping = math.round(LocalPlayer:GetNetworkPing() * 1000)
		end)
		local sep = '<font color="#555555"> | </font>'
		wmText.Text = "apex" .. sep .. fps .. " fps" .. sep .. ping .. " ms" .. sep .. timestamp()
		if ticks % 4 == 0 then
			renderPlayerInfo()
		end
	end
end)


-- Configs are stored locally when executor file APIs are available.
local CONFIG_FILE = "Apex/aftermath-configs.json"
local function persistConfigs()
    local bundle = {version = 1, active = active, autoload = state["cl.autoload"], configs = {}}
    for _, name in ipairs(cfgOrder) do bundle.configs[#bundle.configs + 1] = {name = name, updated = configs[name].updated, data = encodeCfg(configs[name].data)} end
    local environment = type(getgenv) == "function" and getgenv() or _G
    environment.ApexConfigSession = bundle
    if type(writefile) == "function" and type(makefolder) == "function" then
        local ok, err = pcall(function()
            if type(isfolder) ~= "function" or not isfolder("Apex") then pcall(makefolder, "Apex") end
            writefile(CONFIG_FILE, HttpService:JSONEncode(bundle))
        end)
        if not ok then log("Config persistence unavailable: " .. tostring(err)) end
    end
end
local function restoreConfigs()
    local environment = type(getgenv) == "function" and getgenv() or _G
    local bundle = environment.ApexConfigSession
    if type(readfile) == "function" and (type(isfile) ~= "function" or isfile(CONFIG_FILE)) then
        local ok, value = pcall(function() return HttpService:JSONDecode(readfile(CONFIG_FILE)) end)
        if ok then bundle = value end
    end
    if type(bundle) ~= "table" or bundle.version ~= 1 or type(bundle.configs) ~= "table" then return end
    local restored, order = {}, {}
    for index, entry in ipairs(bundle.configs) do
        if index > 50 then break end
        if type(entry) == "table" and type(entry.name) == "string" and #entry.name > 0 and #entry.name <= 48 then
            local data = decodeCfg(entry.data)
            if data then restored[entry.name] = {data = data, updated = type(entry.updated) == "number" and entry.updated or os.time()}; order[#order + 1] = entry.name end
        end
    end
    if #order == 0 then return end
    configs, cfgOrder = restored, order
    active = configs[bundle.active] and bundle.active or cfgOrder[1]; cfgSel = active
    state["cl.autoload"] = bundle.autoload ~= false
    if state["cl.autoload"] then for key, value in pairs(configs[active].data) do set(key, value) end end
end
local originalCfgAction = cfgAction
cfgAction = function(id, btn) originalCfgAction(id, btn); persistConfigs() end
restoreConfigs()
runtime = createApexRuntime({state = state, set = set, log = log, notify = notify, player = LocalPlayer, playerGui = PlayerGui,
    playerState = plState, inputBlocked = function() return unloaded or panicked or window.Visible or capturing ~= nil end})
table.insert(anyWatchers, function(key, value) if runtime then runtime:Change(key, value) end end)
local environment = type(getgenv) == "function" and getgenv() or _G
environment.ApexSession = {Unload = unload, Runtime = runtime, Set = set, Get = function(key) return state[key] end}
runtime:Start()

-- ===== boot =====

selectTab("aiming")
winScale.Scale = currentScale()
centerWindow()
refreshPreview()
refreshCrosshair()
refreshKeybindList()
renderPlayers()
renderConfigs()
log("apex " .. VERSION .. " loaded")
log("Live runtime connected", "ok")
log("loaded config '" .. active .. "'")
notify("loaded, press " .. state["ui.key"] .. " to toggle the menu", "ok")
