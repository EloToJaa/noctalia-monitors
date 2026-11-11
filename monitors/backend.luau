--!nonstrict
-- Per-compositor details, kept free of noctalia.* calls so they can be tested.
--
-- Every compositor here implements wlr-output-management, so changes are always
-- applied with wlr-randr. What differs is how the current state is read (Umbriel
-- has an event stream, the others are polled through `wlr-randr --json`) and how
-- a layout is made permanent (a file the compositor config includes).

local model = require("./model.luau")

local M = {}

M.KINDS = { "umbriel", "hyprland", "niri", "generic" }

-- probe = { umbriel = bool, hyprland = bool, niri = bool }: which sessions are live.
-- `setting` is the user's choice: "auto" or one of M.KINDS.
function M.detect(setting, probe)
  if table.find(M.KINDS, setting) ~= nil then
    return setting
  end
  if probe.umbriel then
    return "umbriel"
  end
  if probe.hyprland then
    return "hyprland"
  end
  if probe.niri then
    return "niri"
  end
  return "generic"
end

-- Umbriel pushes changes; the rest are polled.
function M.streams(kind)
  return kind == "umbriel"
end

-- Where a layout is saved and how the compositor is told to load it.
--   dir      directory under the user's config dir
--   file     saved file name
--   main     candidate main config files, first existing one is checked for the include
--   pattern  Lua pattern that matches the include in the main config
--   include  the line(s) to add to the main config
--   comment  comment prefix of the saved file
--   render   (drafts, outputs) -> file body
-- `has(path)` reports whether a path exists, to choose between Hyprland's formats.
function M.target(kind, has)
  if kind == "umbriel" then
    return {
      dir = "umbriel",
      file = "monitors.toml",
      main = { "config.toml" },
      pattern = "monitors%.toml",
      include = '[include.optional]\nfiles = ["~/.config/umbriel/monitors.toml"]',
      comment = "#",
      render = model.umbrielConfig,
    }
  end
  if kind == "hyprland" then
    if not has("hypr/hyprland.lua") and has("hypr/hyprland.conf") then
      return {
        dir = "hypr",
        file = "monitors.conf",
        main = { "hyprland.conf" },
        pattern = "monitors%.conf",
        include = "source = ~/.config/hypr/monitors.conf",
        comment = "#",
        render = model.hyprlandConf,
      }
    end
    return {
      dir = "hypr",
      file = "monitors.lua",
      main = { "hyprland.lua" },
      pattern = "[\"']monitors[\"']",
      include = 'pcall(require, "monitors")',
      comment = "--",
      render = model.hyprlandLua,
    }
  end
  if kind == "niri" then
    return {
      dir = "niri",
      file = "monitors.kdl",
      main = { "config.kdl" },
      pattern = "monitors%.kdl",
      include = 'include optional=true "~/.config/niri/monitors.kdl"',
      comment = "//",
      render = model.niriKdl,
    }
  end
  return nil
end

-- The saved file's full text: a header saying who wrote it, then the layout.
function M.fileText(target, drafts, outputs)
  local c = target.comment
  return `{c} Written by the noctalia-monitors plugin. Load it from the main config with:\n`
    .. (string.gsub(c .. " " .. target.include, "\n", "\n" .. c .. " "))
    .. "\n\n"
    .. target.render(drafts, outputs)
end

function M.label(kind)
  if kind == "umbriel" then
    return "Umbriel"
  end
  if kind == "hyprland" then
    return "Hyprland"
  end
  if kind == "niri" then
    return "niri"
  end
  return "wlroots"
end


-- Renderer for a saved file name, for callers that only know what the service published.
function M.renderer(file)
  if file == "monitors.lua" then
    return model.hyprlandLua
  end
  if file == "monitors.conf" then
    return model.hyprlandConf
  end
  if file == "monitors.kdl" then
    return model.niriKdl
  end
  return model.umbrielConfig
end

return M
