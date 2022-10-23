-- mod-version:3
local core = require "core"
local common = require "core.common"
local keymap = require "core.keymap"
local command = require "core.command"
local style = require "core.style"
local View = require "core.view"
local native = require "plugins.projectsearch.native"

local ResultsView = View:extend()

ResultsView.context = "session"

function ResultsView:new(path, text, fn)
  ResultsView.super.new(self)
  self.scrollable = true
  self.brightness = 0
  self:begin_search(path, text, fn)
end


function ResultsView:get_name()
  return "Search Results"
end


function ResultsView:begin_search(path, text, type)
  self.search_args = { path, text, type }
  self.results = {}
  self.query = text
  self.searching = true
  self.last_file_idx = 0
  
  core.add_thread(function()
    local chunk_count, chunks_per_cycle = 0, 200
    local original = native.compile(text, type)
    local c_time = 0
    local start = system.get_time()
    for dir_name, file in core.get_project_files() do
      if file.type == "file" and (not path or (dir_name .. "/" .. file.filename):find(path, 1, true) == 1) then
        local processed_chunks, chunks, finished = 0, 0, false
        local path = (dir_name == core.project_dir and "" or (dir_name .. PATHSEP)) .. file.filename
        local line, col, offset = 1, 0, 0
        while not finished do 
          local remaining = chunks_per_cycle - processed_chunks
          local cstart = system.get_time()
          chunks, offset, line, col = native.find(self.results, path, remaining, original, offset, line, col)
          c_time = c_time + (system.get_time() - cstart)
          finished = chunks <= remaining and chunks < chunks_per_cycle
          processed_chunks = chunks + processed_chunks
          chunk_count = chunk_count + chunks
          if chunk_count > 200 then coroutine.yield() chunk_count = 0 end
        end
        self.last_file_idx = self.last_file_idx + 1
      end
    end
    local total_time = system.get_time() - start
    print("TOTAL: ", total_time)
    print("C: ", c_time)
    self.searching = false
    self.brightness = 100
    core.redraw = true
  end)
  self.scroll.to.y = 0
end


function ResultsView:refresh()
  self:begin_search(table.unpack(self.search_args))
end


function ResultsView:on_mouse_moved(mx, my, ...)
  ResultsView.super.on_mouse_moved(self, mx, my, ...)
  self.selected_idx = 0
  for i, item, x,y,w,h in self:each_visible_result() do
    if mx >= x and my >= y and mx < x + w and my < y + h then
      self.selected_idx = i
      break
    end
  end
end


function ResultsView:on_mouse_pressed(...)
  local caught = ResultsView.super.on_mouse_pressed(self, ...)
  if not caught then
    return self:open_selected_result()
  end
end


function ResultsView:open_selected_result()
  local res = self.results[self.selected_idx]
  if not res then
    return
  end
  core.try(function()
    local dv = core.root_view:open_doc(core.open_doc(res.file))
    core.root_view.root_node:update_layout()
    dv.doc:set_selection(res.line, res.col)
    dv:scroll_to_line(res.line, false, true)
  end)
  return true
end


function ResultsView:update()
  self:move_towards("brightness", 0, 0.1)
  ResultsView.super.update(self)
end


function ResultsView:get_results_yoffset()
  return style.font:get_height() + style.padding.y * 3
end


function ResultsView:get_line_height()
  return style.padding.y + style.font:get_height()
end


function ResultsView:get_scrollable_size()
  return self:get_results_yoffset() + #self.results * self:get_line_height()
end


function ResultsView:get_visible_results_range()
  local lh = self:get_line_height()
  local oy = self:get_results_yoffset()
  local min = math.max(1, math.floor((self.scroll.y - oy) / lh))
  return min, min + math.floor(self.size.y / lh) + 1
end


function ResultsView:each_visible_result()
  return coroutine.wrap(function()
    local lh = self:get_line_height()
    local x, y = self:get_content_offset()
    local min, max = self:get_visible_results_range()
    y = y + self:get_results_yoffset() + lh * (min - 1)
    for i = min, max do
      local item = self.results[i]
      if not item then break end
      coroutine.yield(i, item, x, y, self.size.x, lh)
      y = y + lh
    end
  end)
end


function ResultsView:scroll_to_make_selected_visible()
  local h = self:get_line_height()
  local y = self:get_results_yoffset() + h * (self.selected_idx - 1)
  self.scroll.to.y = math.min(self.scroll.to.y, y)
  self.scroll.to.y = math.max(self.scroll.to.y, y + h - self.size.y)
end


