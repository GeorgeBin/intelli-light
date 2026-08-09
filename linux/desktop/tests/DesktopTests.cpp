#include "IpcClient.h"
#include "StatePresentation.h"

#include <QJsonArray>
#include <QJsonDocument>
#include <QTest>

class DesktopTests : public QObject
{
    Q_OBJECT

private Q_SLOTS:
    void waitingStatesRemainDistinct();
    void lightStatesMapToNativePresentation();
    void providerAndGeorgeLightCommandsSerialize();
    void ipcResponseSerialization();
};

void DesktopTests::waitingStatesRemainDistinct()
{
    QCOMPARE(StatePresentation::agentName(QStringLiteral("waitingApproval")), QStringLiteral("Waiting Approval"));
    QCOMPARE(StatePresentation::agentName(QStringLiteral("waitingInput")), QStringLiteral("Waiting Input"));
    QCOMPARE(StatePresentation::agentName(QStringLiteral("waitingImplementation")),
             QStringLiteral("Waiting Implementation"));
}

void DesktopTests::lightStatesMapToNativePresentation()
{
    QCOMPARE(StatePresentation::lightName(QStringLiteral("working")), QStringLiteral("Working"));
    QCOMPARE(StatePresentation::lightName(QStringLiteral("actionRequired")), QStringLiteral("Action Required"));
    QCOMPARE(StatePresentation::lightName(QStringLiteral("error")), QStringLiteral("Error"));
    QCOMPARE(StatePresentation::lightName(QStringLiteral("done")), QStringLiteral("Done"));
    QCOMPARE(StatePresentation::lightName(QStringLiteral("idle")), QStringLiteral("Idle"));
    QVERIFY(StatePresentation::needsAttention(QStringLiteral("actionRequired")));
    QVERIFY(!StatePresentation::needsAttention(QStringLiteral("working")));
}

void DesktopTests::providerAndGeorgeLightCommandsSerialize()
{
    const QJsonObject providers{
        {QStringLiteral("command"), QStringLiteral("setProviders")},
        {QStringLiteral("providers"), QJsonArray{QStringLiteral("codex"), QStringLiteral("claude")}},
    };
    const QJsonDocument providerDocument(providers);
    QCOMPARE(QJsonDocument::fromJson(providerDocument.toJson(QJsonDocument::Compact)).object(), providers);

    const QJsonObject effect{
        {QStringLiteral("color"), QStringLiteral("#4D8FFF")},
        {QStringLiteral("modeId"), 3},
        {QStringLiteral("durationSec"), 300},
        {QStringLiteral("brightness"), 70},
    };
    const QJsonObject light{
        {QStringLiteral("command"), QStringLiteral("setGeorgeLight")},
        {QStringLiteral("georgeLight"),
         QJsonObject{
             {QStringLiteral("enabled"), true},
             {QStringLiteral("address"), QStringLiteral("http://lamp.local")},
             {QStringLiteral("effects"), QJsonObject{{QStringLiteral("working"), effect}}},
         }},
    };
    QCOMPARE(QJsonDocument::fromJson(QJsonDocument(light).toJson(QJsonDocument::Compact)).object(), light);
}

void DesktopTests::ipcResponseSerialization()
{
    const IpcClient::Result result = IpcClient::parseResponse(
        QByteArrayLiteral("{\"ok\":true,\"snapshot\":{\"lightState\":\"working\"}}\n"));
    QVERIFY2(result.ok, qPrintable(result.error));
    QCOMPARE(result.response.value(QStringLiteral("snapshot")).toObject().value(QStringLiteral("lightState")).toString(),
             QStringLiteral("working"));
    const IpcClient::Result error =
        IpcClient::parseResponse(QByteArrayLiteral("{\"ok\":false,\"error\":\"invalid config\"}\n"));
    QVERIFY(!error.ok);
    QCOMPARE(error.error, QStringLiteral("invalid config"));
}

QTEST_MAIN(DesktopTests)
#include "DesktopTests.moc"
