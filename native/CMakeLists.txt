# LGPL-3.0-or-later

cmake_minimum_required(VERSION 3.22.1)

project(glesmod_native LANGUAGES C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS ON)

add_library(gl_gles SHARED
    src/core.c
    src/custom.c
    src/enum.c
    src/generated_forwarders.c
    src/probe.c
    src/shader.c
)

target_include_directories(gl_gles PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/include"
    "${CMAKE_CURRENT_SOURCE_DIR}/src"
)

find_library(ANDROID_LOG_LIB log)
find_library(ANDROID_DL_LIB dl)
find_library(ANDROID_M_LIB m)

target_link_libraries(gl_gles PRIVATE
    ${ANDROID_LOG_LIB}
    ${ANDROID_DL_LIB}
    ${ANDROID_M_LIB}
)

set_target_properties(gl_gles PROPERTIES
    OUTPUT_NAME "gl_gles"
    C_VISIBILITY_PRESET default
    VISIBILITY_INLINES_HIDDEN OFF
)
