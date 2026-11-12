#include "capture.h"

#include "notes.h"

#include <QDir>
#include <QLocalServer>
#include <QLocalSocket>
#include <QStandardPaths>

namespace {
// One request per connection: "add <text>\n", answered with "ok\n".
const QByteArray addCommand = QByteArrayLiteral("add ");
constexpr int timeoutMs = 2000;
}

QString Capture::socketPath() {
    QString runtime = QStandardPaths::writableLocation(QStandardPaths::RuntimeLocation);
    if (runtime.isEmpty())
        runtime = QDir::tempPath();
    return QDir(runtime).filePath(QStringLiteral("omawrite-plus.sock"));
}

bool Capture::sendToRunningApp(const QString &line) {
    QLocalSocket socket;
    socket.connectToServer(socketPath());
    if (!socket.waitForConnected(timeoutMs))
        return false;
    QString flat = line;
    flat.replace(QLatin1Char('\n'), QLatin1Char(' '));
    socket.write(addCommand + flat.toUtf8() + '\n');
    if (!socket.waitForBytesWritten(timeoutMs))
        return false;
    while (!socket.canReadLine()) {
        if (!socket.waitForReadyRead(timeoutMs))
            return false;
    }
    return socket.readLine().trimmed() == "ok";
}

CaptureServer::CaptureServer(Notes *notes, QObject *parent)
    : QObject(parent), m_notes(notes), m_server(new QLocalServer(this)) {
    m_server->setSocketOptions(QLocalServer::UserAccessOption);
    connect(m_server, &QLocalServer::newConnection, this, &CaptureServer::accept);
}

bool CaptureServer::listen() {
    const QString path = Capture::socketPath();
    // A socket left behind by a crash would block listening. One that still
    // answers belongs to another open window, which keeps taking captures.
    QLocalSocket probe;
    probe.connectToServer(path);
    if (probe.waitForConnected(200))
        return false;
    QLocalServer::removeServer(path);
    return m_server->listen(path);
}

void CaptureServer::accept() {
    while (QLocalSocket *socket = m_server->nextPendingConnection()) {
        connect(socket, &QLocalSocket::disconnected, socket, &QObject::deleteLater);
        connect(socket, &QLocalSocket::readyRead, this, [this, socket]() {
            if (!socket->canReadLine())
                return;
            const QByteArray request = socket->readLine();
            bool ok = false;
            if (request.startsWith(addCommand)) {
                const QString line = QString::fromUtf8(request.mid(addCommand.size())).trimmed();
                ok = !line.isEmpty() && !m_notes->addToJar(line).isEmpty();
            }
            socket->write(ok ? "ok\n" : "error\n");
            socket->flush();
            socket->disconnectFromServer();
        });
    }
}
