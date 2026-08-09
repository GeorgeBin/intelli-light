#pragma once

#include <QString>

namespace StatePresentation
{
QString agentName(const QString &wireState);
QString lightName(const QString &wireState);
QString iconName(const QString &lightState);
bool needsAttention(const QString &lightState);
}
