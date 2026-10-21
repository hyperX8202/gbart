cmake_minimum_required(VERSION 3.5.0)
project(keyboard_engine)

# Sources live outside the module so the engine can also be built and tested on the host
# (see native/test). Paths are relative to entry/src/main/cpp.
set(KEYBOARD_ROOT ${CMAKE_CURRENT_SOURCE_DIR}/../../../..)
set(LATINIME_SRC ${KEYBOARD_ROOT}/third_party/latinime/src)
set(NATIVE_DIR ${KEYBOARD_ROOT}/native)

file(GLOB_RECURSE LATINIME_SOURCES ${LATINIME_SRC}/*.cpp)

add_library(keyboard_engine SHARED
    ${LATINIME_SOURCES}
    ${NATIVE_DIR}/latinime_engine.cpp
    ${NATIVE_DIR}/gesture_decoder.cpp
    ${NATIVE_DIR}/napi_init.cpp)

target_include_directories(keyboard_engine PRIVATE
    ${NATIVE_DIR}/ohos_jni
    ${NATIVE_DIR}
    ${LATINIME_SRC})

set_target_properties(keyboard_engine PROPERTIES CXX_STANDARD 17 CXX_STANDARD_REQUIRED ON)
# The AOSP core is warning-heavy and uses VLAs; keep the build quiet like Android.mk does (-w).
target_compile_options(keyboard_engine PRIVATE -w -O2)
target_link_libraries(keyboard_engine PUBLIC libace_napi.z.so libz.so)
