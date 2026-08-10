#pragma once

#include <QJsonObject>
#include <QString>

namespace DefaultSettings
{
inline const QString GeorgeLightAddress = QStringLiteral("http://george-light-zero.local");

inline QString georgeLightAddress(const QJsonObject &config)
{
    const QString address = config.value(QStringLiteral("address")).toString().trimmed();
    return address.isEmpty() ? GeorgeLightAddress : address;
}
}
