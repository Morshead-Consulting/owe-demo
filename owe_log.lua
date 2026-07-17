-- owe_log.lua ---------------------------------------------------------------
-- CSV event logger for the OWE saturation demonstrator (consumer CMO).
--
-- Design rules (see README gotchas):
--   * All persistent config lives in the scenario key-value store, never in
--     Lua globals -- globals do not survive save/load.
--   * Every file write is open-append-close inside pcall, with a
--     ScenEdit_SpecialMessage fallback so failures are visible in-game.
--   * One long-format CSV, one row per event, shared across all runs.
--
-- Load in dev with:   ScenEdit_RunScript('owe_log.lua')
-- Ship by embedding this file's text in a ScenLoaded event action.
------------------------------------------------------------------------------

OweLog = OweLog or {}

local CSV_HEADER =
  "run_id,sim_epoch,sim_time,event,side,unit,unit_class,lat,lon,detail"

-- KV keys used ---------------------------------------------------------------
-- owelog_run_id   : e.g. "R012"
-- owelog_path     : full path to results.csv, e.g. "C:/owe-demo/results/results.csv"
-- owelog_side     : defending side name (for special-message fallback)

------------------------------------------------------------------------------
-- init: call once from the variation script (which knows run_id and out_dir).
------------------------------------------------------------------------------
function OweLog.init(runId, outDir, defSide)
  ScenEdit_SetKeyValue('owelog_run_id', runId)
  ScenEdit_SetKeyValue('owelog_path', outDir .. '/results.csv')
  ScenEdit_SetKeyValue('owelog_side', defSide or 'Blue')
  -- Write header only if the file doesn't already exist (shared across runs).
  local path = ScenEdit_GetKeyValue('owelog_path')
  local ok, f = pcall(io.open, path, 'r')
  if not ok or f == nil then
    OweLog._append(CSV_HEADER)
  else
    f:close()
  end
  OweLog.row('run_start', { detail = 'init' })
end

------------------------------------------------------------------------------
-- internal: defensive single-line append
------------------------------------------------------------------------------
function OweLog._append(line)
  local path = ScenEdit_GetKeyValue('owelog_path')
  if path == nil or path == '' then return end
  local ok, err = pcall(function()
    local f = assert(io.open(path, 'a'))
    f:write(line, '\n')
    f:close()
  end)
  if not ok then
    -- Make the failure loud in-game rather than silently losing data.
    local side = ScenEdit_GetKeyValue('owelog_side')
    pcall(ScenEdit_SpecialMessage, side,
      'OWELOG WRITE FAILED: ' .. tostring(err) .. ' :: ' .. line)
  end
end

------------------------------------------------------------------------------
-- internal: CSV-safe field (strip commas/quotes/newlines; nil -> '')
------------------------------------------------------------------------------
local function q(v)
  if v == nil then return '' end
  local s = tostring(v)
  s = s:gsub('[,\r\n"]', ';')
  return s
end

------------------------------------------------------------------------------
-- row: the core call. fields = { side=, unit=, unit_class=, lat=, lon=, detail= }
-- All optional; run_id and both time columns are added automatically.
------------------------------------------------------------------------------
function OweLog.row(event, fields)
  fields = fields or {}
  local t = ScenEdit_CurrentTime()  -- epoch seconds (UTC)
  local iso = os.date('!%Y-%m-%dT%H:%M:%S', t)
  local line = table.concat({
    q(ScenEdit_GetKeyValue('owelog_run_id')),
    q(t), q(iso), q(event),
    q(fields.side), q(fields.unit), q(fields.unit_class),
    q(fields.lat), q(fields.lon), q(fields.detail),
  }, ',')
  OweLog._append(line)
end

------------------------------------------------------------------------------
-- unitEvent: for actions fired by UNIT triggers only
-- (UnitDestroyed / UnitDamaged / UnitEntersArea). ScenEdit_UnitX() returns
-- the triggering unit's wrapper in that context and nothing useful elsewhere.
------------------------------------------------------------------------------
function OweLog.unitEvent(event, extraDetail)
  local ok, u = pcall(ScenEdit_UnitX)
  if not ok or u == nil then
    OweLog.row(event, { detail = 'ScenEdit_UnitX unavailable; ' ..
                                 tostring(extraDetail) })
    return
  end
  OweLog.row(event, {
    side       = u.side,
    unit       = u.name,
    unit_class = u.classname,
    lat        = u.latitude,
    lon        = u.longitude,
    detail     = extraDetail,
  })
end

------------------------------------------------------------------------------
-- snapshotMagazines: periodic expenditure capture (no weapon-fired trigger
-- exists, so stocks are diffed offline in pandas). Pass the defending side
-- name and a list of GBAD unit names (read them from KV so the wiring script
-- stays generic).
--
-- NB magazine/mount wrapper field names have drifted across builds; the
-- pcall-per-unit keeps one bad field name from killing the whole snapshot.
-- Verify .magazines / .mounts structure against your build's docs on first run.
------------------------------------------------------------------------------
function OweLog.snapshotMagazines(sideName, unitNames)
  for _, uname in ipairs(unitNames) do
    local ok, msg = pcall(function()
      local u = ScenEdit_GetUnit({ side = sideName, name = uname })
      if u == nil then return uname .. ':not-found' end
      local parts = {}
      if u.magazines then
        for _, mag in ipairs(u.magazines) do
          -- Typical shape: mag.mag_weapons is a list of weapon records with
          -- .wpn_name and .wpn_current -- CHECK against your build.
          if mag.mag_weapons then
            for _, w in ipairs(mag.mag_weapons) do
              parts[#parts + 1] = tostring(w.wpn_name) .. '=' ..
                                  tostring(w.wpn_current)
            end
          end
        end
      end
      if u.mounts then
        for _, m in ipairs(u.mounts) do
          if m.mount_weapons then
            for _, w in ipairs(m.mount_weapons) do
              parts[#parts + 1] = 'mnt:' .. tostring(w.wpn_name) .. '=' ..
                                  tostring(w.wpn_current)
            end
          end
        end
      end
      OweLog.row('mag_snapshot', {
        side = sideName, unit = uname,
        detail = table.concat(parts, '|'),
      })
      return nil
    end)
    if not ok then
      OweLog.row('mag_snapshot_error',
        { side = sideName, unit = uname, detail = tostring(msg) })
    end
  end
end

------------------------------------------------------------------------------
-- endRun: final snapshot hook + score row, then end the scenario.
------------------------------------------------------------------------------
function OweLog.endRun(sideName, gbadUnitNames)
  if gbadUnitNames then OweLog.snapshotMagazines(sideName, gbadUnitNames) end
  local okS, score = pcall(ScenEdit_GetScore, sideName)
  OweLog.row('end', { side = sideName,
                      detail = 'score=' .. tostring(okS and score or 'n/a') })
  pcall(ScenEdit_EndScenario)
end
