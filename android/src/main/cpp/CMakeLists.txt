cmake_minimum_required(VERSION 3.22.1)
project("libdivecomputer_plugin_jni" LANGUAGES C CXX)

# ── libdivecomputer (prebuilt static library) ────────────────────────────
#
# Static .a files are linked into our JNI bridge at build time.
# The final liblibdivecomputer_plugin_jni.so contains everything — no separate
# libdivecomputer.so to ship. Same approach as iOS/macOS.

add_library(divecomputer STATIC IMPORTED)
set_target_properties(divecomputer PROPERTIES
    IMPORTED_LOCATION "${CMAKE_SOURCE_DIR}/libs/${ANDROID_ABI}/libdivecomputer.a"
)

# ── JNI bridge ───────────────────────────────────────────────────────────

add_library(libdivecomputer_plugin_jni SHARED
    jni_bridge.cpp
)

target_include_directories(libdivecomputer_plugin_jni PRIVATE
    ${CMAKE_SOURCE_DIR}/include
)

target_link_libraries(libdivecomputer_plugin_jni
    divecomputer
    log
)

set_target_properties(libdivecomputer_plugin_jni PROPERTIES
    C_STANDARD   11
    CXX_STANDARD 17
)