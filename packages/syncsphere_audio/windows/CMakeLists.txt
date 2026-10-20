# Windows implementation of the SyncSphere audio plugin: WASAPI output with
# scheduled starts and rate control, Media Foundation decoding.
cmake_minimum_required(VERSION 3.14)

set(PROJECT_NAME "syncsphere_audio")
project(${PROJECT_NAME} LANGUAGES CXX)
cmake_policy(VERSION 3.14...3.25)

# This value is used when generating builds using this plugin, so it must
# not be changed.
set(PLUGIN_NAME "syncsphere_audio_plugin")

list(APPEND PLUGIN_SOURCES
  "audio_engine.cpp"
  "audio_engine.h"
  "media_decoder.cpp"
  "media_decoder.h"
  "render_math.h"
  "syncsphere_audio_plugin.cpp"
  "syncsphere_audio_plugin.h"
)

add_library(${PLUGIN_NAME} SHARED
  "include/syncsphere_audio/syncsphere_audio_plugin_c_api.h"
  "syncsphere_audio_plugin_c_api.cpp"
  ${PLUGIN_SOURCES}
)

apply_standard_settings(${PLUGIN_NAME})

set_target_properties(${PLUGIN_NAME} PROPERTIES CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL NOMINMAX WIN32_LEAN_AND_MEAN)

target_include_directories(${PLUGIN_NAME} INTERFACE "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(${PLUGIN_NAME} PRIVATE
  flutter flutter_wrapper_plugin
  mfplat mfreadwrite mfuuid avrt ole32 propsys shell32)

set(syncsphere_audio_bundled_libraries "" PARENT_SCOPE)
