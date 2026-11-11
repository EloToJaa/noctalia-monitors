--!nonstrict
-- Monitors panel - edit one monitor at a time, then apply the whole layout.
--
-- Edits are kept as drafts (model.draftsFrom) and only reach the compositor when
-- the user presses Apply: the panel sends them to the service on the
-- "monitors.request" channel, and the answer arrives as a fresh
-- "monitors.state" snapshot. After an apply the service starts a countdown;
-- Keep or Revert is shown here until it ends.

local model = require("./model.luau")

local MAP_WIDTH = 480
local MAP_HEIGHT = 150
local DRAG_TYPE = "monitor"
local MAP_COLORS = {
  { fill = "secondary_container", text = "on_secondary_container" },
  { fill = "tertiary_container", text = "on_tertiary_container" },
  { fill = "surface_container_highest", text = "on_surface" },
}

local closeButton = true
local snapshot: any = { available = false, outputs = {}, randr = true }
local base = {} -- drafts describing the live layout
local drafts = {} -- drafts the user is editing
local selected = nil
local placement = {} -- connector -> { anchor, side, align }
local resyncNext = false
local copied = false

local function tr(key, subst)
  return noctalia.tr(key, subst)
end

local function request(payload)
  payload.stamp = noctalia.nowMs()
  noctalia.state.set("monitors.request", payload)
end

local function findOutput(name)
  for _, out in ipairs(snapshot.outputs or {}) do
    if out.name == name then
      return out
    end
  end
  return nil
end

local function hasChanges()
  return #model.changedNames(base, drafts) > 0
end

local function enabledCount()
  local count = 0
  for _, draft in pairs(drafts) do
    if draft.enabled then
      count += 1
    end
  end
  return count
end

-- ── State sync ───────────────────────────────────────────────────────────────

local function resetDrafts()
  drafts = model.copyDrafts(base)
  placement = {}
end

local function layoutChanged(oldBase, newBase)
  for name, draft in pairs(newBase) do
    if oldBase[name] == nil or not model.draftsEqual(oldBase[name], draft) then
      return true
    end
  end
  for name in pairs(oldBase) do
    if newBase[name] == nil then
      return true
    end
  end
  return false
end

local function sync(new)
  local previous = snapshot
  snapshot = new
  local oldBase = base
  base = model.draftsFrom(new.outputs or {})

  local hadEdits = #model.changedNames(oldBase, drafts) > 0
  local countdownStarted = previous.revert == nil and new.revert ~= nil
  local countdownEnded = previous.revert ~= nil and new.revert == nil

  if countdownStarted then
    resyncNext = true
  end

  if countdownEnded or not hadEdits or (resyncNext and layoutChanged(oldBase, base)) then
    resetDrafts()
    if resyncNext and layoutChanged(oldBase, base) then
      resyncNext = false
    end
  else
    for name, draft in pairs(base) do
      if drafts[name] == nil then
        drafts[name] = model.copyDraft(draft)
      end
    end
    for name in pairs(drafts) do
      if base[name] == nil then
        drafts[name] = nil
      end
    end
  end

  if selected == nil or drafts[selected] == nil then
    selected = nil
    for _, out in ipairs(new.outputs or {}) do
      if out.focused then
        selected = out.name
      end
    end
    if selected == nil and new.outputs ~= nil and new.outputs[1] ~= nil then
      selected = new.outputs[1].name
    end
  end
end

-- ── Editing ──────────────────────────────────────────────────────────────────

-- Outputs that sat flush against `name` before a size change keep their
-- relation to it afterwards instead of overlapping or leaving a gap.
local function relationsTo(name)
  local relations = {}
  for other, draft in pairs(drafts) do
    if other ~= name and draft.enabled then
      local side, align = model.relation(drafts, other, name)
      if side ~= nil then
        relations[other] = { side = side, align = align }
      end
    end
  end
  return relations
end

local function reflow(name, relations)
  for other, relation in pairs(relations) do
    model.place(drafts, other, name, relation.side, relation.align)
  end
end

local function editSelected(change)
  local draft = drafts[selected]
  if draft == nil then
    return
  end
  local relations = relationsTo(selected)
  change(draft)
  reflow(selected, relations)
  copied = false
end

