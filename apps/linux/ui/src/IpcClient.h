#pragma once

#include <QJsonObject>
#include <QString>

class IpcClient
{
public:
    struct Result {
        bool ok = false;
        QJsonObject response;
        QString error;
        bool transportError = false;
    };

    explicit IpcClient(QString socketPath = defaultSocketPath());

    Result request(const QJsonObject &request, int timeoutMs = 5000) const;
    Result snapshot() const;
    static Result parseResponse(const QByteArray &response);
    static QString defaultSocketPath();

private:
    QString socketPath_;
};
