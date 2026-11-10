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

# One C runtime for SDL and the game: the static one, so the .exe needs no
# Visual C++ redistributable of its own.
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded")

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

# The GPU kernels (shaders/*.comp, translated from the Mac app's Metal in
# Shaders.swift): GLSL compiled to SPIR-V with glslc (the Vulkan SDK's, or the
# system's), embedded in the program, run through SDL_GPU on Vulkan.
find_program(GLSLC glslc HINTS "$ENV{VULKAN_SDK}/Bin" "$ENV{VULKAN_SDK}/bin" REQUIRED)
set(VC_KERNELS accumulate streak develop viewfinder meter dof_pack dof_tiles dof_blur relight shadow_vis flare_probe lens_fx background_fill negative shell_store develop16)
set(spv_dir ${CMAKE_BINARY_DIR}/spv)
file(GLOB shader_lib ${CMAKE_SOURCE_DIR}/shaders/*.glsl)
set(spv_files)
foreach(k IN LISTS VC_KERNELS)
  add_custom_command(OUTPUT ${spv_dir}/${k}.spv
    COMMAND ${CMAKE_COMMAND} -E make_directory ${spv_dir}
    COMMAND ${GLSLC} --target-env=vulkan1.1 -O -I ${CMAKE_SOURCE_DIR}/shaders
            ${CMAKE_SOURCE_DIR}/shaders/${k}.comp -o ${spv_dir}/${k}.spv
    DEPENDS ${CMAKE_SOURCE_DIR}/shaders/${k}.comp ${shader_lib}
    COMMENT "glslc ${k}.comp")
  list(APPEND spv_files ${spv_dir}/${k}.spv)
endforeach()
add_custom_command(OUTPUT ${CMAKE_BINARY_DIR}/gen/shaders_spv.h
  COMMAND ${CMAKE_COMMAND} -E make_directory ${CMAKE_BINARY_DIR}/gen
  COMMAND ${CMAKE_COMMAND} -DOUT=${CMAKE_BINARY_DIR}/gen/shaders_spv.h "-DNAMES=${VC_KERNELS}" -DDIR=${spv_dir}
          -P ${CMAKE_SOURCE_DIR}/cmake/embed_spirv.cmake
  DEPENDS ${spv_files} ${CMAKE_SOURCE_DIR}/cmake/embed_spirv.cmake
  COMMENT "Embedding the GPU kernels")
add_custom_target(vc_shaders DEPENDS ${CMAKE_BINARY_DIR}/gen/shaders_spv.h)

add_executable(VintageClick WIN32 src/main.cpp src/movie.cpp src/platform.cpp)
add_dependencies(VintageClick vc_shaders)
target_include_directories(VintageClick PRIVATE ${CMAKE_BINARY_DIR}/gen)
if(WIN32)
  target_sources(VintageClick PRIVATE src/app.rc)   # the app icon and version info
  target_link_libraries(VintageClick PRIVATE mfplat mfreadwrite mfuuid ole32)   # the movie camera's encoder
endif()
target_include_directories(VintageClick PRIVATE src third_party)
target_link_libraries(VintageClick PRIVATE SDL3::SDL3-static Threads::Threads)
if(MSVC)
  target_compile_options(VintageClick PRIVATE /O2 /utf-8 /fp:fast /EHsc)
  target_compile_definitions(VintageClick PRIVATE _USE_MATH_DEFINES NOMINMAX _CRT_SECURE_NO_WARNINGS)
else()
  target_compile_options(VintageClick PRIVATE -O2 -ffast-math)
endif()

# assets/ (font, sounds) beside the program.
add_custom_command(TARGET VintageClick POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E copy_directory ${CMAKE_SOURCE_DIR}/assets $<TARGET_FILE_DIR:VintageClick>/assets
  COMMAND ${CMAKE_COMMAND} -E copy_directory ${CMAKE_SOURCE_DIR}/../Resources/Sounds $<TARGET_FILE_DIR:VintageClick>/assets/Sounds)
