#include "StatePresentation.h"

QString StatePresentation::agentName(const QString &wireState)
{
    if (wireState == QStringLiteral("waitingApproval")) {
        return QStringLiteral("Waiting Approval");
    }
    if (wireState == QStringLiteral("waitingInput")) {
        return QStringLiteral("Waiting Input");
    }
    if (wireState == QStringLiteral("waitingImplementation")) {
        return QStringLiteral("Waiting Implementation");
    }
    if (wireState == QStringLiteral("working")) {
        return QStringLiteral("Working");
    }
    if (wireState == QStringLiteral("error")) {
        return QStringLiteral("Error");
    }
    if (wireState == QStringLiteral("done")) {
        return QStringLiteral("Done");
    }
    return QStringLiteral("Idle");
}

QString StatePresentation::lightName(const QString &wireState)
{
    if (wireState == QStringLiteral("actionRequired")) {
        return QStringLiteral("Action Required");
    }
    return agentName(wireState);
}

QString StatePresentation::iconName(const QString &lightState)
{
    if (lightState == QStringLiteral("working")) {
        return QStringLiteral("media-playback-start");
    }
    if (lightState == QStringLiteral("actionRequired")) {
        return QStringLiteral("dialog-warning");
    }
    if (lightState == QStringLiteral("error")) {
        return QStringLiteral("dialog-error");
    }
    if (lightState == QStringLiteral("done")) {
        return QStringLiteral("emblem-default");
    }
    return QStringLiteral("intelli-light");
}

bool StatePresentation::needsAttention(const QString &lightState)
{
    return lightState == QStringLiteral("actionRequired") || lightState == QStringLiteral("error");
}
