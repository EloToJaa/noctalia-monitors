--!nonstrict
-- Pure monitor-configuration logic: no noctalia.* calls, so it runs (and is
-- tested) under a plain `luau` binary. Shared by the service and the panel.
--
-- Terms:
--   output  one entry of `umbriel outputs --json`, normalised by M.normalize
--   draft   the user's pending configuration of one output (M.draftFrom)
--   mhz     refresh rate in millihertz, as Umbriel reports it

local M = {}

M.TRANSFORMS = { "normal", "90", "180", "270", "flipped", "flipped-90", "flipped-180", "flipped-270" }
M.SCALES = { 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0, 4.0 }
M.SIDES = { "right_of", "left_of", "above", "below" }
M.ALIGNS = { "start", "center", "end" }

local TOUCH_TOLERANCE = 1

function M.round(n)
  return math.floor(n + 0.5)
end

local function isRotated(transform)
  return transform == "90" or transform == "270" or transform == "flipped-90" or transform == "flipped-270"
end
M.isRotated = isRotated

-- ── Parsing ──────────────────────────────────────────────────────────────────

local function adaptiveSyncState(raw)
  if raw == nil then
    return nil -- the output cannot use variable refresh
  end
  if type(raw) == "boolean" then
    return raw
  end
  if type(raw) == "string" then
    return raw == "on" or raw == "enabled" or raw == "true" or raw == "active"
  end
  return nil
end

-- One `umbriel outputs` entry -> the fields the panel uses.
function M.normalize(raw)
  local modes = {}
  local current = nil
  for _, mode in ipairs(raw.modes or {}) do
    local entry = {
      w = mode.width,
      h = mode.height,
      mhz = mode.refresh_mhz,
      preferred = mode.preferred == true,
      current = mode.current == true,
    }
    table.insert(modes, entry)
    if entry.current then
      current = entry
    end
  end
  local position = raw.position or {}
  return {
    name = raw.name,
    description = raw.description or raw.name,
    make = raw.make or "",
    model = raw.model or "",
    enabled = raw.enabled == true,
    focused = raw.focused == true,
    x = position.x or 0,
    y = position.y or 0,
    scale = raw.scale or 1.0,
    transform = raw.transform or "normal",
    vrr = adaptiveSyncState(raw.adaptive_sync),
    vrrSupported = raw.adaptive_sync ~= nil,
    modes = modes,
    current = current,
  }
end

function M.normalizeAll(rawList)
  local outputs = {}
  if type(rawList) ~= "table" then
    return outputs
  end
  for _, raw in ipairs(rawList) do
    if type(raw) == "table" and type(raw.name) == "string" then
      table.insert(outputs, M.normalize(raw))
    end
  end
  table.sort(outputs, function(a, b)
    return a.name < b.name
  end)
  return outputs
end

-- ── Modes ────────────────────────────────────────────────────────────────────

-- "59.94 Hz", "60 Hz", "144 Hz"
function M.refreshLabel(mhz)
  local hz = mhz / 1000
  local text = string.format("%.2f", hz)
  text = string.gsub(text, "0+$", "")
  text = string.gsub(text, "%.$", "")
  return text .. " Hz"
end

function M.resolutionLabel(w, h)
  return `{w}x{h}`
end

-- Distinct resolutions of an output, biggest first.
function M.resolutions(out)
  local seen = {}
  local list = {}
  for _, mode in ipairs(out.modes) do
    local key = `{mode.w}x{mode.h}`
    if not seen[key] then
      seen[key] = true
      table.insert(list, { w = mode.w, h = mode.h, preferred = mode.preferred })
    elseif mode.preferred then
      for _, existing in ipairs(list) do
        if existing.w == mode.w and existing.h == mode.h then
          existing.preferred = true
        end
      end
    end
  end
  table.sort(list, function(a, b)
    if a.w ~= b.w then
      return a.w > b.w
    end
    return a.h > b.h
  end)
  return list
end

-- Refresh rates available at one resolution, fastest first.
function M.refreshRates(out, w, h)
  local list = {}
  for _, mode in ipairs(out.modes) do
    if mode.w == w and mode.h == h then
      table.insert(list, { mhz = mode.mhz, preferred = mode.preferred })
    end
  end
  table.sort(list, function(a, b)
    return a.mhz > b.mhz
  end)
  return list
end

