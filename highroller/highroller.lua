local function log(t)
  reaper.ShowConsoleMsg(t .. '\n')
end
local function logtable(table, indent)
  log(tostring(table))
  for index, value in pairs(table) do -- print table
    log('    ' .. tostring(index) .. ' : ' .. tostring(value))
  end
end

local function GetPianoRollTake()
  local editor = reaper.MIDIEditor_GetActive()
  if not editor then return nil end
  local take = reaper.MIDIEditor_GetTake(editor)
  if not take or not reaper.TakeIsMIDI(take) then return nil end
  return take
end

function FlipHorizontal()
  local take = GetPianoRollTake()
  if not take then return end

  local _, noteCount = reaper.MIDI_CountEvts(take)

  local minStart, maxEnd = math.huge, -math.huge
  local notes = {}

  -- gather selected notes and bounds
  for i = 0, noteCount-1 do
    local ok, sel, muted, startppq, endppq =
      reaper.MIDI_GetNote(take, i)

    if sel then
      table.insert(notes, {i, startppq, endppq})
      if startppq < minStart then minStart = startppq end
      if endppq   > maxEnd   then maxEnd   = endppq end
    end
  end

  if #notes == 0 then return end

  local span = maxEnd - minStart

  reaper.MIDI_DisableSort(take)

  for _, n in ipairs(notes) do
    local idx, startppq, endppq = table.unpack(n)
    local len = endppq - startppq

    local newStart = minStart + (span - (endppq - minStart))
    local newEnd   = newStart + len

    reaper.MIDI_SetNote(take, idx, nil, nil, newStart, newEnd, nil, nil, nil, true)
  end

  reaper.MIDI_Sort(take)
end

function FlipVertical()
  local take = GetPianoRollTake()
  if not take then return end

  local _, noteCount = reaper.MIDI_CountEvts(take)

  local minPitch, maxPitch = 127, 0
  local notes = {}

  -- gather selected notes + pitch bounds
  for i = 0, noteCount-1 do
    local ok, sel, muted, startppq, endppq, chan, pitch =
      reaper.MIDI_GetNote(take, i)

    if sel then
      table.insert(notes, {i, pitch})
      if pitch < minPitch then minPitch = pitch end
      if pitch > maxPitch then maxPitch = pitch end
    end
  end

  if #notes == 0 then return end

  reaper.MIDI_DisableSort(take)

  for _, n in ipairs(notes) do
    local idx, pitch = table.unpack(n)
    local newPitch = maxPitch - (pitch - minPitch)

    reaper.MIDI_SetNote(take, idx, nil, nil, nil, nil, nil, newPitch, nil, true)
  end

  reaper.MIDI_Sort(take)
end

