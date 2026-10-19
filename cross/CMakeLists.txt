# Vintage Click, cross-platform build (Windows, Linux; macOS for testing).
# The renderer (spirula_render) is built separately from Spirula Studio with
# renderer/spirula-vintage-click.patch and loaded at run time from beside the
# program; this builds the game and fetches SDL3.
cmake_minimum_required(VERSION 3.24)
project(VintageClick CXX C)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release)
endif()

include(FetchContent)
set(SDL_SHARED OFF CACHE BOOL "" FORCE)
set(SDL_STATIC ON CACHE BOOL "" FORCE)
set(SDL_TEST_LIBRARY OFF CACHE BOOL "" FORCE)
FetchContent_Declare(SDL3
  GIT_REPOSITORY https://github.com/libsdl-org/SDL.git
  GIT_TAG release-3.2.24
  GIT_SHALLOW TRUE)
FetchContent_MakeAvailable(SDL3)

find_package(Threads REQUIRED)
add_executable(VintageClick WIN32 src/main.cpp)
target_include_directories(VintageClick PRIVATE src third_party)
target_link_libraries(VintageClick PRIVATE SDL3::SDL3-static Threads::Threads)
if(MSVC)
  target_compile_options(VintageClick PRIVATE /O2 /utf-8 /fp:fast /EHsc)
  target_compile_definitions(VintageClick PRIVATE _USE_MATH_DEFINES NOMINMAX _CRT_SECURE_NO_WARNINGS)
  set_property(TARGET VintageClick PROPERTY MSVC_RUNTIME_LIBRARY "MultiThreaded")
else()
  target_compile_options(VintageClick PRIVATE -O2 -ffast-math)
endif()

# assets/ (font, sounds) beside the program.
add_custom_command(TARGET VintageClick POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E copy_directory ${CMAKE_SOURCE_DIR}/assets $<TARGET_FILE_DIR:VintageClick>/assets
  COMMAND ${CMAKE_COMMAND} -E copy_directory ${CMAKE_SOURCE_DIR}/../Resources/Sounds $<TARGET_FILE_DIR:VintageClick>/assets/Sounds)