local function getPlacement(name)
  local current = placement[name]
  if current ~= nil and drafts[current.anchor] ~= nil and drafts[current.anchor].enabled then
    return current
  end
  local firstOther = nil
  for _, out in ipairs(snapshot.outputs or {}) do
    if out.name ~= name and drafts[out.name] ~= nil and drafts[out.name].enabled then
      if firstOther == nil then
        firstOther = out.name
      end
      local side, align = model.relation(drafts, name, out.name)
      if side ~= nil then
        placement[name] = { anchor = out.name, side = side, align = align }
        return placement[name]
      end
    end
  end
  if firstOther == nil then
    return nil
  end
  placement[name] = { anchor = firstOther, side = "right_of", align = "start" }
  return placement[name]
end

local function applyPlacement(name)
  local p = placement[name]
  if p == nil then
    return
  end
  model.place(drafts, name, p.anchor, p.side, p.align)
  copied = false
end

-- ── UI pieces ────────────────────────────────────────────────────────────────

local function card(children, props)
  local config = { gap = 8, padding = 12, radius = 10, fill = "surface_container/0.35" }
  for key, value in pairs(props or {}) do
    config[key] = value
  end
  return ui.column(config, children)
end

local function field(labelKey, control)
  return ui.row({ gap = 8, align = "center" }, {
    ui.label({ text = tr(labelKey), width = 110, color = "on_surface_variant", fontSize = 12 }),
    control,
  })
end

local function indexOf(list, predicate)
  for i, item in ipairs(list) do
    if predicate(item) then
      return i - 1
    end
  end
  return 0
end

local function notice(glyph, text, color)
  return ui.row({ gap = 8, align = "center" }, {
    ui.glyph({ name = glyph, size = 16, color = color or "on_surface_variant" }),
    ui.label({ text = text, color = color or "on_surface_variant", fontSize = 11, wrap = true, flexGrow = 1 }),
  })
end

-- ── Layout map ───────────────────────────────────────────────────────────────
--
-- Every monitor is a block: its middle is the drag handle, and a thin strip along
-- each real edge is a drop zone. Dropping one monitor on another's edge places it
-- flush there (model.dropOn). The plugin UI has no absolute positioning, so the
-- map is drawn as vertical bands (model.bands) rather than free-floating boxes.

local function selectOutput(name)
  return function()
    selected = name
    render()
  end
end

-- `value` is "<anchor>:<side>"; the payload is the dragged connector.
function onMonitorDropped(payload, value)
  local anchor, side = string.match(value, "^(.*):([%a_]+)$")
  if anchor == nil or drafts[payload] == nil then
    return
  end
  if model.dropOn(drafts, payload, anchor, side) then
    selected = payload
    placement[payload] = nil -- re-derived from the new layout
    copied = false
  end
  render()
end

local function edgeZone(anchor, side, band, props)
  local zone = {
    key = `edge-{anchor}-{side}-{band}`,
    accepts = { DRAG_TYPE },
    value = `{anchor}:{side}`,
    onDrop = "onMonitorDropped",
    fill = "surface_container_low",
    hitSlop = 6,
  }
  for key, value in pairs(props) do
    zone[key] = value
  end
  return ui.dropZone(zone)
end

local function monitorBlock(item, band, width, height, color)
  local isSelected = item.name == selected
  local edge = math.max(4, math.min(12, math.floor(math.min(width, height) / 4)))
  local fill = isSelected and "primary" or color.fill
  local textColor = isSelected and "on_primary" or color.text

  local label = {}
  if item.left and width >= #item.name * 7 + 2 * edge + 8 then
    table.insert(label, ui.label({ text = item.name, fontSize = 11, color = textColor, fontWeight = "bold" }))
  end
  local middle = {}
  if item.left then
    table.insert(middle, edgeZone(item.name, "left_of", band, { width = edge }))
  end
  table.insert(middle, ui.dragSource({
    key = `drag-{item.name}-{band}`,
    dragType = DRAG_TYPE,
    payload = item.name,
    flexGrow = 1,
    align = "center",
    justify = "center",
    fill = fill,
    tooltip = item.name,
    onClick = selectOutput(item.name),
  }, label))
  if item.right then
    table.insert(middle, edgeZone(item.name, "right_of", band, { width = edge }))
  end

  local rows = {}
  if item.top then
    table.insert(rows, edgeZone(item.name, "above", band, { height = edge }))
  end
  table.insert(rows, ui.row({ gap = 0, flexGrow = 1 }, middle))
  if item.bottom then
    table.insert(rows, edgeZone(item.name, "below", band, { height = edge }))
  end
  return ui.column({ key = `block-{item.name}-{band}`, gap = 0, width = width, height = height }, rows)
