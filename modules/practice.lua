-- Idle skill-up, class-agnostic.
--
-- WHY THIS IS NOT A `practice` LOOP. On this server there is no train-at-a-
-- guildmaster and no pool of practice sessions. `do_practice` is a listing
-- command whose fallback prints the actual design: "You increase your skill
-- by using." Ratings rise inside master_spell() when an action is *used*.
-- So practising means repeating a real command, and this repeats whichever
-- ones a profile lists.
--
-- THE RULE FOR RESOURCES. An action that spends a resource fires only when
-- that resource is FULL, and never in combat. Throughput is the same either
-- way -- spending down to a floor and waiting to refill, or taking one
-- action per refill, both settle at regen_rate / cost actions per second,
-- because regen is the only real limit. What differs is whether you are
-- left standing there depleted, and this way you never are: the mana that
-- pays for a real heal is always in the tank.
--
-- WHAT A PROFILE PROVIDES. One action per line in `practice_list`, with an
-- optional `| resource` suffix naming what must be full first:
--
--   variables:
--     practice_list: |
--       cast 'cure critic' saihtam | mana
--       hide
--
-- Known resources are `mana`, `move` and `hp`; omit the suffix for actions
-- that cost nothing, which then keep training while mana refills. An
-- unknown resource name never fires, so a typo goes quiet rather than
-- looping on a command that cannot work. Blank lines and `#` comments are
-- skipped. An empty list means the whole feature is off, which is the
-- default.

local TICK  = 5   -- seconds between checks
local QUIET = 4   -- consecutive quiet ticks before this counts as idle

local RESOURCES = {
  mana = { "MANA", "MANA_MAX" },
  move = { "MOVEMENT", "MOVEMENT_MAX" },
  hp   = { "HEALTH", "HEALTH_MAX" },
}

local quiet = 0        -- ticks since anything combat-shaped was seen
local slot = 0         -- rotation cursor, so every listed action gets a turn
local actions = nil    -- parsed lazily; nil means "not read yet"

-- The action sent on the current tick, so a refusal can be blamed on it.
-- Deliberately short-lived: cleared at the top of every beat, because the
-- server answers well inside one tick. Without that expiry a refusal aimed
-- at some *other* script's cast (duo.lua healing, say) could be credited
-- here and retire a perfectly good action.
local last = nil

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function parse()
  local list = {}
  for line in (mud.get("practice_list") or ""):gmatch("[^\n]+") do
    local command, resource = line:match("^(.-)|(.*)$")
    if not command then command = line end
    command = trim(command)
    resource = resource and trim(resource)
    if resource == "" then resource = nil end
    if command ~= "" and not command:match("^#") then
      list[#list + 1] = { command = command, resource = resource }
    end
  end
  return list
end

-- Unknown numbers read as "not full", so a session whose MSDP has not
-- arrived yet waits instead of spending something it cannot measure.
local function full(resource)
  if not resource then return true end
  local keys = RESOURCES[resource]
  if not keys then return false end
  local now = tonumber(mud.data(keys[1]))
  local max = tonumber(mud.data(keys[2]))
  if not now or not max or max <= 0 then return false end
  return now >= max
end

local beat   -- forward declaration: the heartbeat re-arms itself

beat = function()
  -- Re-armed first and unconditionally, so none of the early returns below
  -- can quietly end the loop.
  mud.timer(TICK, beat)
  last = nil

  -- Edge detector: the YAML triggers set this on anything combat-shaped,
  -- and reading it clears it. A variable that merely stays "1" could not
  -- tell "still fighting" from "fought a minute ago".
  local busy = mud.get("combat_seen") == "1"
  mud.set("combat_seen", "0")
  if busy then
    quiet = 0
    return
  end

  if quiet < QUIET then
    quiet = quiet + 1
    return
  end

  if mud.get("practice_on") ~= "1" then return end
  -- Resting and sleeping refuse every spell worth grinding, and retrying
  -- once per tick would be pure spam.
  if mud.get("upright") ~= "1" then return end

  actions = actions or parse()
  if #actions == 0 then return end

  -- First eligible action at or after the cursor, so a free action keeps
  -- training while a mana-gated one waits for the tank to refill.
  for offset = 0, #actions - 1 do
    local index = ((slot + offset) % #actions) + 1
    local action = actions[index]
    if not action.dead and full(action.resource) then
      slot = index
      last = index
      mud.send(action.command)
      return
    end
  end
end

mud.on_connect(function()
  quiet = 0
  slot = 0
  actions = nil
  mud.timer(TICK, beat)
end)

-- Called when the server refuses the command outright -- an unlearned
-- spell, a bad spell name, an unknown command. These are permanent for the
-- session, and crucially they cost no mana and no round (do_cast checks
-- HAS_SKILL before either), so without this the loop retries the same
-- doomed command every tick forever.
--
-- Retire it and let the rotation carry on with whatever does work.
-- `/reload` clears the retirements, which is also how a newly practised
-- spell gets back in.
function practice_failed()
  if not last or not actions then return end

  local action = actions[last]
  last = nil
  if action.dead then return end
  action.dead = true
  mud.echo("[practice] the server refuses '" .. action.command
    .. "' — dropping it for this session.")

  local alive = 0
  for _, candidate in ipairs(actions) do
    if not candidate.dead then alive = alive + 1 end
  end
  if alive == 0 then
    mud.echo("[practice] nothing left that works; idle until /reload.")
  end
end

-- `prt` — stop and start it without editing anything.
function practice_toggle()
  if mud.get("practice_on") == "1" then
    mud.set("practice_on", "0")
    mud.echo("[practice] off.")
  else
    mud.set("practice_on", "1")
    quiet = 0
    mud.echo("[practice] on — idle in " .. (QUIET * TICK) .. "s.")
  end
end

-- `prs` — what it thinks it is doing, and what it is waiting for.
function practice_status()
  actions = actions or parse()
  if #actions == 0 then
    mud.echo("[practice] nothing in practice_list, so nothing to do.")
    return
  end
  mud.echo("[practice] "
    .. (mud.get("practice_on") == "1" and "on" or "off")
    .. ", quiet " .. quiet .. "/" .. QUIET
    .. (mud.get("upright") == "1" and "" or ", not upright"))
  for _, action in ipairs(actions) do
    local note
    if action.dead then
      note = "dropped — server refused it"
    elseif not action.resource then
      note = "no resource"
    elseif not RESOURCES[action.resource] then
      note = "unknown resource '" .. action.resource .. "' — will never fire"
    elseif full(action.resource) then
      note = action.resource .. " full, ready"
    else
      note = "waiting for full " .. action.resource
    end
    mud.echo("  " .. action.command .. "   [" .. note .. "]")
  end
end
