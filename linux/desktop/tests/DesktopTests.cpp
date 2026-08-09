#include "ColorEditWidget.h"
#include "ColorUtils.h"
#include "DefaultSettings.h"
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
    void georgeLightAddressDefaultsAndOverrides();
    void hexValidationAndNormalization();
    void colorConversionsRoundTrip();
    void effectJsonKeepsStandardRgbHex();
    void colorEditWidgetSyncsSwatchAndNormalizes();
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

void DesktopTests::georgeLightAddressDefaultsAndOverrides()
{
    QCOMPARE(DefaultSettings::georgeLightAddress({}), QStringLiteral("http://george-light-zero.local"));
    QCOMPARE(DefaultSettings::georgeLightAddress({{QStringLiteral("address"), QStringLiteral("  ")}}),
             QStringLiteral("http://george-light-zero.local"));
    QCOMPARE(DefaultSettings::georgeLightAddress(
                 {{QStringLiteral("address"), QStringLiteral("http://light.example:8080")}}),
             QStringLiteral("http://light.example:8080"));
}

void DesktopTests::hexValidationAndNormalization()
{
    QVERIFY(ColorUtils::isValidHex(QStringLiteral("#4D8FFF")));
    QVERIFY(ColorUtils::isValidHex(QStringLiteral("#4d8fff")));
    QVERIFY(!ColorUtils::isValidHex(QStringLiteral("#4D8FF")));    // too short
    QVERIFY(!ColorUtils::isValidHex(QStringLiteral("4D8FFF")));    // missing '#'
    QVERIFY(!ColorUtils::isValidHex(QStringLiteral("#4D8FFG")));   // non-hex digit
    QVERIFY(!ColorUtils::isValidHex(QStringLiteral("#4D8FFFF")));  // too long
    QVERIFY(!ColorUtils::isValidHex(QStringLiteral("#4D8F")));     // too short
    QVERIFY(!ColorUtils::isValidHex(QString()));

    // Lowercase input is normalized to the uppercase #RRGGBB form saved to disk.
    QCOMPARE(ColorUtils::normalizeHex(QStringLiteral("#4d8fff")), QStringLiteral("#4D8FFF"));
    QCOMPARE(ColorUtils::normalizeHex(QStringLiteral("#4D8FFF")), QStringLiteral("#4D8FFF"));
    QCOMPARE(ColorUtils::normalizeHex(QStringLiteral("#zzzzzz")), QString());
    // The utility is strict about whitespace; the widget trims before calling it.
    QCOMPARE(ColorUtils::normalizeHex(QStringLiteral("  #4D8FFF  ")), QString());
}

void DesktopTests::colorConversionsRoundTrip()
{
    // HEX -> QColor, which backs the swatch synchronization.
    const QColor color = ColorUtils::colorFromHex(QStringLiteral("#4D8FFF"));
    QVERIFY(color.isValid());
    QCOMPARE(color.red(), 0x4D);
    QCOMPARE(color.green(), 0x8F);
    QCOMPARE(color.blue(), 0xFF);
    QCOMPARE(ColorUtils::hexFromColor(color), QStringLiteral("#4D8FFF"));

    // QColor -> HEX round-trips through lowercase input to standard uppercase.
    QCOMPARE(ColorUtils::hexFromColor(ColorUtils::colorFromHex(QStringLiteral("#4d8fff"))),
             QStringLiteral("#4D8FFF"));

    // Invalid input yields an invalid QColor, which the swatch renders as invalid.
    QVERIFY(!ColorUtils::colorFromHex(QStringLiteral("nope")).isValid());
    QVERIFY(!ColorUtils::colorFromHex(QStringLiteral("#4D8FF")).isValid());
    QCOMPARE(ColorUtils::hexFromColor(QColor{}), QString());
}

void DesktopTests::effectJsonKeepsStandardRgbHex()
{
    // The Desktop normalizes the raw line-edit text to #RRGGBB before the effect
    // leaves the UI, so the daemon always receives the canonical form.
    const QString raw = QStringLiteral("#4d8fff");
    const QJsonObject effect{
        {QStringLiteral("color"), ColorUtils::normalizeHex(raw)},
        {QStringLiteral("modeId"), 3},
        {QStringLiteral("durationSec"), 300},
        {QStringLiteral("brightness"), 70},
    };
    const QJsonObject parsed =
        QJsonDocument::fromJson(QJsonDocument(effect).toJson(QJsonDocument::Compact)).object();
    QCOMPARE(parsed.value(QStringLiteral("color")).toString(), QStringLiteral("#4D8FFF"));
    QCOMPARE(parsed.value(QStringLiteral("modeId")).toInt(), 3);
    QCOMPARE(parsed.value(QStringLiteral("durationSec")).toInt(), 300);
    QCOMPARE(parsed.value(QStringLiteral("brightness")).toInt(), 70);
}

void DesktopTests::colorEditWidgetSyncsSwatchAndNormalizes()
{
    ColorEditWidget editor;
    QVERIFY(!editor.isValid());
    QCOMPARE(editor.hex(), QString());

    // A snapshot value lands on the widget, becomes valid, and is normalized.
    editor.setHex(QStringLiteral("#4d8fff"));
    QVERIFY(editor.isValid());
    QCOMPARE(editor.hex(), QStringLiteral("#4D8FFF"));

    // Invalid input never produces a value that could be sent to the daemon.
    editor.setHex(QStringLiteral("#zzzzzz"));
    QVERIFY(!editor.isValid());
    QCOMPARE(editor.hex(), QString());
}

QTEST_MAIN(DesktopTests)
#include "DesktopTests.moc"