end

local function layoutMap()
  local layout = model.bands(drafts)
  if layout == nil or layout.bounds.w <= 0 or layout.bounds.h <= 0 then
    return nil
  end
  local scale = math.min(MAP_WIDTH / layout.bounds.w, MAP_HEIGHT / layout.bounds.h)

  local colorOf = {}
  local count = 0
  for _, out in ipairs(snapshot.outputs or {}) do
    local draft = drafts[out.name]
    if draft ~= nil and draft.enabled then
      colorOf[out.name] = MAP_COLORS[(count % #MAP_COLORS) + 1]
      count += 1
    end
  end

  local bands = {}
  for index, band in ipairs(layout.bands) do
    local width = math.max(2, math.floor((band.x2 - band.x1) * scale + 0.5))
    local items = {}
    for _, item in ipairs(band.items) do
      local height = math.max(2, math.floor((item.y2 - item.y1) * scale + 0.5))
      if item.kind == "gap" then
        table.insert(items, ui.box({ height = height, fill = "surface/0" }))
      else
        table.insert(items, monitorBlock(item, index, width, height, colorOf[item.name]))
      end
    end
    table.insert(bands, ui.column({ gap = 0, width = width }, items))
  end

  return ui.column({ gap = 6, align = "center" }, {
    ui.row({ gap = 0, align = "start" }, bands),
    ui.label({ text = tr("map.hint"), color = "on_surface_variant", fontSize = 11 }),
  })
end

-- Names every monitor on its own screen for a few seconds (identify.luau).
-- Pressing it again while the overlay is up restarts its timer.
function identify()
  noctalia.state.set("monitors.identify", { stamp = noctalia.nowMs() })
  noctalia.layer.show("identify")
end

local function outputChips()
  local chips = {}
  for _, out in ipairs(snapshot.outputs or {}) do
    local draft = drafts[out.name]
    table.insert(chips, ui.button({
      text = out.name,
      glyph = (draft ~= nil and draft.enabled) and "device-desktop" or "device-desktop-off",
      selected = out.name == selected,
      onClick = selectOutput(out.name),
      tooltip = out.description,
    }))
  end
  table.insert(chips, ui.spacer({ flexGrow = 1 }))
  table.insert(chips, ui.button({
    text = tr("identify.button"),
    glyph = "eye",
    tooltip = tr("identify.tooltip"),
    onClick = identify,
  }))
  return ui.row({ gap = 6, align = "center" }, chips)
end

-- ── Editor ───────────────────────────────────────────────────────────────────

local function transformLabel(transform)
  return tr("transform." .. transform)
end

local function scaleLabel(scale)
  return string.format("%d%%", model.round(scale * 100))
end

local function scaleOptions(current)
  local list = {}
  local found = false
  for _, value in ipairs(model.SCALES) do
    table.insert(list, value)
    if math.abs(value - current) < 0.0005 then
      found = true
    end
  end
  if not found then
    table.insert(list, current)
    table.sort(list)
  end
  return list
end

local function positionControls(name, draft)
  local controls = {}
  local p = getPlacement(name)

  if p ~= nil then
    local anchors = {}
    for _, out in ipairs(snapshot.outputs or {}) do
      if out.name ~= name and drafts[out.name] ~= nil and drafts[out.name].enabled then
        table.insert(anchors, out.name)
      end
    end
    local sideLabels = {}
    for _, side in ipairs(model.SIDES) do
      table.insert(sideLabels, tr("side." .. side))
    end
    local alignLabels = {}
    for _, align in ipairs(model.ALIGNS) do
      table.insert(alignLabels, tr("align." .. align))
    end

    table.insert(controls, field("editor.place", ui.row({ gap = 6, flexGrow = 1 }, {
      ui.select({
        key = `side-{name}`,
        flexGrow = 1,
        options = sideLabels,
        selectedIndex = indexOf(model.SIDES, function(side)
          return side == p.side
        end),
        onChange = function(index)
          p.side = model.SIDES[(tonumber(index) or 0) + 1]
          applyPlacement(name)
          render()
        end,
      }),
      ui.select({
        key = `anchor-{name}`,
        flexGrow = 1,
        options = anchors,
        selectedIndex = indexOf(anchors, function(anchor)
          return anchor == p.anchor
        end),
        onChange = function(index)
          p.anchor = anchors[(tonumber(index) or 0) + 1] or p.anchor
          applyPlacement(name)
          render()
        end,
      }),
    })))
    table.insert(controls, field("editor.align", ui.select({
      key = `align-{name}`,
      flexGrow = 1,
      options = alignLabels,
      selectedIndex = indexOf(model.ALIGNS, function(align)
        return align == p.align
      end),
      onChange = function(index)
        p.align = model.ALIGNS[(tonumber(index) or 0) + 1]
        applyPlacement(name)
        render()
      end,
    })))
  end

  local function coordinate(axis)
    return ui.input({
      key = `{axis}-{name}-{draft[axis]}`,
      value = tostring(draft[axis]),
      flexGrow = 1,
      controlSize = "sm",
      onSubmit = function(text)
        local value = tonumber(text)
        if value == nil then
          render()
          return
        end
        editSelected(function(d)
          d[axis] = math.floor(value)
        end)
        placement[name] = nil
        render()
      end,
    })
  end
  table.insert(controls, field("editor.position", ui.row({ gap = 6, align = "center", flexGrow = 1 }, {
    ui.label({ text = "X", color = "on_surface_variant", fontSize = 11 }),
    coordinate("x"),
    ui.label({ text = "Y", color = "on_surface_variant", fontSize = 11 }),
    coordinate("y"),
  })))
  return controls
end

local function editor()
  local out = findOutput(selected)
  local draft = drafts[selected]
  if out == nil or draft == nil then
    return card({ ui.label({ text = tr("panel.no_monitor"), color = "on_surface_variant" }) })
  end

  local children = {}
  local title = out.description
  if out.make ~= "" or out.model ~= "" then
    title = string.format("%s %s", out.make, out.model)
  end
  table.insert(children, ui.row({ gap = 8, align = "center" }, {
    ui.column({ gap = 2, flexGrow = 1 }, {
      ui.label({ text = title, fontWeight = "bold", fontSize = 14 }),
      ui.label({ text = `{out.name} - {draft.w}x{draft.h}`, color = "on_surface_variant", fontSize = 11 }),
    }),
    ui.label({ text = tr("editor.enabled"), color = "on_surface_variant", fontSize = 12 }),
    ui.toggle({
      key = `enabled-{out.name}`,
      checked = draft.enabled,
      -- The last enabled output cannot be switched off, and a disabled output
      -- with no advertised mode has nothing to be switched on with.
      enabled = draft.enabled and enabledCount() > 1 or not draft.enabled and #out.modes > 0,
      onChange = function(value)
        editSelected(function(d)
          d.enabled = value == "true"
        end)
        placement[out.name] = nil
        render()
      end,
    }),
  }))

  if not draft.enabled then
    table.insert(children, notice("info-circle", tr("editor.disabled_hint")))
    return card(children)
  end

  -- Resolution
  local resolutions = model.resolutions(out)
  local resolutionLabels = {}
  for _, res in ipairs(resolutions) do
    local label = model.resolutionLabel(res.w, res.h)
    if res.preferred then
      label = label .. tr("editor.preferred")
    end
    table.insert(resolutionLabels, label)
  end
  table.insert(children, field("editor.resolution", ui.select({
    key = `res-{out.name}`,
    flexGrow = 1,
    options = resolutionLabels,
    selectedIndex = indexOf(resolutions, function(res)
      return res.w == draft.w and res.h == draft.h
    end),
    onChange = function(index)
      local res = resolutions[(tonumber(index) or 0) + 1]
      if res == nil then
        return
      end
      editSelected(function(d)
        d.w, d.h = res.w, res.h
        d.mhz = model.closestRefresh(out, res.w, res.h, d.mhz)
      end)
      render()
    end,
  })))

  -- Refresh rate
  local rates = model.refreshRates(out, draft.w, draft.h)
  local rateLabels = {}
  for _, rate in ipairs(rates) do
    table.insert(rateLabels, model.refreshLabel(rate.mhz))
  end
  table.insert(children, field("editor.refresh", ui.select({
    key = `rate-{out.name}-{draft.w}x{draft.h}`,
    flexGrow = 1,
    options = rateLabels,
    selectedIndex = indexOf(rates, function(rate)
      return rate.mhz == draft.mhz
    end),
    onChange = function(index)
      local rate = rates[(tonumber(index) or 0) + 1]
      if rate == nil then
        return
      end
      editSelected(function(d)
        d.mhz = rate.mhz
      end)
      render()
    end,
  })))

  -- Scale
  local scales = scaleOptions(draft.scale)
  local scaleLabels = {}
  for _, value in ipairs(scales) do
    table.insert(scaleLabels, scaleLabel(value))
  end
  table.insert(children, field("editor.scale", ui.select({
    key = `scale-{out.name}`,
    flexGrow = 1,
    options = scaleLabels,
    selectedIndex = indexOf(scales, function(value)
      return math.abs(value - draft.scale) < 0.0005
    end),
    onChange = function(index)
      local value = scales[(tonumber(index) or 0) + 1]
      if value == nil then
        return
      end
      editSelected(function(d)
        d.scale = value
      end)
      render()
    end,
  })))

  -- Rotation
  local transformLabels = {}
  for _, transform in ipairs(model.TRANSFORMS) do
    table.insert(transformLabels, transformLabel(transform))
  end
  table.insert(children, field("editor.rotation", ui.select({
    key = `transform-{out.name}`,
    flexGrow = 1,
    options = transformLabels,
    selectedIndex = indexOf(model.TRANSFORMS, function(transform)
      return transform == draft.transform
    end),
    onChange = function(index)
      local transform = model.TRANSFORMS[(tonumber(index) or 0) + 1]
      if transform == nil then
        return
      end
      editSelected(function(d)
        d.transform = transform
      end)
      render()
    end,
  })))

  -- Variable refresh rate
  if out.vrrSupported then
    table.insert(children, field("editor.vrr", ui.row({ gap = 8, align = "center", flexGrow = 1 }, {
      ui.toggle({
        key = `vrr-{out.name}`,
        checked = draft.vrr,
        onChange = function(value)
          editSelected(function(d)
            d.vrr = value == "true"
          end)
          render()
        end,
      }),
      ui.label({ text = tr("editor.vrr_hint"), color = "on_surface_variant", fontSize = 11, wrap = true, flexGrow = 1 }),
    })))
  end

  table.insert(children, ui.separator({}))
  for _, control in ipairs(positionControls(out.name, draft)) do
    table.insert(children, control)
  end

  return card(children)
end

-- ── Page ─────────────────────────────────────────────────────────────────────

local function revertBanner(revert)
  return card({
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = "clock", size = 20, color = "primary" }),
      ui.column({ gap = 2, flexGrow = 1 }, {
        ui.label({ text = tr("revert.title"), fontWeight = "bold", fontSize = 13 }),
        ui.label({
          text = tr("revert.body", { seconds = revert.remaining }),
          color = "on_surface_variant",
          fontSize = 11,
          wrap = true,
        }),
      }),
    }),
    ui.row({ gap = 6, justify = "end" }, {
      ui.button({
        text = tr("revert.keep"),
        glyph = "check",
        variant = "primary",
        width = 120,
        onClick = function()
          request({ op = "confirm" })
        end,
      }),
      ui.button({
        text = tr("revert.revert"),
        glyph = "arrow-back-up",
        variant = "destructive",
        width = 120,
        onClick = function()
          request({ op = "revert" })
        end,
      }),
    }),
  }, { fill = "primary_container/0.4" })
