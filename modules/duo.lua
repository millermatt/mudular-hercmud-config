-- Healing decisions for the mathias/saihtam duo.
--
-- Two things YAML rules cannot do, which is the whole reason this file
-- exists:
--
--   * A `when:` guard compares numbers but cannot divide, so a YAML
--     threshold has to be absolute hit points and is wrong again the next
--     time somebody levels. Here it is a fraction of the maximum.
--
--   * Choosing a spell needs a table lookup and a running memory of what
--     the server has refused.
--
-- WHO DECIDES WHAT. mathias only ever says "I need a heal" — he sends the
-- bare token `ch` to saihtam and names no spell. Every spell choice happens
-- in saihtam's session, which is the only one that knows his mana and what
-- he has actually learned. (That is also why saihtam's profile sets
-- `cross_session: expand_aliases: true`: the injected `ch` has to expand
-- through his own alias to reach this file.)
--
-- The re-entry latches stay in YAML (`healing`, `self_healing`, `retrying`,
-- cleared by the duo-cooldowns timer). The VM has no `os`, so there is no
-- clock in here.

local HEAL_BELOW      = 0.60   -- mathias asks for a heal below 60% HP
local SELF_HEAL_BELOW = 0.55   -- saihtam looks after himself below 55%

-- The cleric's healing ladder, cheapest first. `cost` is the mana from the
-- server's own spello() table (spell_parser.c); `heals` is the average of
-- its dice from mag_points (magic.c); `level` is the class requirement from
-- class.c, recorded for the reader only.
--
-- `level` is necessary but not sufficient, and is used only in that
-- direction. On this server `cast` checks HAS_SKILL, the *learned*
-- percentage (utils.h), so being high enough level does not mean the spell
-- is castable — a cleric has to `practice` it first, and that half is
-- discovered below from the server's own refusals.
--
-- But the converse holds: a spell above this cleric's level cannot have
-- been practised, so skipping it can never skip something castable. It
-- saves the two or three refused casts a low-level cleric would otherwise
-- throw at the top of the ladder on the first heal of every session.
local LADDER = {
  { name = "cure light",   cost = 10, heals =  5, level =  1 },
  { name = "cure minor",   cost = 20, heals = 10, level =  5 },
  { name = "cure normal",  cost = 30, heals = 17, level =  9 },
  { name = "cure serious", cost = 35, heals = 51, level = 15 },
  { name = "cure critic",  cost = 50, heals = 89, level = 21 },
}

-- Spells the server has told us we do not know. Learned once per session and
-- re-learned after a `/reload`, which is also how a freshly practiced spell
-- gets another chance.
local unknown = {}

-- The cast we are waiting to hear about, so a refusal can be attributed to
-- the spell that caused it: { name = ..., target = ... }.
local pending = nil

-- A missing or zero maximum is "no idea", not "zero health": every caller
-- declines to act, matching how an unresolvable `when:` term fails safe.
local function health_of(data)
  local hp  = tonumber(data.HEALTH)
  local max = tonumber(data.HEALTH_MAX)
  if not hp or not max or max <= 0 then return nil end
  return hp / max, max - hp
end

local function own_health()
  return health_of({ HEALTH = mud.data("HEALTH"), HEALTH_MAX = mud.data("HEALTH_MAX") })
end

-- Unknown mana reads as plenty. The wrong guess in that direction costs one
-- wasted round and gets corrected by `no_energy` below; the other direction
-- would refuse to heal at all on a missing MSDP value.
local function own_mana()
  return tonumber(mud.data("MANA")) or math.huge
end

-- Unknown level lets everything through, for the same reason unknown mana
-- reads as plenty: a missing MSDP value must not be the thing that stops a
-- heal.
local function own_level()
  return tonumber(mud.data("LEVEL"))
end

local function pct(f)
  return string.format("%d%% HP", math.floor(f * 100 + 0.5))
end

-- The cheapest spell we know, can pay for, and that covers the deficit —
-- so a 40-point hole is not filled with 50 mana of cure critic. Falls back
-- to the largest affordable spell when nothing covers it, and to nil when
-- nothing is affordable at all.
local function pick(deficit, mana, ceiling)
  local fallback
  local level = own_level()
  for _, spell in ipairs(LADDER) do
    if not unknown[spell.name] and spell.cost <= mana
      and (not level or spell.level <= level)
      and (not ceiling or spell.cost < ceiling) then
      if spell.heals >= deficit then return spell end
      fallback = spell
    end
  end
  return fallback
end

local function cast(spell, target, why)
  pending = { name = spell.name, target = target }
  mud.send("cast '" .. spell.name .. "' " .. target)
  mud.echo("[duo] " .. spell.name .. " on " .. target .. " — " .. why)
end