function ResultsView:draw()
  self:draw_background(style.background)

  -- status
  local ox, oy = self:get_content_offset()
  local x, y = ox + style.padding.x, oy + style.padding.y
  local files_number = core.project_files_number()
  local per = common.clamp(files_number and self.last_file_idx / files_number or 1, 0, 1)
  local text
  if self.searching then
    if files_number then
      text = string.format("Searching %.f%% (%d of %d files, %d matches) for %q...",
        per * 100, self.last_file_idx, files_number,
        #self.results, self.query)
    else
      text = string.format("Searching (%d files, %d matches) for %q...",
        self.last_file_idx, #self.results, self.query)
    end
  else
    text = string.format("Found %d matches for %q",
      #self.results, self.query)
  end
  local color = common.lerp(style.text, style.accent, self.brightness / 100)
  renderer.draw_text(style.font, text, x, y, color)

  -- horizontal line
  local yoffset = self:get_results_yoffset()
  local x = ox + style.padding.x
  local w = self.size.x - style.padding.x * 2
  local h = style.divider_size
  local color = common.lerp(style.dim, style.text, self.brightness / 100)
  renderer.draw_rect(x, oy + yoffset - style.padding.y, w, h, color)
  if self.searching then
    renderer.draw_rect(x, oy + yoffset - style.padding.y, w * per, h, style.text)
  end

  -- results
  local y1, y2 = self.position.y, self.position.y + self.size.y
  for i, item, x,y,w,h in self:each_visible_result() do
    local color = style.text
    if i == self.selected_idx then
      color = style.accent
      renderer.draw_rect(x, y, w, h, style.line_highlight)
    end
    x = x + style.padding.x
    local text = string.format("%s at line %d (col %d): ", item.file, item.line, item.col)
    x = common.draw_text(style.font, style.dim, text, "left", x, y, w, h)
    x = common.draw_text(style.code_font, color, item.text, "left", x, y, w, h)
  end

  self:draw_scrollbar()
end


local function begin_search(path, text, type)
  if text == "" then
    core.error("Expected non-empty string")
    return
  end
  local rv = ResultsView(path, text, type)
  core.root_view:get_active_node_default():add_view(rv)
end


local function get_selected_text()
  local view = core.active_view
  local doc = (view and view.doc) and view.doc or nil
  if doc then
    return doc:get_text(table.unpack({ doc:get_selection() }))
  end
end


local function normalize_path(path)
  if not path then return nil end
  path = common.normalize_path(path)
  for i, project_dir in ipairs(core.project_directories) do
    if common.path_belongs_to(path, project_dir.name) then
      return project_dir.item.filename .. PATHSEP .. common.relative_path(project_dir.name, path)
    end
  end
  return path
end


command.add(nil, {
  ["project-search:find"] = function(path)
    core.command_view:enter("Find Text In " .. (normalize_path(path) or "Project"), {
      text = get_selected_text(),
      select_text = true,
      submit = function(text)
        text = text:lower()
        begin_search(path, text, "text")
      end
    })
  end,

  ["project-search:find-regex"] = function(path)
    core.command_view:enter("Find Regex In " .. (normalize_path(path) or "Project"), {
      submit = function(text)
        begin_search(path, text, "regex")
      end
    })
  end,

  ["project-search:fuzzy-find"] = function(path)
    core.command_view:enter("Fuzzy Find Text In " .. (normalize_path(path) or "Project"), {
      text = get_selected_text(),
      select_text = true,
      submit = function(text)
        begin_search(path, text, "fuzzy")
      end
    })
  end,
})


command.add(ResultsView, {
  ["project-search:select-previous"] = function()
    local view = core.active_view
    view.selected_idx = math.max(view.selected_idx - 1, 1)
    view:scroll_to_make_selected_visible()
  end,

  ["project-search:select-next"] = function()
    local view = core.active_view
    view.selected_idx = math.min(view.selected_idx + 1, #view.results)
    view:scroll_to_make_selected_visible()
  end,

  ["project-search:open-selected"] = function()
    core.active_view:open_selected_result()
  end,

  ["project-search:refresh"] = function()
    core.active_view:refresh()
  end,

  ["project-search:move-to-previous-page"] = function()
    local view = core.active_view
    view.scroll.to.y = view.scroll.to.y - view.size.y
  end,

  ["project-search:move-to-next-page"] = function()
    local view = core.active_view
    view.scroll.to.y = view.scroll.to.y + view.size.y
  end,

  ["project-search:move-to-start-of-doc"] = function()
    local view = core.active_view
    view.scroll.to.y = 0
  end,

  ["project-search:move-to-end-of-doc"] = function()
    local view = core.active_view
    view.scroll.to.y = view:get_scrollable_size()
  end
})

keymap.add {
  ["f5"]                 = "project-search:refresh",
  ["ctrl+shift+f"]       = "project-search:find",
  ["up"]                 = "project-search:select-previous",
  ["down"]               = "project-search:select-next",
  ["return"]             = "project-search:open-selected",
  ["pageup"]             = "project-search:move-to-previous-page",
  ["pagedown"]           = "project-search:move-to-next-page",
  ["ctrl+home"]          = "project-search:move-to-start-of-doc",
  ["ctrl+end"]           = "project-search:move-to-end-of-doc",
  ["home"]               = "project-search:move-to-start-of-doc",
  ["end"]                = "project-search:move-to-end-of-doc"
}
