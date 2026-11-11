--!nonstrict
-- Monitors service - the only entry that talks to the compositor and wlr-randr.
--
-- Umbriel pushes its output list over the IPC event stream. `umbriel subscribe
-- outputs` is that stream on stdout, one JSON object per line, so the service
-- holds it open and republishes the normalised list as a snapshot the panel
-- reads. Umbriel has no runtime action for mode/position/scale, so changes go
-- through `wlr-randr` (wlr-output-management), followed by a confirm-or-revert
-- countdown that restores the previous layout when nobody confirms.
--
--   noctalia.state.set("monitors.state", snapshot)     one snapshot, one re-render
--   noctalia.state.watch("monitors.request", handler)  requests from the panel
--
-- Requests (tables with an `op`):
--   { op = "apply", drafts = { [connector] = draft } }   apply, start countdown
--   { op = "confirm" }                                   keep the new layout
--   { op = "revert" }                                    restore the old layout
--   { op = "save" }                                      write the live layout to the compositor's include file
--   { op = "refresh" }                                   retry a dropped stream

local model = require("./model.luau")
local backend = require("./backend.luau")

local RECONNECT_INTERVAL_MS = 1000
local REVERT_SECONDS = 15
local RANDR_TIMEOUT_MS = 15000
-- runStream has no exit callback. Report termination on stdout so the next
-- retry can reconnect, including when the child starts but cannot connect.
local STREAM_COMMAND = [[umbriel subscribe outputs; printf '\n{"event":"monitors-disconnected"}\n']]

local available = false
local streaming = false
local outputs = {}
local streamError = nil
local busy = false
-- { previous = drafts, names = { connector }, deadlineMs = number } while the
-- user has an unconfirmed change; `previous` is the last confirmed layout.
local pending = nil

-- A shell started by systemd can inherit WAYLAND_DISPLAY without UMBRIEL_SOCKET.
-- Follow the CLI's fallback, scoped to this display rather than another session.
local function socketPath()
  local explicit = noctalia.getenv("UMBRIEL_SOCKET")
  if explicit ~= nil and explicit ~= "" then
    return explicit
  end
  local runtimeDir = noctalia.getenv("XDG_RUNTIME_DIR")
  local display = noctalia.getenv("WAYLAND_DISPLAY")
  if runtimeDir ~= nil and runtimeDir ~= "" and display ~= nil and display ~= "" then
    return `{runtimeDir}/umbriel-{display}.sock`
  end
  return nil
end

local function revertState()
  if pending == nil then
    return nil
  end
  local remaining = math.ceil((pending.deadlineMs - noctalia.nowMs()) / 1000)
  return { remaining = math.max(remaining, 0), total = REVERT_SECONDS, names = pending.names }
end

-- ── Compositor and saved layout ──────────────────────────────────────────────

local kind = "generic"
local target = nil -- backend.target(kind): where the layout is saved

local function configHome()
  local xdg = noctalia.getenv("XDG_CONFIG_HOME")
  if xdg ~= nil and xdg ~= "" then
    return xdg
  end
  return "~/.config"
end

local function envSet(name)
  local value = noctalia.getenv(name)
  return value ~= nil and value ~= ""
end

local saveInfo = { supported = false, exists = false, included = false, error = nil }

local function refreshSaveInfo()
  if target == nil then
    saveInfo = { supported = false, exists = false, included = false, error = nil }
    return
  end
  local dir = `{configHome()}/{target.dir}`
  saveInfo.supported = true
  saveInfo.path = `{dir}/{target.file}`
  saveInfo.file = target.file
  saveInfo.include = target.include
  saveInfo.exists = noctalia.fileExists(saveInfo.path)
  saveInfo.included = false
  for _, candidate in ipairs(target.main) do
    local main = noctalia.readFile(`{dir}/{candidate}`)
    if main ~= nil and string.find(main, target.pattern) ~= nil then
      saveInfo.included = true
    end
  end
end

local function resolveKind()
  local path = socketPath()
  local probe = {
    umbriel = path ~= nil and noctalia.fileExists(path) and noctalia.commandExists("umbriel"),
    hyprland = envSet("HYPRLAND_INSTANCE_SIGNATURE"),
    niri = envSet("NIRI_SOCKET"),
  }
  local setting = noctalia.getConfig("compositor")
  kind = backend.detect(type(setting) == "string" and setting or "auto", probe)
  target = backend.target(kind, function(relative)
    return noctalia.fileExists(`{configHome()}/{relative}`)
  end)
  saveInfo.error = nil
  refreshSaveInfo()
end

local function publish()
  noctalia.state.set("monitors.state", {
    available = available,
    outputs = outputs,
    error = streamError,
    busy = busy,
    randr = noctalia.commandExists("wlr-randr"),
    revert = revertState(),
    save = saveInfo,
    compositor = kind,
    compositorLabel = backend.label(kind),
  })