-- Pick and throw the best heal at `target`, given how big the hole is.
-- Shared by every entry point so the choice is made in exactly one place.
-- What the server has refused so far, for a human to read.
local function struck()
  local names = {}
  for _, spell in ipairs(LADDER) do
    if unknown[spell.name] then names[#names + 1] = spell.name end
  end
  if #names == 0 then return "none" end
  return table.concat(names, ", ")
end

-- Why `pick` came back empty, in the words of whatever is actually wrong.
-- An emptied ladder and an empty mana pool are different problems with
-- different fixes, and reporting both as "no mana" is what let a struck-off
-- ladder hide behind a mana complaint for a whole fight.
local function why_nothing(mana)
  local cheapest
  for _, spell in ipairs(LADDER) do
    if not unknown[spell.name] and (not cheapest or spell.cost < cheapest) then
      cheapest = spell.cost
    end
  end
  if not cheapest then
    return "every spell is struck off (" .. struck() .. ") — `duo!` puts them back",
           "gn ladder empty, cannot heal"
  end
  return "cheapest heal left costs " .. cheapest .. " and I have " .. tostring(mana),
         "gn no mana"
end

local function heal(target, fraction, deficit)
  if not fraction then return end

  local mana = own_mana()
  local spell = pick(deficit, mana)
  if not spell then
    local why, tell = why_nothing(mana)
    mud.echo("[duo] no heal for " .. target .. ": " .. why)
    mud.send(tell)
    return false
  end

  cast(spell, target, pct(fraction) .. ", " .. deficit .. " down")
  return true
end

-- ---------------------------------------------------------------------
-- mathias' side: notice, and ask. No spell names live here.
-- ---------------------------------------------------------------------

function call_heal()
  local f = own_health()
  if not f or f >= HEAL_BELOW then return end

  local cleric = mud.session("saihtam")
  if not cleric then
    mud.echo("[duo] " .. pct(f) .. " and no cleric connected.")
    return
  end

  cleric:send("ch")
  mud.echo("[duo] " .. pct(f) .. " — asked saihtam for a heal.")
  mud.set("healing", "1")
end

-- ---------------------------------------------------------------------
-- saihtam's side: every spell choice.
-- ---------------------------------------------------------------------

-- `ch`, and whatever mathias injects when he needs help.
function heal_tank()
  local tank = mud.session("mathias")
  if not tank then
    mud.echo("[duo] mathias is not connected.")
    return
  end
  local f, deficit = health_of(tank.data)
  if not f then
    mud.echo("[duo] no vitals for mathias yet.")
    return
  end
  heal("mathias", f, deficit)
end

-- `cc`, and the trigger on being hit.
function heal_self()
  local f, deficit = own_health()
  if not f or f >= SELF_HEAL_BELOW then return end
  if heal("saihtam", f, deficit) then
    mud.set("self_healing", "1")
  end
end

-- "You do not know that spell!" — the one authoritative answer about what
-- this cleric can cast. Strike it off and immediately throw the next thing
-- down the ladder, so the round is not wasted. Bounded: each refusal
-- removes one spell for good, so this can happen at most once per rung.
function not_known()
  if not pending then return end

  unknown[pending.name] = true
  mud.echo("[duo] " .. pending.name .. " is not learned — dropping it from the ladder.")

  local target = pending.target
  local f, deficit
  if target == "saihtam" then
    f, deficit = own_health()
  else
    local tank = mud.session(target)
    if tank then f, deficit = health_of(tank.data) end
  end
  pending = nil
  if f then heal(target, f, deficit) end
end

-- "You haven't the energy to cast that spell!" — MSDP mana is up to a
-- second stale, so this is the server correcting us. Retry strictly cheaper,
-- which is what makes it terminate.
function no_energy()
  if not pending then
    mud.send("gn no mana")
    return
  end

  local ceiling = nil
  for _, spell in ipairs(LADDER) do
    if spell.name == pending.name then ceiling = spell.cost end
  end

  local target = pending.target
  local f, deficit
  if target == "saihtam" then
    f, deficit = own_health()
  else
    local tank = mud.session(target)
    if tank then f, deficit = health_of(tank.data) end
  end
  pending = nil

  local spell = f and pick(deficit, own_mana(), ceiling)
  if not spell then
    mud.echo("[duo] out of mana for anything useful.")
    mud.send("gn no mana")
    return
  end
  cast(spell, target, "cheaper: out of mana for the last one")
end

-- A lost concentration roll still cost half the mana and a full round.
-- Throw it again, but only while the target still wants it.
function retry_heal()
  local target = pending and pending.target or "mathias"
  local f, deficit
  if target == "saihtam" then
    f, deficit = own_health()
    if not f or f >= SELF_HEAL_BELOW then return end
  else
    local tank = mud.session(target)
    if not tank then return end
    f, deficit = health_of(tank.data)
    if not f or f >= HEAL_BELOW then return end
  end

  pending = nil
  if heal(target, f, deficit) then
    mud.set("retrying", "1")
  end
end

-- ---------------------------------------------------------------------
-- Naming a rung by hand, and seeing what the server has refused.
-- ---------------------------------------------------------------------

-- The by-hand overrides go through here rather than sending the cast
-- themselves. `not_known` strikes off whatever `pending` holds, and
-- `pending` is only ever set by `cast` — so a cast the script did not
-- record leaves the *last scripted* spell standing to take the blame for
-- a refusal it did not earn, and that spell is struck off for good.
local BY_HAND = { cl = "cure light", cs = "cure serious", cc = "cure critic" }

function cast_named(line, caps)
  local name = BY_HAND[caps[1]]
  for _, spell in ipairs(LADDER) do
    if spell.name == name then
      -- Say no here rather than spending a combat round finding out. The
      -- server would answer "You do not know that spell!", which costs the
      -- round the tank was waiting on and teaches nothing the class table
      -- already knows.
      local level = own_level()
      if level and spell.level > level then
        mud.echo("[duo] " .. spell.name .. " is level " .. spell.level
                 .. " and I am " .. level .. " — not casting it.")
        return
      end
      cast(spell, "mathias", "by hand")
      return
    end
  end
end

function show_ladder()
  mud.echo("[duo] struck off: " .. struck() .. " — `duo!` puts them back.")
end

-- Without this the only way back from a wrong strike-off is `/reload`,
-- which is not a thing anyone thinks of mid-fight.
function reset_ladder()
  unknown = {}
  mud.echo("[duo] ladder restored; the server gets to refuse them again.")
end
