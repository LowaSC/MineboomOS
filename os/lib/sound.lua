-- Звуковая система MineboomOS. Безопасно игнорирует отсутствие speaker.
local Sound = {}

local _speaker = nil
local function getSpeaker()
    if not _speaker then _speaker = peripheral.find("speaker") end
    return _speaker
end

local function play(instr, vol, pitch)
    local s = getSpeaker()
    if not s then return end
    pcall(s.playNote, instr, math.min(3, math.max(0, vol or 1)), pitch or 12)
end

Sound.click   = function(v) play("harp",  (v or 1) * 0.4, 12) end
Sound.open    = function(v) play("harp",  (v or 1) * 0.7, 16) end
Sound.close   = function(v) play("harp",  (v or 1) * 0.4, 10) end
Sound.notify  = function(v) play("bell",  (v or 1) * 0.8, 12) end
Sound.error   = function(v) play("bass",  (v or 1) * 1.0, 5)  end
Sound.success = function(v) play("pling", (v or 1) * 0.8, 12) end
Sound.login   = function(v) play("pling", (v or 1) * 1.0, 18) end
Sound.lock    = function(v) play("bass",  (v or 1) * 0.5, 8)  end

return Sound
