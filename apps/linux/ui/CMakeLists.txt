cmake_minimum_required(VERSION 3.22)

set(INTELLI_LIGHT_REPO_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../..")
set(INTELLI_LIGHT_VERSION_FILE "${INTELLI_LIGHT_REPO_DIR}/VERSION")
set(INTELLI_LIGHT_APP_ID_FILE "${INTELLI_LIGHT_REPO_DIR}/APP_ID")
if(NOT EXISTS "${INTELLI_LIGHT_VERSION_FILE}" OR NOT EXISTS "${INTELLI_LIGHT_APP_ID_FILE}")
    message(FATAL_ERROR "Missing root VERSION or APP_ID metadata")
endif()

file(READ "${INTELLI_LIGHT_VERSION_FILE}" INTELLI_LIGHT_VERSION)
file(READ "${INTELLI_LIGHT_APP_ID_FILE}" INTELLI_LIGHT_APP_ID)
string(STRIP "${INTELLI_LIGHT_VERSION}" INTELLI_LIGHT_VERSION)
string(STRIP "${INTELLI_LIGHT_APP_ID}" INTELLI_LIGHT_APP_ID)
if(DEFINED INTELLI_LIGHT_EXPECTED_VERSION AND
   NOT INTELLI_LIGHT_EXPECTED_VERSION STREQUAL INTELLI_LIGHT_VERSION)
    message(FATAL_ERROR "VERSION mismatch between build input and root metadata")
endif()
if(DEFINED INTELLI_LIGHT_EXPECTED_APP_ID AND
   NOT INTELLI_LIGHT_EXPECTED_APP_ID STREQUAL INTELLI_LIGHT_APP_ID)
    message(FATAL_ERROR "APP_ID mismatch between build input and root metadata")
endif()
if(NOT INTELLI_LIGHT_VERSION MATCHES "^[0-9]+\\.[0-9]+\\.[0-9]+$")
    message(FATAL_ERROR "Invalid VERSION metadata: ${INTELLI_LIGHT_VERSION}")
endif()
if(NOT INTELLI_LIGHT_APP_ID MATCHES "^[A-Za-z0-9]+(\\.[A-Za-z0-9-]+)+$")
    message(FATAL_ERROR "Invalid APP_ID metadata: ${INTELLI_LIGHT_APP_ID}")
endif()

project(intelli-light-desktop VERSION ${INTELLI_LIGHT_VERSION} LANGUAGES CXX)

configure_file(src/AppMetadata.h.in ${CMAKE_CURRENT_BINARY_DIR}/generated/AppMetadata.h @ONLY)
configure_file(data/intelli-light.desktop.in
    ${CMAKE_CURRENT_BINARY_DIR}/${INTELLI_LIGHT_APP_ID}.desktop @ONLY)

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

install(TARGETS intelli-light-desktop ${KDE_INSTALL_TARGETS_DEFAULT_ARGS})
install(FILES ${CMAKE_CURRENT_BINARY_DIR}/${INTELLI_LIGHT_APP_ID}.desktop
    DESTINATION ${KDE_INSTALL_APPDIR})
install(FILES data/icons/intelli-light.svg
    DESTINATION ${KDE_INSTALL_ICONDIR}/hicolor/scalable/apps)
