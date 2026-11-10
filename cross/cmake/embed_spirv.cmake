# Writes the compiled shaders (SPIR-V) into one header as byte arrays:
#   cmake -DOUT=shaders_spv.h -DNAMES="develop;accumulate" -DDIR=<spv dir> -P embed_spirv.cmake
set(text "// Generated from cross/shaders by embed_spirv.cmake: do not edit.\n#pragma once\n#include <cstddef>\n#include <cstdint>\n\n")
foreach(name IN LISTS NAMES)
  file(READ "${DIR}/${name}.spv" hex HEX)
  string(LENGTH "${hex}" n)
  math(EXPR bytes "${n} / 2")
  string(REGEX REPLACE "([0-9a-f][0-9a-f])" "0x\\1," body "${hex}")
  string(APPEND text "static const uint8_t spv_${name}[${bytes}] = {${body}};\n")
endforeach()
file(WRITE "${OUT}.tmp" "${text}")
file(COPY_FILE "${OUT}.tmp" "${OUT}" ONLY_IF_DIFFERENT)