end

local function footer()
  local changed = hasChanges()
  return ui.row({ gap = 6 }, {
    ui.button({
      text = tr("footer.apply"),
      glyph = "check",
      variant = "primary",
      enabled = changed and snapshot.busy ~= true and snapshot.randr ~= false and enabledCount() > 0,
      flexGrow = 1,
      onClick = function()
        request({ op = "apply", drafts = drafts })
      end,
    }),
    ui.button({
      text = tr("footer.reset"),
      glyph = "restore",
      enabled = changed,
      onClick = function()
        resetDrafts()
        copied = false
        render()
      end,
    }),
    ui.button({
      text = copied and tr("footer.copied") or tr("footer.copy"),
      glyph = copied and "check" or "copy",
      tooltip = tr("footer.copy_tooltip"),
      onClick = function()
        copied = noctalia.copyToClipboard(model.umbrielConfig(drafts, snapshot.outputs or {}), "text/plain")
        render()
      end,
    }),
  })
end

-- Persist the live (confirmed) layout so it survives an Umbriel restart.
local function saveRow()
  local save = snapshot.save or {}
  local canSave = not hasChanges() and snapshot.revert == nil and snapshot.busy ~= true
  local rows = {
    ui.button({
      text = tr("footer.save"),
      glyph = "device-floppy",
      tooltip = tr("footer.save_tooltip"),
      enabled = canSave,
      onClick = function()
        request({ op = "save" })
      end,
    }),
  }
  local hint = nil
  if save.included ~= true then
    hint = notice("info-circle", tr("save.not_included", { path = save.path or "" }), "on_surface_variant")
  elseif save.exists == true then
    hint = notice("check", tr("save.auto", { path = save.path or "" }))
  end
  if hint ~= nil then
    table.insert(rows, ui.column({ flexGrow = 1 }, { hint }))
  end
  return ui.row({ gap = 8, align = "center" }, rows)
