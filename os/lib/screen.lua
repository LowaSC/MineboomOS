local Screen = {}

local function color(value, fallback)
    if colors and value then return value end
    return fallback
end

function Screen.create()
    local target = term.current()

    local self = {
        target = target,
        width = 51,
        height = 19,
    }

    function self:refreshSize()
        self.width, self.height = self.target.getSize()
    end

    function self:clear(bg, fg)
        self:refreshSize()
        self.target.setBackgroundColor(color(bg, colors.black))
        self.target.setTextColor(color(fg, colors.white))
        self.target.clear()
        self.target.setCursorPos(1, 1)
    end

    function self:writeAt(x, y, text, fg, bg)
        self.target.setCursorPos(x, y)
        if bg then self.target.setBackgroundColor(bg) end
        if fg then self.target.setTextColor(fg) end
        self.target.write(tostring(text or ""))
    end

    function self:line(y, text, fg, bg)
        self:writeAt(1, y, string.rep(" ", self.width), fg, bg)
        self:writeAt(1, y, text, fg, bg)
    end

    function self:title(title, subtitle)
        self:clear(colors.black, colors.white)
        self:line(1, string.rep(" ", self.width), colors.white, colors.gray)
        self:writeAt(2, 1, title, colors.white, colors.gray)
        if subtitle then
            self:writeAt(2, 2, subtitle, colors.lightGray, colors.black)
        end
    end

    self:refreshSize()
    return self
end

return Screen
