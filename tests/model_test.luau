--!nonstrict
-- Run with: luau tests/model_test.luau   (from the repo root; see `just test`)
local model = require("../monitors/model")

local failures = 0
local function check(name, cond)
  if not cond then
    failures += 1
    print("FAIL: " .. name)
  end
end
local function eq(name, a, b)
  check(`{name} (got {a}, want {b})`, a == b)
end

local function raw(name, w, h, x, y, extra)
  local out = {
    name = name,
    enabled = true,
    position = { x = x, y = y },
    scale = 1.0,
    transform = "normal",
    modes = {
      { width = w, height = h, refresh_mhz = 60000, preferred = true, current = true },
      { width = w, height = h, refresh_mhz = 59940, preferred = false, current = false },
      { width = 1280, height = 720, refresh_mhz = 60000, preferred = false, current = false },
    },
  }
  for k, v in pairs(extra or {}) do
    out[k] = v
  end
  return out
end

-- parsing + modes
local outs = model.normalizeAll({ raw("DP-2", 1920, 1080, 1920, 0), raw("DP-1", 1920, 1080, 0, 0) })
eq("sorted", outs[1].name, "DP-1")
eq("resolutions", #model.resolutions(outs[1]), 2)
eq("res order", model.resolutions(outs[1])[1].w, 1920)
eq("rates", #model.refreshRates(outs[1], 1920, 1080), 2)
eq("rate order", model.refreshRates(outs[1], 1920, 1080)[1].mhz, 60000)
eq("label 60", model.refreshLabel(60000), "60 Hz")
eq("label 59.94", model.refreshLabel(59940), "59.94 Hz")
eq("label 144", model.refreshLabel(144000), "144 Hz")
eq("closest", model.closestRefresh(outs[1], 1920, 1080, 59000), 59940)

-- geometry
local drafts = model.draftsFrom(outs)
eq("logical w", select(1, model.logicalSize(drafts["DP-1"])), 1920)
drafts["DP-1"].scale = 2.0
eq("scaled h", select(2, model.logicalSize(drafts["DP-1"])), 540)
drafts["DP-1"].transform = "90"
eq("rotated w", select(1, model.logicalSize(drafts["DP-1"])), 540)
eq("rotated h", select(2, model.logicalSize(drafts["DP-1"])), 960)
drafts["DP-1"].scale = 1.0
drafts["DP-1"].transform = "normal"

-- connectivity / snapping
check("connected", model.isConnected(drafts))
drafts["DP-2"].x = 5000
check("disconnected", not model.isConnected(drafts))
model.snapDisconnected(drafts)
check("snapped", model.isConnected(drafts))
eq("snapped x", drafts["DP-2"].x, 1920)

-- overlap
drafts["DP-2"].x = 100
eq("overlap count", #model.overlapping(drafts), 2)

-- placement
model.place(drafts, "DP-2", "DP-1", "right_of", "start")
eq("right x", drafts["DP-2"].x, 1920)
eq("right y", drafts["DP-2"].y, 0)
model.place(drafts, "DP-2", "DP-1", "below", "center")
eq("below y", drafts["DP-2"].y, 1080)
drafts["DP-2"].mhz = 59940
drafts["DP-2"].w, drafts["DP-2"].h = 1280, 720
model.place(drafts, "DP-2", "DP-1", "above", "end")
eq("above y", drafts["DP-2"].y, -720)
eq("above end x", drafts["DP-2"].x, 640)
local side, align = model.relation(drafts, "DP-2", "DP-1")
eq("relation side", side, "above")
eq("relation align", align, "end")

-- wlr-randr
local argv = model.randrArgs(drafts, { "DP-1", "DP-2" }, { ["DP-1"] = true })
eq("argv head", argv[1], "wlr-randr")
eq("argv mode", table.concat(argv, " "):find("--mode 1920x1080@60.000Hz", 1, true) ~= nil, true)
eq("argv vrr", table.concat(argv, " "):find("--adaptive-sync disabled", 1, true) ~= nil, true)
drafts["DP-2"].enabled = false
eq("argv off", table.concat(model.randrArgs(drafts, { "DP-2" }), " "), "wlr-randr --output DP-2 --off")

-- change detection
local base = model.draftsFrom(outs)
local edited = model.copyDrafts(base)
eq("no changes", #model.changedNames(base, edited), 0)
edited["DP-1"].scale = 1.5
eq("one change", #model.changedNames(base, edited), 1)

local cfg = model.umbrielConfig(model.draftsFrom(outs), outs)
check("config has section", cfg:find("[output.DP-1]", 1, true) ~= nil)
check("config mode", cfg:find("mode = \"1920x1080@60\"", 1, true) ~= nil)
check("config scale", cfg:find("scale = 1.0", 1, true) ~= nil or cfg:find("scale = 1\n", 1, true) ~= nil)
print(cfg)

if failures > 0 then
  print(`{failures} failure(s)`)
  error("tests failed")
end
print("model tests passed")
