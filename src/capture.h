#pragma once

#include <QObject>
#include <QString>

class QLocalServer;
class Notes;

// Quick capture: `omawrite-plus add "idea"` drops a line into the idea jar.
// When the app is open it listens on a socket in the user's runtime folder
// and takes the line itself, so the note on screen gets it as an edit rather
// than having its file changed underneath it. When the app is closed the
// command writes the note's file directly.
namespace Capture {

// The socket the running app listens on.
QString socketPath();

// Hands the line to a running app. False when no app answered.
bool sendToRunningApp(const QString &line);

}

class CaptureServer : public QObject {
    Q_OBJECT

public:
    explicit CaptureServer(Notes *notes, QObject *parent = nullptr);
    bool listen();

private:
    void accept();

    Notes *m_notes;
    QLocalServer *m_server;
};