-- The mode closest to a requested refresh at a resolution, used when the user
-- changes resolution and the old rate does not exist there.
function M.closestRefresh(out, w, h, wantMhz)
  local best = nil
  for _, rate in ipairs(M.refreshRates(out, w, h)) do
    if best == nil or math.abs(rate.mhz - wantMhz) < math.abs(best.mhz - wantMhz) then
      best = rate
    end
  end
  return best and best.mhz or wantMhz
end

-- ── Drafts ───────────────────────────────────────────────────────────────────

function M.draftFrom(out)
  local mode = out.current
  if mode == nil then
    -- A disabled output reports no current mode: start from its preferred one.
    for _, candidate in ipairs(out.modes) do
      if candidate.preferred then
        mode = candidate
        break
      end
    end
    mode = mode or out.modes[1]
  end
  return {
    enabled = out.enabled,
    w = mode and mode.w or 0,
    h = mode and mode.h or 0,
    mhz = mode and mode.mhz or 0,
    x = out.x,
    y = out.y,
    scale = out.scale,
    transform = out.transform,
    vrr = out.vrr == true,
  }
end

function M.draftsFrom(outputs)
  local drafts = {}
  for _, out in ipairs(outputs) do
    drafts[out.name] = M.draftFrom(out)
  end
  return drafts
end

function M.copyDraft(draft)
  local copy = {}
  for key, value in pairs(draft) do
    copy[key] = value
  end
  return copy
end

function M.copyDrafts(drafts)
  local copy = {}
  for name, draft in pairs(drafts) do
    copy[name] = M.copyDraft(draft)
  end
  return copy
end

local function sameFloat(a, b)
  return math.abs(a - b) < 0.0005
end

function M.draftsEqual(a, b)
  if a.enabled ~= b.enabled then
    return false
  end
  if not a.enabled then
    return true
  end
  return a.w == b.w
    and a.h == b.h
    and a.mhz == b.mhz
    and a.x == b.x
    and a.y == b.y
    and sameFloat(a.scale, b.scale)
    and a.transform == b.transform
    and a.vrr == b.vrr
end

-- Names whose draft differs from `base`.
function M.changedNames(base, drafts)
  local names = {}
  for name, draft in pairs(drafts) do
    local original = base[name]
    if original == nil or not M.draftsEqual(original, draft) then
      table.insert(names, name)
    end
  end
  table.sort(names)
  return names
end

-- ── Geometry ─────────────────────────────────────────────────────────────────

-- Logical size of a draft: the mode divided by scale, swapped when rotated.
function M.logicalSize(draft)
  if not draft.enabled then
    return 0, 0
  end
  local w, h = draft.w, draft.h
  if isRotated(draft.transform) then
    w, h = h, w
  end
  local scale = draft.scale > 0 and draft.scale or 1
  return math.floor(w / scale), math.floor(h / scale)
end

local function rect(drafts, name)
  local draft = drafts[name]
  local w, h = M.logicalSize(draft)
  return { x = draft.x, y = draft.y, w = w, h = h }
end

function M.touching(a, b)
  local overlapY = a.y < b.y + b.h and a.y + a.h > b.y
  local overlapX = a.x < b.x + b.w and a.x + a.w > b.x
  if math.abs(a.x + a.w - b.x) <= TOUCH_TOLERANCE and overlapY then
    return true
  end
  if math.abs(a.x - (b.x + b.w)) <= TOUCH_TOLERANCE and overlapY then
    return true
  end
  if math.abs(a.y + a.h - b.y) <= TOUCH_TOLERANCE and overlapX then
    return true
  end
  if math.abs(a.y - (b.y + b.h)) <= TOUCH_TOLERANCE and overlapX then
    return true
  end
  return false
end

function M.overlaps(a, b)
  return a.x < b.x + b.w and a.x + a.w > b.x and a.y < b.y + b.h and a.y + a.h > b.y
end

local function enabledNames(drafts)
  local names = {}
  for name, draft in pairs(drafts) do
    if draft.enabled then
      table.insert(names, name)
    end
  end
  table.sort(names)
  return names
end

-- Connected groups of enabled outputs (outputs that touch edge to edge).
local function components(drafts)
  local names = enabledNames(drafts)
  local groups = {}
  local visited = {}
  for _, start in ipairs(names) do
    if not visited[start] then
      local group = {}
      local queue = { start }
      visited[start] = true
      while #queue > 0 do
        local current = table.remove(queue, 1)
        table.insert(group, current)
        for _, other in ipairs(names) do
          if not visited[other] and (M.touching(rect(drafts, current), rect(drafts, other))) then
            visited[other] = true
            table.insert(queue, other)
          end
        end
      end
      table.insert(groups, group)
    end
  end
  return groups
