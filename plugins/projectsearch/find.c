// gcc find.c -I ~/lite/lite-xl/resources -shared -fPIC -o native.so
#include <lite_xl_plugin_api.h>
#include <string.h>
#include <ctype.h>


#define FIND_CHUNK_SIZE 8192
#define CONTEXT_SIZE 80
#define min(a,b) (a) < (b) ? (a) : (b)
#define max(a,b) (a) < (b) ? (b) : (a)

static int result_view_begin_search(lua_State* L) {
  const char* path = luaL_checkstring(L, 2);
  int chunk_pauses = luaL_checkinteger(L, 3);
  luaL_checktype(L, 4, LUA_TTABLE);
  int file_offset = luaL_checkinteger(L, 5);
  int line_offset = luaL_checkinteger(L, 6);
  int col_offset = luaL_checkinteger(L, 7);
  lua_rawgeti(L, 4, 1);
  size_t text_length;
  const char* lower_text = luaL_checkstring(L, -1);
  lua_rawgeti(L, 4, 2);
  const char* upper_text = luaL_checklstring(L, -1, &text_length);
  FILE* file = fopen(path, "rb");
  if (!file) {
    lua_pushinteger(L, 0);
    return 1;
  }
  if (file_offset)
    fseek(file, file_offset, SEEK_SET);
  char chunk[FIND_CHUNK_SIZE];
  int offset = 0;
  int line = line_offset;
  int last_valid = 0;
  int col = col_offset;
  int chunks = 0;
  int last_line = 0;
  for (chunks = 0; chunks < chunk_pauses; ++chunks) {
    last_line = 0;
    int length = fread(&chunk[offset], 1, sizeof(chunk) - offset, file);
    if (length < 0)
      return luaL_error(L, "error in file read");
    length += offset;
    if (length <= text_length)
      break;
    for (int i = 0; i < length; ++i, ++col) {
      if (chunk[i] == '\n') {
        ++line;
        last_line = i + 1;
        col = 0;
      } else if (chunk[i] == lower_text[0] || chunk[i] == upper_text[0]) {
        if (i > length - text_length - (length == FIND_CHUNK_SIZE ? CONTEXT_SIZE : 0)) {
          offset = length - i;
          memcpy(chunk, &chunk[i], length - i);
          file_offset = ftell(file) + i;
          line_offset = line;
          col_offset = col;
          last_line = 0;
          break;
        }
        int end = i + text_length, j;
        for (j = i+1; j <= end; ++j) {
          if (chunk[j] != lower_text[j - i] && chunk[j] != upper_text[j - i]) {
            break;
          }
        }
        if (j == end) {
          int len = luaL_len(L, 1);
          lua_newtable(L);
          lua_pushstring(L, path);
          lua_setfield(L, -2, "file");
          int concats = 1;
          if (j - CONTEXT_SIZE > last_line) {
            ++concats;
            lua_pushliteral(L, "... ");
          }
          int start_line = max(j - CONTEXT_SIZE, last_line);
          int newline_occurence = 0;
          int line_length = min(text_length + (max(CONTEXT_SIZE*2 - text_length, 0)), length - j);
          int end_line = start_line + line_length;
          for (newline_occurence = j; newline_occurence < end_line && chunk[newline_occurence] != '\n'; ++newline_occurence);
          lua_pushlstring(L, &chunk[start_line], newline_occurence - start_line);
          if (concats > 1)
            lua_concat(L, concats);
          lua_setfield(L, -2, "text");
          lua_pushinteger(L, line);
          lua_setfield(L, -2, "line");
          lua_pushinteger(L, col);
          lua_setfield(L, -2, "col");
          lua_rawseti(L, 1, len + 1);
        }
      } 
    }
  }
  fclose(file);
  lua_pushinteger(L, chunks);
  lua_pushinteger(L, file_offset);
  lua_pushinteger(L, line_offset);
  lua_pushinteger(L, col_offset);
  return 3;
} 

static int result_view_compile(lua_State* L) {
  size_t len;
  const char* text = luaL_checklstring(L, 1, &len);
  char buffer1[1024];
  char buffer2[1024];
  for (int i = 0; i < len; ++i) {
    buffer1[i] = tolower(text[i]);
    buffer2[i] = toupper(text[i]);
  }
  buffer1[len] = 0;
  buffer2[len] = 0;
  lua_newtable(L);
  lua_pushlstring(L, buffer1, len);
  lua_rawseti(L, -2, 1);
  lua_pushlstring(L, buffer2, len);
  lua_rawseti(L, -2, 2);
  return 1;
}


int luaopen_lite_xl_native(lua_State* L, void* XL) {
  lite_xl_plugin_init(XL);
  lua_newtable(L);
  lua_pushcfunction(L, result_view_compile);
  lua_setfield(L, -2, "compile");
  lua_pushcfunction(L, result_view_begin_search);
  lua_setfield(L, -2, "find");
  return 1;
}
