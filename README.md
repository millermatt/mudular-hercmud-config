# Mudular config for HercMUD

My [Mudular](https://github.com/millermatt/mudular) setup for
[HercMUD](https://hercmud.net) — a warrior and a cleric played together, where
the warrior's pane drives both, plus an idle skill-trainer for the cleric.

Take any of it. Everything here is public domain (see [LICENSE](LICENSE)) —
copy a rule into your own profile without a second thought.

**These rules are HercMUD-specific.** They match its exact message strings,
down to the two spaces in `is dead!  R.I.P.` The *shapes* transfer to any MUD;
the patterns will not.

## What's here

| File | What it does |
|---|---|
| `profiles/mathias.yaml` | Warrior. Every key you press lives here — it drives the pair |
| `profiles/saihtam.yaml` | Cleric. Mostly reacts; follows the warrior around |
| `modules/duo.lua` | Picks which heal to cast, and learns which spells the cleric actually knows |
| `modules/hercmud-combat.yaml` | Shared combat rules: looting, splitting gold, re-targeting |
| `modules/hercmud-health.yaml` | Eat, drink, save |
| `modules/practice.yaml` + `practice.lua` | Trains skills while nothing else is happening |
| `mudular.yaml` | Client settings: a comms pane for tells and channels, two keybinds |

## Installing it

Copy the contents into your Mudular config directory:

- **Linux** — `~/.config/mudular/`
- **macOS** — `~/Library/Application Support/mudular/`
- **Windows** — `%APPDATA%\mudular\config\`

Then rename the profiles to your own characters, and change the character names
inside them — `mathias` and `saihtam` are written into the rules in both
directions. Search for both names and you will find every place that matters.

Passwords are not here and cannot be: Mudular refuses a `password:` field in a
profile and keeps them in your OS keyring instead (`mudular --set-password
<profile>`).

## How the duo works

The warrior's pane is the only one you need to watch.

| Type | Result |
|---|---|
| `t goblin` | Pick a target |
| `k` | Attack it — the cleric joins in on its own |
| `h` | Ask for a heal now |
| `f` | Both of you flee |
| `grp` | Re-form the group after a flee or a death |

Then it mostly runs itself: the cleric assists when a fight starts, heals when
the warrior drops below 60% health, re-throws a spell that fizzled, and says so
on the group channel when it runs out of mana. Corpses are looted and gold is
split automatically.

Two decisions worth knowing about, because they are not obvious:

**Fleeing is the server's job, not the client's.** Type `wimpy` once on each
character and HercMUD bails you out the instant damage drops you below a third
of your health — measured against your real maximum, with no client round-trip
and nothing to tune. The rules here only *react* to that, so the other
character comes along. An earlier version guessed at a hit-point threshold in
the client and fled at full health, which is how I learned this.

**Health thresholds are fractions, in Lua.** Mudular's `when:` guards compare
numbers but cannot divide, so a threshold written in YAML has to be an absolute
hit-point count — and that is wrong again the next time you level.
`duo.lua` does the arithmetic instead, so `HEAL_BELOW = 0.60` keeps meaning the
same thing forever.

## The cleric's spell list

`duo.lua` does not assume which heals the cleric knows. It tries the cheapest
spell that covers the damage, and when the server says *"You do not know that
spell!"* it strikes that one off and immediately throws the next one down. So it
tunes itself to your level over the first few fights, and picks up new spells
after a `/reload`.

This matters more than it sounds on HercMUD: `cast` checks the *learned*
percentage, not your level, so being high enough for a spell does not mean you
have it. A lookup table keyed on level would confidently pick spells you cannot
cast.

## Idle skill training

HercMUD has no train-at-a-guildmaster: `practice` only lists what you know, and
skills go up by *using* them. So `practice.lua` repeats things while nothing
else is happening.

The rule it follows: an action that costs a resource only fires when that
resource is **full**, and never in combat. Throughput is the same either way —
spending down to a floor and waiting to refill comes out at the same
actions-per-hour, because regeneration is the only real limit — so this way you
are never caught depleted, and the mana that pays for a real heal is always
there.

Turn it on and off with `prt`; `prs` shows what it is waiting for. It is
deliberately not bound to `pr`, because `pr` at this server abbreviates to
`practice`, which is the listing you actually want while training.

## What I left out

My comms history (private tells), a raw session capture, saved layout state,
map-debug output, and profile backups. Nothing here is generated state — it is
all things I wrote.
