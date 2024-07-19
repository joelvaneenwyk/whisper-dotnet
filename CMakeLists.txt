# CMakeList.txt : Top-level CMake project file, do global configuration
# and include sub-projects here.
#
cmake_minimum_required (VERSION 3.8)

# Find the 'git' package so that we can automatically initialize
# submodules before we build. This is a modified version of what
# was described in Modern CMake here:
#
#   - https://cliutils.gitlab.io/modern-cmake/chapters/projects/submodule.html
#
find_package(Git QUIET)
if(GIT_FOUND AND EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/.git" AND NOT EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/whisper.cpp/.gitmodules")
  message(STATUS "The submodules are currently being updated...")
  execute_process(COMMAND ${GIT_EXECUTABLE} submodule update --init --recursive
                  WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
                  RESULT_VARIABLE GIT_SUBMOD_RESULT)
  if(NOT GIT_SUBMOD_RESULT EQUAL "0")
      message(FATAL_ERROR "git submodule update --init --recursive failed with ${GIT_SUBMOD_RESULT}, please checkout submodules")
  endif()

  if(NOT EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/whisper.cpp/.gitmodules")
      message(FATAL_ERROR "Failed to update submodules!")
  endif()
endif()

# Enable Hot Reload for MSVC compilers if supported.
if (POLICY CMP0141)
  cmake_policy(SET CMP0141 NEW)
  set(CMAKE_MSVC_DEBUG_INFORMATION_FORMAT "$<IF:$<AND:$<C_COMPILER_ID:MSVC>,$<CXX_COMPILER_ID:MSVC>>,$<$<CONFIG:Debug,RelWithDebInfo>:EditAndContinue>,$<$<CONFIG:Debug,RelWithDebInfo>:ProgramDatabase>>")
endif()

project ("Whisper.net")

# Include sub-projects.
add_subdirectory ("whisper.cpp")