end

-- Write the live layout, which is the confirmed one, so it survives a restart.
-- Never called while a change waits for confirmation.
local function save()
  if target == nil or pending ~= nil or #outputs == 0 then
    return
  end
  local drafts = model.draftsFrom(outputs)
  local ok, err = noctalia.mkdirAll(`{configHome()}/{target.dir}`)
  if ok then
    local tmp = saveInfo.path .. ".tmp"
    ok, err = noctalia.writeFile(tmp, backend.fileText(target, drafts, outputs))
    if ok then
      ok, err = noctalia.renameFile(tmp, saveInfo.path)
    end
  end
  if not ok then
    saveInfo.error = err or "write failed"
    noctalia.notifyError(noctalia.tr("notify.save_failed"), saveInfo.error)
  else
    saveInfo.error = nil
    noctalia.notify(noctalia.tr("notify.saved_title"), noctalia.tr("notify.saved_body", { path = saveInfo.path }))
  end
  refreshSaveInfo()
  publish()
end

-- Keeping a change updates the file when the user has opted in by saving once.
local function confirm()
  pending = nil
  refreshSaveInfo()
  if saveInfo.exists then
    save()
    return
  end
  publish()
end

local function onLine(line)
  local decoded = noctalia.json.decode(line)
  if type(decoded) ~= "table" then
    return
  end
  if decoded.event == "monitors-disconnected" then
    streaming = false
    available = false
    outputs = {}
    streamError = noctalia.tr("error.stream_closed")
    publish()
    return
  end
  -- The stream reports its own rejection on the first line and then closes;
  -- every other line is one subscribed state snapshot.
  if type(decoded.err) == "string" then
    streamError = decoded.err
    publish()
    return
  end
  if decoded.event == "outputs" and type(decoded.data) == "table" then
    outputs = model.normalizeAll(decoded.data)
    available = true
    streamError = nil
    publish()
  end
end

local function startStream()
  if streaming then
    return
  end
  local path = socketPath()
  if path == nil or not noctalia.fileExists(path) or not noctalia.commandExists("umbriel") then
    return
  end
  streaming = noctalia.runStream(STREAM_COMMAND, onLine)
  if not streaming then
    streamError = noctalia.tr("error.stream_failed")
    publish()
  end
end

-- Compositors without an event stream are polled through wlr-randr. A snapshot
-- identical to the last one is dropped so the panel does not re-render.
local POLL_INTERVAL_MS = 2000
local polling = false
local lastPollMs = -POLL_INTERVAL_MS
local lastSnapshot = ""

local function poll()
  if polling then
    return
  end
  lastPollMs = noctalia.nowMs()
  if not noctalia.commandExists("wlr-randr") then
    if streamError == nil then
      available = false
      outputs = {}
      streamError = noctalia.tr("error.no_randr")
      publish()
    end
    return
  end
  polling = true
  local started = noctalia.runAsync({ "wlr-randr", "--json" }, function(result)
    polling = false
    if result.exitCode ~= 0 then
      available = false
      outputs = {}
      lastSnapshot = ""
      streamError = noctalia.string.trim(result.stderr or "")
      if streamError == "" then
        streamError = noctalia.tr("error.randr_start")
      end
      publish()
      return
    end
    local decoded = noctalia.json.decode(result.stdout or "")
    if type(decoded) ~= "table" then
      return
    end
    local list = model.normalizeAllRandr(decoded)
    local encoded = noctalia.json.encode(list) or ""
    if available and streamError == nil and encoded == lastSnapshot then
      return
    end
    lastSnapshot = encoded
    outputs = list
    available = true
    streamError = nil
    publish()
  end, 5000)
  if not started then
    polling = false
  end
end

-- Pick the compositor while nothing is connected, then keep its source fed.
local function refreshSource()
  if not available then
    local before = kind
    resolveKind()
    if before ~= kind then
      publish()
    end
  end
  if backend.streams(kind) then
    startStream()
    return
  end
  if noctalia.nowMs() - lastPollMs >= POLL_INTERVAL_MS then
    poll()
  end
end

-- Run one wlr-randr invocation. done(ok, errText) fires once it exits.
local function runRandr(argv, done)
  busy = true
  publish()
  local started = noctalia.runAsync(argv, function(result)
    lastPollMs = -POLL_INTERVAL_MS -- re-read the layout on the next tick
    busy = false
    if result.exitCode ~= 0 or result.timedOut then
      local text = noctalia.string.trim(result.stderr or "")
      if result.timedOut then
        text = noctalia.tr("error.timed_out")
      end
      done(false, text)
    else
      done(true, nil)
    end
    publish()
  end, RANDR_TIMEOUT_MS)
  if not started then
    busy = false
    done(false, noctalia.tr("error.randr_start"))
    publish()
  end
