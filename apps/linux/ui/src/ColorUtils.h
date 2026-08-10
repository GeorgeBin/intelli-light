#pragma once

#include <QColor>
#include <QString>

namespace ColorUtils
{
bool isValidHex(const QString &text);
QString normalizeHex(const QString &text);
QColor colorFromHex(const QString &hex);
QString hexFromColor(const QColor &color);
}
