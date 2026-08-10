#include "ColorUtils.h"

namespace ColorUtils
{
bool isValidHex(const QString &text)
{
    if (text.size() != 7 || text.at(0) != QLatin1Char('#')) {
        return false;
    }
    for (int index = 1; index < 7; ++index) {
        const QChar character = text.at(index);
        const bool digit = character >= QLatin1Char('0') && character <= QLatin1Char('9');
        const bool lowercase = character >= QLatin1Char('a') && character <= QLatin1Char('f');
        const bool uppercase = character >= QLatin1Char('A') && character <= QLatin1Char('F');
        if (!digit && !lowercase && !uppercase) {
            return false;
        }
    }
    return true;
}

QString normalizeHex(const QString &text)
{
    if (!isValidHex(text)) {
        return {};
    }
    return text.toUpper();
}

QColor colorFromHex(const QString &hex)
{
    return QColor::fromString(normalizeHex(hex));
}

QString hexFromColor(const QColor &color)
{
    return color.isValid() ? color.name(QColor::HexRgb).toUpper() : QString{};
}
}
