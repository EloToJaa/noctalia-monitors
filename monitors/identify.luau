--!nonstrict
-- Identify layer - names every monitor on its own screen.
--
-- A layer is lazy: nothing exists until the panel calls
-- noctalia.layer.show("identify"). The host then creates one surface and one copy
-- of this script per output, so `layer.outputName()` is that copy's connector.
-- The surface is click-through and hides itself after a few seconds; pressing
-- Identify again while it is up restarts the timer through "monitors.identify".


local VISIBLE_MS = 4000

local shownAt = noctalia.nowMs()

local function modeText(name)
  for _, out in ipairs(noctalia.outputs()) do
    if out.name == name then
      return `{out.width}x{out.height}`
    end
  end
  return ""
end

local function render()
  local name = layer.outputName() or "?"
  local children = {
    ui.glyph({ name = "device-desktop", size = 56, color = "primary" }),
    ui.label({ text = name, fontSize = 72, fontWeight = "bold", color = "on_surface" }),
  }
  local mode = modeText(name)
  if mode ~= "" then
    table.insert(children, ui.label({ text = mode, fontSize = 22, color = "on_surface_variant" }))
  end
  layer.render(ui.column({
    gap = 8,
    align = "center",
    paddingH = 56,
    paddingV = 36,
    radius = 28,
    fill = "surface_container",
    border = "primary",
    borderWidth = 4,
  }, children))
end

function update()
  if noctalia.nowMs() - shownAt >= VISIBLE_MS then
    noctalia.layer.hide("identify")
  end
end

noctalia.state.watch("monitors.identify", function(_value)
  shownAt = noctalia.nowMs()
end)

noctalia.setUpdateInterval(250)
render()
