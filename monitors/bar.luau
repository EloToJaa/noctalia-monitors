--!nonstrict
-- Monitors bar widget - a monitor icon that opens the panel.
--
-- The tooltip lists every output with its current mode. While a change waits
-- for confirmation the widget shows the remaining seconds, so the countdown is
-- visible even with the panel closed. Hidden outside an Umbriel session.

local model = require("./model.luau")

local snapshot: any = { available = false, outputs = {} }
local hasTooltip = false

local function tooltipRows()
  local rows = {}
  for _, out in ipairs(snapshot.outputs or {}) do
    local value = noctalia.tr("tooltip.off")
    if out.enabled and out.current ~= nil then
      value = `{out.current.w}x{out.current.h} @ {model.refreshLabel(out.current.mhz)}`
      if math.abs(out.scale - 1.0) > 0.0005 then
        value = value .. ` · {model.round(out.scale * 100)}%`
      end
    end
    table.insert(rows, { key = out.name, value = value })
  end
  return rows
end

local function render()
  if snapshot.available ~= true then
    if hasTooltip then
      barWidget.clearTooltip()
      hasTooltip = false
    end
    barWidget.setVisible(false)
    return
  end
  barWidget.setVisible(true)

  local rows = tooltipRows()
  if #rows > 0 then
    barWidget.setTooltip(rows)
    hasTooltip = true
  end

  local reverting = snapshot.revert ~= nil
  local glyph = ui.glyph({
    name = reverting and "clock" or "device-desktop",
    color = reverting and "primary" or nil,
  })

  -- A vertical bar has no room for labels, so it stays a single glyph.
  if barWidget.isVertical() then
    barWidget.render(ui.column({ align = "center" }, { glyph }))
    return
  end

  local children = { glyph }
  if reverting then
    table.insert(children, ui.label({ text = `{snapshot.revert.remaining}s`, color = "primary", fontWeight = "medium" }))
  elseif noctalia.getConfig("show_count") == true then
    table.insert(children, ui.label({ text = tostring(#(snapshot.outputs or {})), fontWeight = "medium" }))
  end
  barWidget.render(ui.row({ gap = 6, align = "center" }, children))
end

function update()
  render()
end

function onClick()
  noctalia.togglePanel("elotoja/monitors:panel")
end

noctalia.state.watch("monitors.state", function(value)
  if type(value) == "table" then
    snapshot = value
    render()
  end
end)

snapshot = noctalia.state.get("monitors.state") or snapshot
render()