end

function render()
  local headerContent = {
    ui.glyph({ name = "device-desktop", size = 20, color = "primary" }),
    ui.label({ text = tr("panel.title"), fontWeight = "bold", fontSize = 16, flexGrow = 1 }),
  }
  if closeButton then
    table.insert(headerContent, ui.button({ glyph = "close", variant = "ghost", onClick = "onCloseClicked" }))
  end
  local header = ui.row({ align = "center", gap = 8 }, headerContent)

  if snapshot.available ~= true then
    panel.render(ui.column({ flexGrow = 1, gap = 8, padding = 10 }, {
      header,
      card({ notice("alert-triangle", snapshot.error or tr("panel.unavailable"), "error") }),
    }))
    return
  end

  local children = { header }
  if snapshot.revert ~= nil then
    table.insert(children, revertBanner(snapshot.revert))
  end

  local map = layoutMap()
  if map ~= nil then
    table.insert(children, card({ map }, { align = "center" }))
  end
  table.insert(children, outputChips())

  local body = { editor() }
  local overlapping = model.overlapping(drafts)
  if #overlapping > 0 then
    table.insert(body, notice("alert-triangle", tr("warning.overlap", { names = table.concat(overlapping, ", ") }), "error"))
  elseif not model.isConnected(drafts) then
    table.insert(body, notice("info-circle", tr("warning.disconnected")))
  end
  if snapshot.randr == false then
    table.insert(body, notice("alert-triangle", tr("error.no_randr"), "error"))
  end
  table.insert(children, ui.scroll({ flexGrow = 1, gap = 8 }, body))
  table.insert(children, footer())
  table.insert(children, saveRow())

  if type(snapshot.error) == "string" and snapshot.error ~= "" then
    table.insert(children, ui.label({ text = snapshot.error, color = "error", fontSize = 11, wrap = true }))
  end

  panel.render(ui.column({ flexGrow = 1, gap = 8, padding = 10 }, children))
end

function onCloseClicked()
  panel.close()
end

function onOpen(_context)
  closeButton = noctalia.getSetting("shell.show_close_buttons") ~= false
  copied = false
  local current = noctalia.state.get("monitors.state")
  if type(current) == "table" then
    sync(current)
  end
  -- Opening the panel also retries a disconnected stream immediately.
  request({ op = "refresh" })
  render()
end

noctalia.state.watch("monitors.state", function(value)
  if type(value) == "table" then
    sync(value)
    render()
  end
end)

-- Scriptable drop, the same path as dragging a monitor onto an edge:
--   noctalia msg plugin elotoja/monitors:panel all drop DP-2 HDMI-A-1:left_of
--   noctalia msg plugin elotoja/monitors:panel all identify
function onIpc(event, payload)
  if event == "identify" then
    identify()
    return
  end
  if event ~= "drop" or type(payload) ~= "string" then
    return
  end
  local name, value = string.match(payload, "^(%S+)%s+(%S+)$")
  if name ~= nil then
    onMonitorDropped(name, value)
  end
end
