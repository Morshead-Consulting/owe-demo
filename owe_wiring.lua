-- owe_wiring.lua ------------------------------------------------------------
-- Builds the instrumentation trigger set for the OWE demonstrator.
-- Run ONCE against the baseline in Editor mode (after owe_log.lua is loaded),
-- then save the baseline. Idempotence is not attempted: if you re-run it,
-- delete the OWELOG_* events/triggers/actions first via the Event Editor.
--
-- Assumes (edit the CONFIG block to match your baseline):
--   * Red OWEs are UNIT-type (UAV/aircraft entries) -- see README gotcha 4.
--   * FDL reference points and target units already exist in the baseline.
--
-- Every ScenEdit_Set* table below follows the documented idiom but field
-- names drift between builds: expect to verify one or two against
-- commandlua.github.io for your installed version (README gotcha 7).
------------------------------------------------------------------------------

local CFG = {
  redSide   = 'Red',
  blueSide  = 'Blue',
  fdlRPs    = { 'FDL-1', 'FDL-2', 'FDL-3', 'FDL-4' },
  targets   = { 'TGT-Powerplant', 'TGT-Radar', 'TGT-HQ' },
  gbadUnits = { 'SHORAD-1', 'SHORAD-2', 'AAA-1' },
  -- RegularTime interval is an ENUM, not seconds -- check your build's docs.
  -- Commonly: 0=1s 1=5s 2=15s 3=30s 4=1min 5=5min 6=15min 7=30min 8=1hr
  snapshotIntervalEnum = 6,
  tEndMin  = 120,
}

-- Persist wiring config the actions will need after save/load (gotcha 2).
ScenEdit_SetKeyValue('owelog_gbad', table.concat(CFG.gbadUnits, ';'))
ScenEdit_SetKeyValue('owelog_blue', CFG.blueSide)

-- Small helper: create event + trigger + Lua action and join them ------------
local function makeEvent(name, triggerTbl, actionScript, repeatable)
  triggerTbl.mode = 'add'
  triggerTbl.name = 'TRG_' .. name
  ScenEdit_SetTrigger(triggerTbl)

  ScenEdit_SetAction({ mode = 'add', type = 'LuaScript',
                       name = 'ACT_' .. name, ScriptText = actionScript })

  ScenEdit_SetEvent('OWELOG_' .. name,
    { mode = 'add', IsRepeatable = (repeatable ~= false), IsShown = false })
  ScenEdit_SetEventTrigger('OWELOG_' .. name,
    { mode = 'add', name = 'TRG_' .. name })
  ScenEdit_SetEventAction('OWELOG_' .. name,
    { mode = 'add', name = 'ACT_' .. name })
end

------------------------------------------------------------------------------
-- 1. Red OWE destroyed  -> 'owe_killed'
--    TargetFilter TARGETTYPE: use 'Aircraft' for UAV-as-aircraft entries;
--    adjust if your chosen entry registers under a different type.
------------------------------------------------------------------------------
makeEvent('OWE_KILLED',
  { type = 'UnitDestroyed',
    TargetFilter = { TARGETSIDE = CFG.redSide, TARGETTYPE = 'Aircraft' } },
  [[ OweLog.unitEvent('owe_killed') ]])

------------------------------------------------------------------------------
-- 2. Leaker crossing the final defence line -> 'leaker'
------------------------------------------------------------------------------
makeEvent('LEAKER',
  { type = 'UnitEntersArea',
    area = CFG.fdlRPs,
    TargetFilter = { TARGETSIDE = CFG.redSide, TARGETTYPE = 'Aircraft' } },
  [[ OweLog.unitEvent('leaker', 'fdl=FDL') ]])

------------------------------------------------------------------------------
-- 3. Blue targets damaged / destroyed -> 'target_hit' / 'target_killed'
--    One trigger pair per named target (SPECIFICUNIT filter).
--    UnitDamaged needs a DamagePercent threshold field on most builds.
------------------------------------------------------------------------------
for _, tgt in ipairs(CFG.targets) do
  local tag = tgt:gsub('[^%w]', '')
  makeEvent('TGT_DMG_' .. tag,
    { type = 'UnitDamaged', DamagePercent = 1,
      TargetFilter = { TARGETSIDE = CFG.blueSide, SPECIFICUNIT = tgt } },
    [[ OweLog.unitEvent('target_hit') ]])
  makeEvent('TGT_KILL_' .. tag,
    { type = 'UnitDestroyed',
      TargetFilter = { TARGETSIDE = CFG.blueSide, SPECIFICUNIT = tgt } },
    [[ OweLog.unitEvent('target_killed') ]], false)
end

------------------------------------------------------------------------------
-- 4. Periodic magazine snapshot -> 'mag_snapshot' rows
--    (expenditure is diffed offline; no weapon-fired trigger exists)
------------------------------------------------------------------------------
makeEvent('SNAPSHOT',
  { type = 'RegularTime', interval = CFG.snapshotIntervalEnum },
  [[
    local side  = ScenEdit_GetKeyValue('owelog_blue')
    local names = {}
    for n in string.gmatch(ScenEdit_GetKeyValue('owelog_gbad'), '[^;]+') do
      names[#names + 1] = n
    end
    OweLog.snapshotMagazines(side, names)
  ]])

------------------------------------------------------------------------------
-- 5. End condition: hard stop at T+tEndMin -> final snapshot, score row, end.
--    'Time' triggers want an absolute epoch, so compute from current time at
--    wiring time. Re-wire (or adjust the event) if you change scenario start.
------------------------------------------------------------------------------
local endEpoch = ScenEdit_CurrentTime() + CFG.tEndMin * 60
makeEvent('ENDRUN',
  { type = 'Time', time = endEpoch },
  [[
    local side  = ScenEdit_GetKeyValue('owelog_blue')
    local names = {}
    for n in string.gmatch(ScenEdit_GetKeyValue('owelog_gbad'), '[^;]+') do
      names[#names + 1] = n
    end
    OweLog.endRun(side, names)
  ]], false)

ScenEdit_SpecialMessage(CFG.blueSide,
  'OWELOG wiring complete: kill/leaker/target/snapshot/end events created.')
