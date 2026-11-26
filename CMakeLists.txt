cmake_minimum_required(VERSION 3.16)
project(fcitx5-multiselector VERSION 0.0.3 LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 20)
# 5.1.12 is the oldest version verified to build (Debian 13); 5.1.7 does not.
find_package(Fcitx5Core 5.1.12 REQUIRED)
add_library(multiselector MODULE multiselector.cpp)
target_link_libraries(multiselector Fcitx5::Core)
set_target_properties(multiselector PROPERTIES PREFIX "")
# TabbedCandidateList appeared in fcitx5 5.1.20.
if(Fcitx5Core_VERSION VERSION_GREATER_EQUAL 5.1.20)
  target_compile_definitions(multiselector PRIVATE MULTISELECTOR_HAS_TABBED)
endif()

include(CTest)
if(BUILD_TESTING)
  add_test(NAME integration
           COMMAND ${CMAKE_CURRENT_SOURCE_DIR}/tests/integration.sh
                   $<TARGET_FILE:multiselector>)
  set_tests_properties(integration PROPERTIES
    SKIP_RETURN_CODE 77
    TIMEOUT 180
    ENVIRONMENT "ARTIFACTS=${CMAKE_CURRENT_BINARY_DIR}/test-artifacts")
endif()