end

-- Pointer travel needs touching outputs; true when every enabled output is
-- reachable from every other.
function M.isConnected(drafts)
  return #components(drafts) <= 1
end

-- Names of enabled outputs that overlap another enabled output.
function M.overlapping(drafts)
  local names = enabledNames(drafts)
  local result = {}
  local seen = {}
  for i = 1, #names do
    for j = i + 1, #names do
      if M.overlaps(rect(drafts, names[i]), rect(drafts, names[j])) then
        if not seen[names[i]] then
          seen[names[i]] = true
          table.insert(result, names[i])
        end
        if not seen[names[j]] then
          seen[names[j]] = true
          table.insert(result, names[j])
        end
      end
    end
  end
  return result
end

local function clampRange(desired, otherPos, otherSize, dragSize)
  return math.max(otherPos - dragSize + 1, math.min(desired, otherPos + otherSize - 1))
end

-- Pull detached groups to the nearest edge of the main group so the pointer can
-- cross between every output. Mutates `drafts`; the largest-first group stays
-- where it is.
function M.snapDisconnected(drafts)
  for _ = 1, 8 do
    local groups = components(drafts)
    if #groups <= 1 then
      return
    end
    local main = groups[1]
    local bestDist, bestGroup, bestDx, bestDy = math.huge, 2, 0, 0
    for index = 2, #groups do
      for _, targetName in ipairs(groups[index]) do
        local t = rect(drafts, targetName)
        for _, mainName in ipairs(main) do
          local m = rect(drafts, mainName)
          local candidates = {
            { m.x + m.w, clampRange(t.y, m.y, m.h, t.h) },
            { m.x - t.w, clampRange(t.y, m.y, m.h, t.h) },
            { clampRange(t.x, m.x, m.w, t.w), m.y + m.h },
            { clampRange(t.x, m.x, m.w, t.w), m.y - t.h },
          }
          for _, candidate in ipairs(candidates) do
            local dx, dy = candidate[1] - t.x, candidate[2] - t.y
            local dist = dx * dx + dy * dy
            if dist < bestDist then
              bestDist, bestGroup, bestDx, bestDy = dist, index, dx, dy
            end
          end
        end
      end
    end
    for _, name in ipairs(groups[bestGroup]) do
      drafts[name].x += bestDx
      drafts[name].y += bestDy
    end
  end
end

-- Move `name` flush against `anchor` on one side. `align` slides it along the
-- shared edge: "start" (top/left), "center", or "end" (bottom/right).
function M.place(drafts, name, anchor, side, align)
  local target = drafts[name]
  local base = drafts[anchor]
  if target == nil or base == nil or name == anchor then
    return
  end
  local tw, th = M.logicalSize(target)
  local bw, bh = M.logicalSize(base)

  local function along(baseStart, baseSize, targetSize)
    if align == "center" then
      return baseStart + math.floor((baseSize - targetSize) / 2)
    elseif align == "end" then
      return baseStart + baseSize - targetSize
    end
    return baseStart
  end

  if side == "right_of" then
    target.x = base.x + bw
    target.y = along(base.y, bh, th)
  elseif side == "left_of" then
    target.x = base.x - tw
    target.y = along(base.y, bh, th)
  elseif side == "below" then
    target.x = along(base.x, bw, tw)
    target.y = base.y + bh
  elseif side == "above" then
    target.x = along(base.x, bw, tw)
    target.y = base.y - th
  end
end

