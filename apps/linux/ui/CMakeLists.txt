cmake_minimum_required(VERSION 3.22)

set(INTELLI_LIGHT_CARGO_MANIFEST "${CMAKE_CURRENT_SOURCE_DIR}/../program/Cargo.toml")
if(NOT EXISTS "${INTELLI_LIGHT_CARGO_MANIFEST}")
    message(FATAL_ERROR "Cannot find version source: ${INTELLI_LIGHT_CARGO_MANIFEST}")
endif()

file(STRINGS "${INTELLI_LIGHT_CARGO_MANIFEST}" INTELLI_LIGHT_VERSION_LINES
    REGEX "^[ \\t]*version[ \\t]*=[ \\t]*\"[^\"]+\"[ \\t]*$")
list(LENGTH INTELLI_LIGHT_VERSION_LINES INTELLI_LIGHT_VERSION_LINE_COUNT)
if(NOT INTELLI_LIGHT_VERSION_LINE_COUNT EQUAL 1)
    message(FATAL_ERROR
        "Expected exactly one package version in ${INTELLI_LIGHT_CARGO_MANIFEST}, "
        "found ${INTELLI_LIGHT_VERSION_LINE_COUNT}")
endif()
list(GET INTELLI_LIGHT_VERSION_LINES 0 INTELLI_LIGHT_VERSION_LINE)
string(REGEX REPLACE "^[ \\t]*version[ \\t]*=[ \\t]*\"([^\"]+)\"[ \\t]*$" "\\1"
    INTELLI_LIGHT_VERSION "${INTELLI_LIGHT_VERSION_LINE}")
string(REGEX MATCH "^[0-9]+\\.[0-9]+\\.[0-9]+" INTELLI_LIGHT_CMAKE_VERSION
    "${INTELLI_LIGHT_VERSION}")
if(NOT INTELLI_LIGHT_CMAKE_VERSION)
    message(FATAL_ERROR "Invalid Cargo package version: ${INTELLI_LIGHT_VERSION}")
endif()

project(intelli-light-desktop VERSION ${INTELLI_LIGHT_CMAKE_VERSION} LANGUAGES CXX)

configure_file(src/Version.h.in ${CMAKE_CURRENT_BINARY_DIR}/generated/Version.h @ONLY)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTORCC ON)

find_package(ECM 6.0 REQUIRED NO_MODULE)
list(APPEND CMAKE_MODULE_PATH ${ECM_MODULE_PATH})
include(KDEInstallDirs6)
include(KDECMakeSettings)
include(KDECompilerSettings NO_POLICY_SCOPE)
set(CMAKE_INSTALL_RPATH "")

find_package(Qt6 6.6 REQUIRED COMPONENTS Core Gui Network Test Widgets)
find_package(KF6 6.0 REQUIRED COMPONENTS CoreAddons I18n StatusNotifierItem)
set(CMAKE_SKIP_INSTALL_RPATH TRUE)

add_library(intelli-light-desktop-support STATIC
    src/ColorEditWidget.cpp
    src/ColorEditWidget.h
    src/ColorUtils.cpp
    src/ColorUtils.h
    src/DefaultSettings.h
    src/IpcClient.cpp
    src/IpcClient.h
    src/StatePresentation.cpp
    src/StatePresentation.h
)
target_link_libraries(intelli-light-desktop-support
    PUBLIC Qt6::Core Qt6::Gui Qt6::Network Qt6::Widgets
)
target_include_directories(intelli-light-desktop-support PUBLIC src)

add_executable(intelli-light-desktop
    src/main.cpp
    src/MainWindow.cpp
    src/MainWindow.h
    data/resources.qrc
)
target_include_directories(intelli-light-desktop PRIVATE
    ${CMAKE_CURRENT_BINARY_DIR}/generated
)
target_link_libraries(intelli-light-desktop PRIVATE
    intelli-light-desktop-support
    Qt6::Widgets
    KF6::CoreAddons
    KF6::I18n
    KF6::StatusNotifierItem
)
set_property(TARGET intelli-light-desktop PROPERTY INSTALL_RPATH "")

enable_testing()
add_executable(desktop-tests tests/DesktopTests.cpp)
target_link_libraries(desktop-tests PRIVATE
    intelli-light-desktop-support
    Qt6::Test
    Qt6::Widgets
)
add_test(NAME desktop-tests COMMAND desktop-tests)
set_tests_properties(desktop-tests PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen")

configure_file(data/io.github.georgebin.intelli-light.desktop.in
    io.github.georgebin.intelli-light.desktop @ONLY)
install(TARGETS intelli-light-desktop ${KDE_INSTALL_TARGETS_DEFAULT_ARGS})
install(FILES ${CMAKE_CURRENT_BINARY_DIR}/io.github.georgebin.intelli-light.desktop
    DESTINATION ${KDE_INSTALL_APPDIR})
install(FILES data/icons/intelli-light.svg
    DESTINATION ${KDE_INSTALL_ICONDIR}/hicolor/scalable/apps)