end

local function revert(automatic)
  if pending == nil then
    return
  end
  local previous = pending
  pending = nil
  publish()
  local argv = model.randrArgs(previous.previous, previous.names, model.vrrSet(outputs))
  runRandr(argv, function(ok, err)
    if not ok then
      noctalia.notifyError(noctalia.tr("notify.revert_failed"), err)
      return
    end
    if automatic then
      noctalia.notify(noctalia.tr("notify.reverted_title"), noctalia.tr("notify.reverted_body"))
    end
  end)
end

local function knownOutputs()
  local set = {}
  for _, out in ipairs(outputs) do
    set[out.name] = true
  end
  return set
end

-- Drafts cross the state channel as plain tables; refuse anything malformed
-- before it reaches a command line.
local function validDraft(draft)
  if type(draft) ~= "table" or type(draft.enabled) ~= "boolean" then
    return false
  end
  if not draft.enabled then
    return true
  end
  for _, key in ipairs({ "w", "h", "mhz", "x", "y", "scale" }) do
    if type(draft[key]) ~= "number" then
      return false
    end
  end
  if draft.w <= 0 or draft.h <= 0 or draft.mhz <= 0 or draft.scale < 0.25 or draft.scale > 4 then
    return false
  end
  return table.find(model.TRANSFORMS, draft.transform) ~= nil
end

local function apply(request)
  if busy then
    return
  end
  if not noctalia.commandExists("wlr-randr") then
    noctalia.notifyError(noctalia.tr("notify.apply_failed"), noctalia.tr("error.no_randr"))
    return
  end
  if type(request.drafts) ~= "table" then
    return
  end
  local drafts = model.copyDrafts(request.drafts)
  local known = knownOutputs()
  local names = {}
  local anyEnabled = false
  for name, draft in pairs(drafts) do
    if not known[name] or not validDraft(draft) then
      drafts[name] = nil
    else
      table.insert(names, name)
      anyEnabled = anyEnabled or draft.enabled
    end
  end
  table.sort(names)
  if #names == 0 then
    return
  end
  if not anyEnabled then
    noctalia.notifyError(noctalia.tr("notify.apply_failed"), noctalia.tr("error.all_disabled"))
    return
  end

  -- Outputs that do not touch cannot be crossed with the pointer.
  model.snapDisconnected(drafts)

  -- A second apply before confirming keeps the original layout as the revert
  -- target, so Revert always returns to the last confirmed state.
  local previous = pending ~= nil and pending.previous or model.draftsFrom(outputs)
  local previousNames = pending ~= nil and pending.names or names
  local merged = {}
  for _, name in ipairs(previousNames) do
    merged[name] = true
  end
  for _, name in ipairs(names) do
    merged[name] = true
  end
  local revertNames = {}
  for name in pairs(merged) do
    if previous[name] ~= nil then
      table.insert(revertNames, name)
    end
  end
  table.sort(revertNames)

  runRandr(model.randrArgs(drafts, names, model.vrrSet(outputs)), function(ok, err)
    if not ok then
      noctalia.notifyError(noctalia.tr("notify.apply_failed"), err)
      return
    end
    pending = {
      previous = previous,
      names = revertNames,
      deadlineMs = noctalia.nowMs() + REVERT_SECONDS * 1000,
    }
  end)
end

noctalia.state.watch("monitors.request", function(value)
  if type(value) ~= "table" or type(value.op) ~= "string" then
    return
  end
  refreshSource()
  if value.op == "apply" then
    apply(value)
  elseif value.op == "confirm" then
    confirm()
  elseif value.op == "save" then
    save()
  elseif value.op == "revert" then
    revert(false)
  elseif value.op == "refresh" then
    refreshSaveInfo()
    publish()
  end
end)

-- Scriptable entry point, also used for testing without the panel:
--   noctalia msg plugin elotoja/monitors:service all apply '{"DP-1":{"enabled":true,...}}'
--   noctalia msg plugin elotoja/monitors:service all confirm
--   noctalia msg plugin elotoja/monitors:service all revert
function onIpc(event, payload)
  if event == "apply" then
    local decoded = noctalia.json.decode(payload or "")
    if type(decoded) == "table" then
      apply({ drafts = decoded })
    end
  elseif event == "confirm" then
    confirm()
  elseif event == "save" then
    save()
  elseif event == "revert" then
    revert(false)
  end
end

function update()
  refreshSource()
  if pending == nil then
    return
  end
  if noctalia.nowMs() >= pending.deadlineMs then
    revert(true)
    return
  end
  publish() -- drives the countdown in the panel
end

noctalia.setUpdateInterval(RECONNECT_INTERVAL_MS)
resolveKind()
publish()
refreshSource()

function onConfigChanged()
  resolveKind()
  publish()
end