-- Which side/alignment of `anchor` a draft currently sits on, or nil when it is
-- not flush against it. Seeds the placement controls from the live layout.
function M.relation(drafts, name, anchor)
  local target = drafts[name]
  local base = drafts[anchor]
  if target == nil or base == nil or not target.enabled or not base.enabled then
    return nil
  end
  local t, b = rect(drafts, name), rect(drafts, anchor)
  local function alignOf(tStart, tSize, bStart, bSize)
    if tStart == bStart then
      return "start"
    elseif tStart + tSize == bStart + bSize then
      return "end"
    elseif tStart + math.floor(tSize / 2) == bStart + math.floor(bSize / 2) then
      return "center"
    end
    return "start"
  end
  if t.x == b.x + b.w and t.y < b.y + b.h and t.y + t.h > b.y then
    return "right_of", alignOf(t.y, t.h, b.y, b.h)
  elseif t.x + t.w == b.x and t.y < b.y + b.h and t.y + t.h > b.y then
    return "left_of", alignOf(t.y, t.h, b.y, b.h)
  elseif t.y == b.y + b.h and t.x < b.x + b.w and t.x + t.w > b.x then
    return "below", alignOf(t.x, t.w, b.x, b.w)
  elseif t.y + t.h == b.y and t.x < b.x + b.w and t.x + t.w > b.x then
    return "above", alignOf(t.x, t.w, b.x, b.w)
  end
  return nil
end

-- Bounding box of all enabled outputs, for scaling the layout preview.
function M.bounds(drafts)
  local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
  local any = false
  for _, name in ipairs(enabledNames(drafts)) do
    local r = rect(drafts, name)
    any = true
    minX = math.min(minX, r.x)
    minY = math.min(minY, r.y)
    maxX = math.max(maxX, r.x + r.w)
    maxY = math.max(maxY, r.y + r.h)
  end
  if not any then
    return { x = 0, y = 0, w = 0, h = 0 }
  end
  return { x = minX, y = minY, w = maxX - minX, h = maxY - minY }
end

M.rectOf = rect

-- ── wlr-randr ────────────────────────────────────────────────────────────────

-- Umbriel has no runtime IPC action for mode/position/scale; it implements
-- wlr-output-management, so `wlr-randr` is the supported way to change them.
-- One invocation is one atomic configuration for every output named in it.
-- `vrrSupported` is a set of output names that can use variable refresh; the
-- flag is only passed for those.
function M.randrArgs(drafts, names, vrrSupported)
  local argv = { "wlr-randr" }
  for _, name in ipairs(names) do
    local draft = drafts[name]
    table.insert(argv, "--output")
    table.insert(argv, name)
    if not draft.enabled then
      table.insert(argv, "--off")
    else
      table.insert(argv, "--on")
      table.insert(argv, "--mode")
      table.insert(argv, string.format("%dx%d@%.3fHz", draft.w, draft.h, draft.mhz / 1000))
      table.insert(argv, "--pos")
      table.insert(argv, string.format("%d,%d", draft.x, draft.y))
      table.insert(argv, "--scale")
      table.insert(argv, string.format("%.4f", draft.scale))
      table.insert(argv, "--transform")
      table.insert(argv, draft.transform)
      if vrrSupported ~= nil and vrrSupported[name] then
        table.insert(argv, "--adaptive-sync")
        table.insert(argv, draft.vrr and "enabled" or "disabled")
      end
    end
  end
  return argv
end

function M.vrrSet(outputs)
  local set = {}
  for _, out in ipairs(outputs) do
    if out.vrrSupported then
      set[out.name] = true
    end
  end
  return set
end

-- TOML float text: at least one decimal, no trailing zeros ("1.0", "1.25").
function M.floatText(n)
  local text = string.gsub(string.format("%.4f", n), "0+$", "")
  if string.sub(text, -1) == "." then
    text ..= "0"
  end
  return text
end

-- Umbriel `[output.*]` sections for a set of drafts. wlr-randr changes only
-- last until Umbriel restarts; pasting this into the Umbriel config makes the
-- layout permanent. Connector names are used, so settings belong to the port.
function M.umbrielConfig(drafts, outputs)
  local vrr = M.vrrSet(outputs)
  local names = {}
  for name in pairs(drafts) do
    table.insert(names, name)
  end
  table.sort(names)
  local blocks = {}
  for _, name in ipairs(names) do
    local draft = drafts[name]
    local lines = { `[output.{name}]` }
    if not draft.enabled then
      table.insert(lines, "enabled = false")
    else
      table.insert(lines, string.format('mode = "%dx%d@%s"', draft.w, draft.h, (string.gsub(string.format("%.3f", draft.mhz / 1000), "%.?0+$", ""))))
      table.insert(lines, string.format("position = [%d, %d]", draft.x, draft.y))
      table.insert(lines, "scale = " .. M.floatText(draft.scale))
      if draft.transform ~= "normal" then
        table.insert(lines, `transform = "{draft.transform}"`)
      end
      if vrr[name] then
        table.insert(lines, draft.vrr and 'vrr = "always"' or 'vrr = "disabled"')
      end
    end
    table.insert(blocks, table.concat(lines, "\n"))
  end
  return table.concat(blocks, "\n\n") .. "\n"
