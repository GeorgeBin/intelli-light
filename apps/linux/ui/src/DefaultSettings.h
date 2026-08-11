#pragma once

#include <QJsonObject>
#include <QString>

namespace DefaultSettings
{
inline const QString GeorgeLightAddress = QStringLiteral("http://george-light-zero.local");
inline constexpr int EffectDurationMinimum = 1;
inline constexpr int EffectDurationMaximum = 300;

inline QString georgeLightAddress(const QJsonObject &config)
{
    const QString address = config.value(QStringLiteral("address")).toString().trimmed();
    return address.isEmpty() ? GeorgeLightAddress : address;
}
}
