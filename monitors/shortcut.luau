--!nonstrict
-- Monitors control-center shortcut - a tile that opens the panel.
--
-- Highlighted while a change waits for confirmation, so the pending state is
-- visible from the control center too. Disabled outside an Umbriel session.

local function render(snapshot)
  local available = type(snapshot) == "table" and snapshot.available == true
  local reverting = available and snapshot.revert ~= nil
  shortcut.setLabel(noctalia.tr("shortcut.label"))
  shortcut.setIcon("device-desktop")
  shortcut.setActive(reverting)
  shortcut.setEnabled(available)
end

function onClick()
  noctalia.togglePanel("elotoja/monitors:panel")
end

noctalia.state.watch("monitors.state", render)
render(noctalia.state.get("monitors.state"))