end

-- ── Drag and drop ────────────────────────────────────────────────────────────

-- Drop `name` against one edge of `anchor`. The dragged output keeps its offset
-- along the shared edge when it still overlaps the anchor there, otherwise it
-- lines up with the anchor's start. Outputs in the way are pushed along the
-- drop direction, and a gap left behind by the move is closed. Returns false
-- when nothing changed.
function M.dropOn(drafts, name, anchor, side)
  local target = drafts[name]
  local base = drafts[anchor]
  if name == anchor or target == nil or base == nil or not target.enabled or not base.enabled then
    return false
  end
  if table.find(M.SIDES, side) == nil then
    return false
  end

  local oldX, oldY = target.x, target.y
  M.place(drafts, name, anchor, side, "start")

  local tw, th = M.logicalSize(target)
  local bw, bh = M.logicalSize(base)
  if side == "right_of" or side == "left_of" then
    if oldY > base.y - th and oldY < base.y + bh then
      target.y = oldY
    end
  elseif oldX > base.x - tw and oldX < base.x + bw then
    target.x = oldX
  end

  -- Push whatever the move landed on, and whatever that lands on in turn.
  local queue = { name }
  local guard = 0
  while #queue > 0 and guard < 32 do
    guard += 1
    local mover = table.remove(queue, 1)
    local m = rect(drafts, mover)
    for _, other in ipairs(enabledNames(drafts)) do
      if other ~= mover and other ~= name and other ~= anchor and M.overlaps(m, rect(drafts, other)) then
        local o = drafts[other]
        local ow, oh = M.logicalSize(o)
        if side == "right_of" then
          o.x = m.x + m.w
        elseif side == "left_of" then
          o.x = m.x - ow
        elseif side == "below" then
          o.y = m.y + m.h
        else
          o.y = m.y - oh
        end
        table.insert(queue, other)
      end
    end
  end

  M.snapDisconnected(drafts)
  return true
end

-- The layout as vertical bands for the preview: the desktop is cut at every
-- output's left and right edge, and each band lists, top to bottom, the gaps and
-- the output slices in it. An output spanning several bands appears once per
-- band; `left`/`right`/`top`/`bottom` mark which slices own a real edge of it.
function M.bands(drafts)
  local names = enabledNames(drafts)
  if #names == 0 then
    return nil
  end
  local bounds = M.bounds(drafts)
  local seen, xs = {}, {}
  for _, name in ipairs(names) do
    local r = rect(drafts, name)
    for _, x in ipairs({ r.x, r.x + r.w }) do
      if not seen[x] then
        seen[x] = true
        table.insert(xs, x)
      end
    end
  end
  table.sort(xs)

  local bands = {}
  for i = 1, #xs - 1 do
    local x1, x2 = xs[i], xs[i + 1]
    local covering = {}
    for _, name in ipairs(names) do
      local r = rect(drafts, name)
      if r.x <= x1 and r.x + r.w >= x2 then
        table.insert(covering, { name = name, r = r })
      end
    end
    table.sort(covering, function(a, b)
      if a.r.y ~= b.r.y then
        return a.r.y < b.r.y
      end
      return a.name < b.name
    end)

    local items = {}
    local cursor = bounds.y
    for _, entry in ipairs(covering) do
      local y1 = math.max(cursor, entry.r.y)
      local y2 = entry.r.y + entry.r.h
      if y2 > y1 then
        if y1 > cursor then
          table.insert(items, { kind = "gap", y1 = cursor, y2 = y1 })
        end
        table.insert(items, {
          kind = "monitor",
          name = entry.name,
          y1 = y1,
          y2 = y2,
          left = entry.r.x == x1,
          right = entry.r.x + entry.r.w == x2,
          top = y1 == entry.r.y,
          bottom = y2 == entry.r.y + entry.r.h,
        })
        cursor = y2
      end
    end
    if cursor < bounds.y + bounds.h then
      table.insert(items, { kind = "gap", y1 = cursor, y2 = bounds.y + bounds.h })
    end
    table.insert(bands, { x1 = x1, x2 = x2, items = items })
  end
  return { bounds = bounds, bands = bands }
end

return M