function Split()
  local take = GetPianoRollTake()
  if not take then return end

  local _, noteCount = reaper.MIDI_CountEvts(take)

  -- group selected notes by pitch/channel
  local groups = {}

  for i = 0, noteCount-1 do
    local ok, sel, muted, startppq, endppq, chan, pitch, vel =
      reaper.MIDI_GetNote(take, i)

    if sel then
      local key = pitch.."_"..chan
      groups[key] = groups[key] or {}
      table.insert(groups[key], {
        idx=i,
        start=startppq,
        finish=endppq,
        pitch=pitch,
        chan=chan,
        vel=vel,
        muted=muted
      })
    end
  end

  reaper.MIDI_DisableSort(take)

  -- collect all notes to delete first
  local notesToDelete = {}

  for _, notes in pairs(groups) do
    table.sort(notes, function(a,b) return a.start < b.start end)

    -- detect runs (touching notes) separately per pitch/channel
    local runs = {}
    local run = {notes[1]}
    for i = 2, #notes do
      local prev = run[#run]
      local cur  = notes[i]
      if cur.start <= prev.finish then
        table.insert(run, cur)
      else
        table.insert(runs, run)
        run = {cur}
      end
    end
    table.insert(runs, run)

    -- mark notes for deletion
    for _, r in ipairs(runs) do
      for _, n in ipairs(r) do
        table.insert(notesToDelete, n.idx)
      end
    end
  end

  -- delete all notes in reverse order of indices
  table.sort(notesToDelete, function(a,b) return a > b end)
  for _, idx in ipairs(notesToDelete) do
    reaper.MIDI_DeleteNote(take, idx)
  end

  -- now rebuild the runs with +1 subdivision
  for _, notes in pairs(groups) do
    table.sort(notes, function(a,b) return a.start < b.start end)

    local runs = {}
    local run = {notes[1]}
    for i = 2, #notes do
      local prev = run[#run]
      local cur  = notes[i]
      if cur.start <= prev.finish then
        table.insert(run, cur)
      else
        table.insert(runs, run)
        run = {cur}
      end
    end
    table.insert(runs, run)

    -- create new subdivided notes
    for _, r in ipairs(runs) do
      local start = r[1].start
      local finish = r[#r].finish
      local span = finish - start
      local slices = #r + 1
      local step = span / slices

      for i = 0, slices-1 do
        local s = start + step*i
        local e = start + step*(i+1)

        reaper.MIDI_InsertNote(
          take, true, r[1].muted,
          s, e,
          r[1].chan,
          r[1].pitch,
          r[1].vel,
          true
        )
      end
    end
  end

  reaper.MIDI_Sort(take)
end

function Glue()
  local take = GetPianoRollTake()
  if not take then return end
  local _, noteCount = reaper.MIDI_CountEvts(take)

  -- group selected notes by pitch/channel
  local groups = {}
  for i = 0, noteCount-1 do
    local ok, sel, muted, startppq, endppq, chan, pitch, vel =
      reaper.MIDI_GetNote(take, i)
    if sel then
      local key = pitch.."_"..chan
      groups[key] = groups[key] or {}
      table.insert(groups[key], {
        idx=i,
        start=startppq,
        finish=endppq,
        pitch=pitch,
        chan=chan,
        vel=vel,
        muted=muted
      })
    end
  end

  reaper.MIDI_DisableSort(take)

  -- 1️⃣ Collect all notes to delete across all runs
  local notesToDelete = {}
  local runsByGroup = {} -- store runs to rebuild after deletion
  for gkey, notes in pairs(groups) do
    table.sort(notes, function(a,b) return a.start < b.start end)

    -- detect consecutive/overlapping runs
    local runs = {}
    local run = {notes[1]}
    for i=2,#notes do
      local prev = run[#run]
      local cur  = notes[i]
      if cur.start <= prev.finish then
        table.insert(run, cur)
      else
        table.insert(runs, run)
        run = {cur}
      end
    end
    table.insert(runs, run)
    runsByGroup[gkey] = runs

    -- mark all notes for deletion
    for _, r in ipairs(runs) do
      for _, n in ipairs(r) do
        table.insert(notesToDelete, n.idx)
      end
    end
  end

  -- 2️⃣ Delete all notes in descending index order (safe!)
  table.sort(notesToDelete, function(a,b) return a > b end)
  for _, idx in ipairs(notesToDelete) do
    reaper.MIDI_DeleteNote(take, idx)
  end

  -- 3️⃣ Rebuild merged notes for each run (stepwise glue)
  for gkey, runs in pairs(runsByGroup) do
    for _, r in ipairs(runs) do
      local start = r[1].start
      local finish = r[#r].finish
      local pitch = r[1].pitch
      local chan  = r[1].chan
      local vel   = r[1].vel
      local muted = r[1].muted

      local numNotes = #r
      if numNotes <= 1 then goto continue end  -- nothing to glue

      -- insert numNotes-1 evenly spaced notes
      local step = (finish - start) / (numNotes - 1)
      for i = 0, numNotes-2 do
        local s = start + step*i
        local e = start + step*(i+1)
        reaper.MIDI_InsertNote(take, true, muted,
          s, e, chan, pitch, vel, true)
      end

      ::continue::
    end
  end

  reaper.MIDI_Sort(take)
end

-- UI ----------------------------------

local function CountSelectedNotes()
  local take = GetPianoRollTake()
  if not take then return 0 end

  local _, noteCount, _, _ = reaper.MIDI_CountEvts(take)

  local selected = 0
  for i = 0, noteCount-1 do
    local _, sel = reaper.MIDI_GetNote(take, i)
    if sel then selected = selected + 1 end
  end

  return selected
end

if not reaper.ImGui_GetBuiltinPath then
  return reaper.MB('ReaImGui is not installed or too old. Install via Reapack.', 'High Roller', 0)
end

package.path = reaper.ImGui_GetBuiltinPath() .. '/?.lua'
local ImGui = require 'imgui' '0.10'
local ctx = ImGui.CreateContext('High Roller')

local function myWindow()
  local selected = CountSelectedNotes()
  ImGui.Text(ctx, "Selected notes: " .. selected)

  ImGui.BeginDisabled(ctx, selected == 0)

    if ImGui.Button(ctx, 'Flip Horizontal', 100) then
      FlipHorizontal()
    end

    ImGui.SameLine(ctx)

    if ImGui.Button(ctx, 'Flip Vertical', 100) then
      FlipVertical()
    end

    if ImGui.Button(ctx, 'Split', 100) then
      Split()
    end

    ImGui.SameLine(ctx)

    if ImGui.Button(ctx, 'Glue', 100) then
      Glue()
    end

  ImGui.EndDisabled(ctx)
end

local function loop()
  ImGui.SetNextWindowSize(ctx, 230, 200, ImGui.Cond_Always)
  local visible, open = ImGui.Begin(ctx, 'High Roller', true)
  if visible then
    myWindow()
    ImGui.End(ctx)
  end

  if open then
    reaper.defer(loop)
  end
end

reaper.defer(loop)