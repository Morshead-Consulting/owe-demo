# OWE Saturation Demonstrator — parameter schema + logging harness

Skeleton for the CMO one-way-effector demonstrator: a parameter file that fully
defines a run, a Lua logging module that writes analysis-ready CSV from inside
the event engine, an event-wiring script that builds the trigger set, and a
Python stub that turns the parameter file into a per-run variation script.

```
params.example.json   the run definition (schema documented below)
owe_log.lua           logging module (CSV writer + magazine snapshots)
owe_wiring.lua        builds the events/triggers/actions that call the logger
gen_variation.py      params.json -> variation_<run_id>.lua  (stub)
```

Intended workflow per run:

1. Load `owe_baseline.scen` in Editor mode.
2. Console: `ScenEdit_RunScript('owe_log.lua')` then `ScenEdit_RunScript('owe_wiring.lua')`
   (development mode; for the shippable version embed both via a ScenLoaded
   event — your Day 10 pattern).
3. Console: `ScenEdit_RunScript('variation_R012.lua')` — applies this run's
   parameters and stamps `run_id` into the key-value store.
4. Save-as `owe_R012.scen`, run at time compression, let the end-condition
   event close it out.
5. Results accumulate in one `results.csv` across all runs; analyse in pandas.

## Parameter schema (params.example.json)

| Block | Field | Meaning |
|---|---|---|
| `run` | `run_id` | Unique per scenario file; stamped into every CSV row. |
| | `replicates` | How many times you'll manually run this .scen. CMO gives no RNG seed control, so replicates are genuinely stochastic — record actual replicate number at analysis time from run order, not from the params. |
| `raid` | `owe_dbid` | Resolve against *your* DB build in the database viewer. Placeholder in the example. |
| | `owe_kind` | `"unit"` or `"weapon"` — how your chosen DB entry is implemented. This changes the whole logging strategy (see gotcha 4). |
| | `launch_sites` | Names of pre-placed Red launch facilities in the baseline. |
| | `waves[]` | Each: `t_offset_min` from scenario start, `size`, `axis` (maps to a pre-built strike mission / reference-point lane in the baseline), `spacing_s` between launches, `altitude_m`, `speed_kts`. |
| `defence` | `emcon` | Side-level EMCON string for Blue, e.g. `"Radar=Active"` — a first-class experimental factor (radars-silent vs radiating changes the detection ladder). |
| | `gbad[]` | Per launcher unit: magazine name -> rounds. This is how interceptor-stock scarcity becomes a factor. |
| | `fdl_rps` | Reference points defining the final defence line polygon for the leaker trigger. |
| | `targets` | Blue target unit names (hit/kill logging + scoring). |
| `logging` | `out_dir` | Directory for `results.csv`. Forward slashes are fine on Windows. |
| | `snapshot_interval` | Cadence of magazine snapshots (see gotcha 6). |
| `end` | `t_end_min` | Hard stop; end-condition event calls `ScenEdit_EndScenario()` after a final snapshot + score row. |

A 3×3 study is then, e.g.: raid size {12, 24, 48} × interceptor stocks
{lean, doctrine, deep}, 3 replicates each = 27 manual runs. An evening or two.

## CSV output

One long-format file, one row per event — easiest shape for pandas:

```
run_id, sim_epoch, sim_time, event, side, unit, unit_class, lat, lon, detail
R012, 1795000000, 2026-11-18T06:14:03, owe_killed, Red, OWE-N-007, Shahed-136, 51.2, -1.8, killer=?
R012, ..., leaker, Red, OWE-E-011, ..., fdl=FDL
R012, ..., target_hit, Blue, TGT-Radar, ..., dmg=34.5
R012, ..., mag_snapshot, Blue, SHORAD-1, ..., CAMM=17/24
R012, ..., end, , , , , score_blue=120
```

Leakers, exchange ratios, engagement timelines, and expenditure curves all
fall out of group-bys on this.

## CMO-specific gotchas (the reasons this module exists)

1. **`io` is available but treat it defensively.** Open-append-close on every
   write; never hold a file handle in a Lua global — handles do not survive
   save/load and a stale handle fails silently. Every write is wrapped in
   `pcall` with a `ScenEdit_SpecialMessage` fallback so a logging failure is
   visible in-game rather than producing a quietly empty CSV.
2. **Lua globals do not survive save/load.** Anything that must persist
   (run_id, out path, wave counters) lives in the scenario key-value store
   (`ScenEdit_SetKeyValue`), not in Lua variables. `owe_log.lua` re-reads its
   config from the KV store on every call for exactly this reason.
3. **There is no weapon-fired trigger.** Interceptor expenditure must be
   *inferred* by diffing periodic magazine snapshots. That's what the
   `mag_snapshot` event is for. Coarse but honest — and it's precisely the
   measurement CPE's analytics layer would give you natively, which is your
   commercial talking point.
4. **Weapon-type vs unit-type OWEs is the big fork.** If your DB entry for the
   Shahed/proxy is a *weapon*, it is not a unit: it fires no `UnitDestroyed`
   or `UnitEntersArea` triggers, so intercepts and leakers can only be
   inferred from target damage + expenditure. If it is (or you proxy it as) a
   *unit* (UAV/aircraft entry, e.g. Harop), you get the full event stream —
   kills, leaker crossings, per-airframe timelines. **Strong reason to prefer
   a unit-type entry or proxy** even if a weapon-type Shahed exists in your DB.
5. **`ScenEdit_UnitX()` is only valid inside actions fired by unit triggers**
   (UnitDestroyed / UnitDamaged / UnitEntersArea). In time-triggered actions
   it returns nothing useful.
6. **`RegularTime` trigger intervals are an enum, not free seconds.** Check
   the values for your build at commandlua.github.io before trusting
   `interval` in `owe_wiring.lua`.
7. **API drift.** Field names in `SetTrigger`/`SetAction` tables have changed
   across builds. Everything here follows the documented idiom but verify
   against the doc version matching your installed build; expect to touch up
   one or two field names on first run. That touch-up list belongs in
   `lessons-learned.md`.
8. **Target attrition needs `UnitDamaged` as well as `UnitDestroyed`** —
   a 50 kg warhead frequently damages rather than kills a facility, and
   damage-only runs are analytically interesting (mission-kill vs K-kill).

## What deliberately isn't here yet

Wave *launch* mechanics in `gen_variation.py` are stubbed: for unit-type OWEs
the clean pattern is a time-triggered event per wave whose action spawns the
airframes in-flight at the launch site and assigns them to the pre-built
per-axis strike mission. For weapon-type OWEs you'd instead script launcher
salvoes (`ScenEdit_AttackContact` / bearing-only launch), which is fiddlier —
decide the fork (gotcha 4) before building this out.
