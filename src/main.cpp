#include <QFont>
#include <QFontDatabase>
#include <QApplication>
#include <QIcon>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQmlError>
#include <QQuickStyle>
#include <QUrl>
#include <QWindow>
#include <QFile>
#include <QDir>
#include <QStandardPaths>
#include <QTextStream>

#include "backend.h"
#include "cli.h"
#include "notes.h"
#include "systemtheme.h"

#define OMAWRITE_VERSION "0.2.1"

int main(int argc, char *argv[]) {
    // Answered before the application exists, so they need no display.
    if (const std::optional<int> exitCode =
            Cli::handleArguments(argc, argv, QStringLiteral(OMAWRITE_VERSION)))
        return *exitCode;

    // `omawrite-plus import FILE...` copies Markdown files in as notes,
    // without a window, so a script or an agent can fill the library.
    if (argc > 2 && QString::fromLocal8Bit(argv[1]) == QLatin1String("import")) {
        QCoreApplication core(argc, argv);
        core.setOrganizationName(QStringLiteral("Omacom"));
        core.setApplicationName(QStringLiteral("omawrite-plus"));
        Notes notes(nullptr, QDir(QStandardPaths::writableLocation(
                                      QStandardPaths::AppDataLocation)).filePath(QStringLiteral("notes")));
        int failures = 0;
        for (int index = 2; index < argc; ++index) {
            QString error;
            const QString path = QString::fromLocal8Bit(argv[index]);
            if (notes.importFile(path, &error).isEmpty()) {
                QTextStream(stderr) << error << '\n';
                ++failures;
            } else {
                QTextStream(stdout) << QStringLiteral("Imported %1\n").arg(path);
            }
        }
        return failures == 0 ? 0 : 1;
    }

    // Omarchy asks Qt for GTK 3 dialogs, which run inside this process, and a
    // long-standing GTK 3 file chooser assertion aborts the whole app, unsaved
    // text and all. The desktop portal shows the same chooser from a process
    // of its own.
    if (qgetenv("QT_QPA_PLATFORMTHEME") == "gtk3")
        qputenv("QT_QPA_PLATFORMTHEME", "xdgdesktopportal");

    QApplication app(argc, argv);
    app.setApplicationName(QStringLiteral("omawrite-plus"));
    app.setApplicationVersion(QStringLiteral(OMAWRITE_VERSION));
    app.setDesktopFileName(QStringLiteral("omawrite-plus"));
    app.setWindowIcon(QIcon::fromTheme(QStringLiteral("omawrite-plus")));

    QFontDatabase::addApplicationFont(QStringLiteral(":/fonts/IBMPlexMono-Regular.ttf"));
    QFontDatabase::addApplicationFont(QStringLiteral(":/fonts/IBMPlexMono-Italic.ttf"));
    QFontDatabase::addApplicationFont(QStringLiteral(":/fonts/IBMPlexMono-Bold.ttf"));
    QFontDatabase::addApplicationFont(QStringLiteral(":/fonts/IBMPlexMono-BoldItalic.ttf"));
    // The script the app signs its name in, top right.
    QFontDatabase::addApplicationFont(QStringLiteral(":/fonts/GreatVibes-Regular.ttf"));
    app.setOrganizationName(QStringLiteral("Omacom"));
    app.setOrganizationDomain(QStringLiteral("omacom.io"));

    QQuickStyle::setStyle(QStringLiteral("Material"));

    Backend backend(&app);
    SystemTheme systemTheme(&app);
    backend.setDarkMode(systemTheme.darkMode());
    QObject::connect(&systemTheme, &SystemTheme::darkModeChanged, &backend,
                     &Backend::setDarkMode);

    // Carry the text scale into the default font, so the chrome that inherits
    // it (dialog titles, buttons) grows along with the writing area.
    const QFont interfaceFont(QStringLiteral("IBM Plex Mono"));
    const qreal basePointSize = interfaceFont.pointSizeF() > 0
        ? interfaceFont.pointSizeF()
        : app.font().pointSizeF();
    const auto applyInterfaceFont = [&app, interfaceFont, basePointSize](qreal textScale) {
        QFont scaled = interfaceFont;
        scaled.setPointSizeF(basePointSize * textScale);
        app.setFont(scaled);
    };

    // The desktop sets the baseline; the backend folds the user's own text
    // size into it and reports the total.
    backend.setDesktopTextScale(systemTheme.textScale());
    applyInterfaceFont(backend.textScale());
    QObject::connect(&systemTheme, &SystemTheme::textScaleChanged, &backend,
                     &Backend::setDesktopTextScale);
    QObject::connect(&backend, &Backend::textScaleChanged, &app,
                     [&backend, applyInterfaceFont]() {
        applyInterfaceFont(backend.textScale());
    });

    QQmlApplicationEngine engine;
    QObject::connect(&engine, &QQmlApplicationEngine::warnings, &app,
                     [](const QList<QQmlError> &warnings) {
        for (const QQmlError &warning : warnings)
            qWarning().noquote() << warning.toString();
    });
    engine.rootContext()->setContextProperty(QStringLiteral("backend"), &backend);
    Notes notes(&backend,
                QDir(QStandardPaths::writableLocation(QStandardPaths::AppDataLocation))
                    .filePath(QStringLiteral("notes")));
    engine.rootContext()->setContextProperty(QStringLiteral("notes"), &notes);

    engine.load(QUrl(QStringLiteral("qrc:/Main.qml")));
    if (engine.rootObjects().isEmpty()) {
        qCritical() << "Could not load the Omawrite+ interface; resource available:"
                    << QFile::exists(QStringLiteral(":/Main.qml"));
        return -1;
    }

    backend.setParentWindow(qobject_cast<QWindow *>(engine.rootObjects().constFirst()));

    notes.start();

    return app.exec();
}
