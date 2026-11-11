--!nonstrict
-- Run with: luau tests/backend_test.luau   (from the repo root; see `just test`)
local model = require("../monitors/model")
local backend = require("../monitors/backend")

local failures = 0
local function eq(name, a, b)
  if a ~= b then
    failures += 1
    print(`FAIL: {name}\n  got:  {a}\n  want: {b}`)
  end
end

-- ── wlr-randr JSON ───────────────────────────────────────────────────────────

local randr = {
  {
    name = "DP-2",
    enabled = true,
    position = { x = 1920, y = 0 },
    scale = 1.5,
    transform = "90",
    adaptive_sync = true,
    modes = {
      { width = 2560, height = 1440, refresh = 143.912003, preferred = false, current = true },
      { width = 2560, height = 1440, refresh = 59.950001, preferred = true, current = false },
    },
  },
  { name = "DP-1", enabled = false, modes = {} },
}
local outs = model.normalizeAllRandr(randr)
eq("sorted by name", outs[1].name, "DP-1")
eq("disabled output", outs[1].enabled, false)
local dp2 = outs[2]
eq("refresh converted to mhz", dp2.current.mhz, 143912)
eq("position", dp2.x, 1920)
eq("transform", dp2.transform, "90")
eq("vrr supported", dp2.vrrSupported, true)
eq("preferred flag", dp2.modes[2].preferred, true)

local drafts = model.draftsFrom(outs)
drafts["DP-2"].vrr = true

-- ── Saved files ──────────────────────────────────────────────────────────────

eq(
  "hyprland lua",
  model.hyprlandLua(drafts, outs),
  'hl.monitor({ output = "DP-1", disabled = true })\n'
    .. 'hl.monitor({ output = "DP-2", mode = "2560x1440@143.91", position = "1920x0", scale = 1.5, transform = 1, vrr = 1 })\n'
)
eq(
  "hyprland conf",
  model.hyprlandConf(drafts, outs),
  "monitor = DP-1, disable\n" .. "monitor = DP-2, 2560x1440@143.91, 1920x0, 1.5, transform, 1, vrr, 1\n"
)
eq(
  "niri kdl",
  model.niriKdl(drafts, outs),
  'output "DP-1" {\n    off\n}\n\n'
    .. 'output "DP-2" {\n    mode "2560x1440@143.912"\n    scale 1.5\n    transform "90"\n    position x=1920 y=0\n    variable-refresh-rate\n}\n'
)

-- ── Detection and targets ────────────────────────────────────────────────────

eq("explicit setting wins", backend.detect("niri", { umbriel = true }), "niri")
eq("auto prefers umbriel", backend.detect("auto", { umbriel = true, hyprland = true }), "umbriel")
eq("auto hyprland", backend.detect("auto", { hyprland = true }), "hyprland")
eq("auto niri", backend.detect("auto", { niri = true }), "niri")
eq("auto fallback", backend.detect("auto", {}), "generic")
eq("only umbriel streams", backend.streams("niri"), false)

local function has(set)
  return function(path)
    return set[path] == true
  end
end
eq("hyprland defaults to lua", backend.target("hyprland", has({})).file, "monitors.lua")
eq("hyprland lua config", backend.target("hyprland", has({ ["hypr/hyprland.lua"] = true })).file, "monitors.lua")
eq("hyprland conf config", backend.target("hyprland", has({ ["hypr/hyprland.conf"] = true })).file, "monitors.conf")
eq("lua wins over conf", backend.target("hyprland", has({ ["hypr/hyprland.lua"] = true, ["hypr/hyprland.conf"] = true })).file, "monitors.lua")
eq("generic has no target", backend.target("generic", has({})), nil)

local function included(kind, existing, text)
  local target = backend.target(kind, has(existing))
  return string.find(text, target.pattern) ~= nil
end
eq("lua include found", included("hyprland", {}, 'pcall(require, "monitors")'), true)
eq("lua include missing", included("hyprland", {}, 'require("keybinds")'), false)
eq("niri include found", included("niri", {}, 'include optional=true "~/.config/niri/monitors.kdl"'), true)
eq("niri include missing", included("niri", {}, 'include "colors.kdl"'), false)
eq("umbriel include found", included("umbriel", {}, 'files = ["~/.config/umbriel/monitors.toml"]'), true)

local niriText = backend.fileText(backend.target("niri", has({})), drafts, outs)
eq("header comment", string.sub(niriText, 1, 3), "// ")
eq("header has include", string.find(niriText, '// include optional=true "~/.config/niri/monitors.kdl"', 1, true) ~= nil, true)
local luaText = backend.fileText(backend.target("hyprland", has({})), drafts, outs)
eq("lua header comment", string.sub(luaText, 1, 3), "-- ")
eq("renderer by file", backend.renderer("monitors.kdl"), model.niriKdl)

if failures > 0 then
  print(`{failures} failure(s)`)
  error("tests failed")
end
print("backend tests passed")
