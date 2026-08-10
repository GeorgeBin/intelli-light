#include "MainWindow.h"
#include "Version.h"

#include <KAboutData>
#include <KLocalizedString>

#include <QApplication>
#include <QCommandLineParser>
#include <QIcon>

int main(int argc, char **argv)
{
    QApplication application(argc, argv);
    application.setQuitOnLastWindowClosed(false);
    QCoreApplication::setOrganizationDomain(QStringLiteral("io.github.georgebin"));
    QCoreApplication::setApplicationName(QStringLiteral("intelli-light-desktop"));
    QGuiApplication::setDesktopFileName(QStringLiteral("io.github.georgebin.intelli-light"));

    KLocalizedString::setApplicationDomain("intelli-light");
    KAboutData aboutData(
        QStringLiteral("intelli-light-desktop"),
        i18n("Intelli Light"),
        QStringLiteral(INTELLI_LIGHT_VERSION),
        i18n("Native KDE Plasma desktop for Intelli Light"),
        KAboutLicense::MIT,
        i18n("Copyright 2026 GeorgeBin contributors"));
    aboutData.setDesktopFileName(QStringLiteral("io.github.georgebin.intelli-light"));
    aboutData.setHomepage(QStringLiteral("https://github.com/GeorgeBin/intelli-light"));
    KAboutData::setApplicationData(aboutData);

    QCommandLineParser parser;
    aboutData.setupCommandLine(&parser);
    parser.process(application);
    aboutData.processCommandLine(&parser);

    MainWindow window;
    window.show();
    return application.exec();
}
