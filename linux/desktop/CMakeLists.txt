cmake_minimum_required(VERSION 3.22)
project(intelli-light-desktop VERSION 0.1.0 LANGUAGES CXX)

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
    src/DefaultSettings.h
    src/IpcClient.cpp
    src/IpcClient.h
    src/StatePresentation.cpp
    src/StatePresentation.h
)
target_link_libraries(intelli-light-desktop-support
    PUBLIC Qt6::Core Qt6::Gui Qt6::Network
)
target_include_directories(intelli-light-desktop-support PUBLIC src)

add_executable(intelli-light-desktop
    src/main.cpp
    src/MainWindow.cpp
    src/MainWindow.h
    data/resources.qrc
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

configure_file(data/io.github.kiwigaze.intelli-light.desktop.in
    io.github.kiwigaze.intelli-light.desktop @ONLY)
install(TARGETS intelli-light-desktop ${KDE_INSTALL_TARGETS_DEFAULT_ARGS})
install(FILES ${CMAKE_CURRENT_BINARY_DIR}/io.github.kiwigaze.intelli-light.desktop
    DESTINATION ${KDE_INSTALL_APPDIR})
install(FILES data/icons/intelli-light.svg
    DESTINATION ${KDE_INSTALL_ICONDIR}/hicolor/scalable/apps)
