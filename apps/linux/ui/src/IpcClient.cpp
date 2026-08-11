#include "IpcClient.h"

#include <QDir>
#include <QFileInfo>
#include <QJsonDocument>
#include <QLocalSocket>
#include <QProcessEnvironment>

#include <unistd.h>

IpcClient::IpcClient(QString socketPath)
    : socketPath_(std::move(socketPath))
{
}

IpcClient::Result IpcClient::request(const QJsonObject &requestObject, int timeoutMs) const
{
    QLocalSocket socket;
    socket.connectToServer(socketPath_, QIODevice::ReadWrite);
    if (!socket.waitForConnected(timeoutMs)) {
        return {false, {}, socket.errorString(), true};
    }

    QByteArray payload = QJsonDocument(requestObject).toJson(QJsonDocument::Compact);
    payload.append('\n');
    if (socket.write(payload) != payload.size()
        || (socket.bytesToWrite() > 0 && !socket.waitForBytesWritten(timeoutMs))) {
        return {false, {}, socket.errorString(), true};
    }
    if (!socket.waitForReadyRead(timeoutMs)) {
        return {false, {}, socket.errorString(), true};
    }

    QByteArray response = socket.readLine();
    while (!response.endsWith('\n') && socket.waitForReadyRead(timeoutMs)) {
        response.append(socket.readLine());
    }
    return parseResponse(response);
}

IpcClient::Result IpcClient::parseResponse(const QByteArray &response)
{
    QJsonParseError parseError;
    const QJsonDocument document = QJsonDocument::fromJson(response, &parseError);
    if (parseError.error != QJsonParseError::NoError || !document.isObject()) {
        return {false, {}, parseError.errorString()};
    }
    const QJsonObject object = document.object();
    if (!object.value(QStringLiteral("ok")).toBool()) {
        return {false, object, object.value(QStringLiteral("error")).toString()};
    }
    return {true, object, {}};
}

IpcClient::Result IpcClient::snapshot() const
{
    return request({{QStringLiteral("command"), QStringLiteral("getSnapshot")}});
}

QString IpcClient::defaultSocketPath()
{
    const QString runtime = QProcessEnvironment::systemEnvironment().value(QStringLiteral("XDG_RUNTIME_DIR"));
    if (!runtime.isEmpty()) {
        return QDir(runtime).filePath(QStringLiteral("intelli-light/daemon.sock"));
    }
    return QStringLiteral("/tmp/intelli-light-%1/daemon.sock").arg(geteuid());
}
