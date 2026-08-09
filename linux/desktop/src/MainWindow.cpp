#include "MainWindow.h"

#include "DefaultSettings.h"

#include "StatePresentation.h"

#include <KAboutData>
#include <KStatusNotifierItem>

#include <QAction>
#include <QApplication>
#include <QCheckBox>
#include <QCloseEvent>
#include <QComboBox>
#include <QFormLayout>
#include <QGroupBox>
#include <QHBoxLayout>
#include <QJsonArray>
#include <QLabel>
#include <QLineEdit>
#include <QMenu>
#include <QMenuBar>
#include <QMessageBox>
#include <QPushButton>
#include <QSpinBox>
#include <QStatusBar>
#include <QTabWidget>
#include <QTimer>
#include <QVBoxLayout>

MainWindow::MainWindow(QWidget *parent)
    : QMainWindow(parent)
{
    setWindowTitle(QStringLiteral("Intelli Light"));
    setWindowIcon(QIcon(QStringLiteral(":/icons/intelli-light.svg")));
    resize(680, 620);

    auto *tabs = new QTabWidget(this);
    tabs->addTab(createOverviewPage(), tr("Overview"));
    tabs->addTab(createAgentsPage(), tr("Agents"));
    tabs->addTab(createGeorgeLightPage(), tr("GeorgeLight"));
    setCentralWidget(tabs);

    auto *helpMenu = menuBar()->addMenu(tr("&Help"));
    auto *aboutAction = helpMenu->addAction(tr("About Intelli Light"));
    connect(aboutAction, &QAction::triggered, this, [this]() {
        const KAboutData about = KAboutData::applicationData();
        QMessageBox::about(this,
                           about.displayName(),
                           tr("%1\nVersion %2\n\nNative KDE Plasma desktop for agent status.\nLicense: MIT")
                               .arg(about.shortDescription(), about.version()));
    });

    createTray();
    refreshTimer_ = new QTimer(this);
    refreshTimer_->setInterval(750);
    connect(refreshTimer_, &QTimer::timeout, this, &MainWindow::refresh);
    refreshTimer_->start();
    refresh();
}

QWidget *MainWindow::createOverviewPage()
{
    auto *page = new QWidget(this);
    auto *layout = new QFormLayout(page);
    daemonStatus_ = new QLabel(tr("Connecting…"), page);
    globalState_ = new QLabel(tr("Idle"), page);
    codexState_ = new QLabel(tr("Idle"), page);
    claudeState_ = new QLabel(tr("Idle"), page);
    currentSession_ = new QLabel(tr("None"), page);
    currentSession_->setTextInteractionFlags(Qt::TextSelectableByMouse);
    lightConnectivity_ = new QLabel(tr("Unknown"), page);
    layout->addRow(tr("Daemon:"), daemonStatus_);
    layout->addRow(tr("Global AgentState:"), globalState_);
    layout->addRow(tr("Codex:"), codexState_);
    layout->addRow(tr("Claude Code:"), claudeState_);
    layout->addRow(tr("Project / session:"), currentSession_);
    layout->addRow(tr("GeorgeLight:"), lightConnectivity_);
    return page;
}

QWidget *MainWindow::createAgentsPage()
{
    auto *page = new QWidget(this);
    auto *layout = new QVBoxLayout(page);
    layout->addWidget(new QLabel(tr("Enabled agent providers"), page));
    codexEnabled_ = new QCheckBox(tr("Codex"), page);
    claudeEnabled_ = new QCheckBox(tr("Claude Code"), page);
    layout->addWidget(codexEnabled_);
    layout->addWidget(claudeEnabled_);
    auto *note = new QLabel(
        tr("At least one provider must remain enabled. Changes are saved by the Rust daemon and immediately synchronize owned hooks."),
        page);
    note->setWordWrap(true);
    layout->addWidget(note);
    layout->addStretch();
    connect(codexEnabled_, &QCheckBox::clicked, this, &MainWindow::updateProviderConfig);
    connect(claudeEnabled_, &QCheckBox::clicked, this, &MainWindow::updateProviderConfig);
    return page;
}

QWidget *MainWindow::createGeorgeLightPage()
{
    auto *page = new QWidget(this);
    auto *layout = new QVBoxLayout(page);
    lightEnabled_ = new QCheckBox(tr("Enable GeorgeLight output"), page);
    lightAddress_ = new QLineEdit(page);
    lightAddress_->setText(DefaultSettings::GeorgeLightAddress);
    auto *addressLayout = new QFormLayout;
    addressLayout->addRow(tr("Address:"), lightAddress_);
    layout->addWidget(lightEnabled_);
    layout->addLayout(addressLayout);
    layout->addWidget(createEffectEditor(tr("Working effect"), workingEffect_));
    layout->addWidget(createEffectEditor(tr("Action Required effect"), actionEffect_));
    layout->addWidget(createEffectEditor(tr("Error effect"), errorEffect_));
    layout->addWidget(createEffectEditor(tr("Done effect"), doneEffect_));
    auto *save = new QPushButton(tr("Apply GeorgeLight Configuration"), page);
    layout->addWidget(save);
    connect(save, &QPushButton::clicked, this, &MainWindow::updateGeorgeLightConfig);
    connect(lightEnabled_, &QCheckBox::clicked, this, &MainWindow::updateGeorgeLightConfig);
    return page;
}

QGroupBox *MainWindow::createEffectEditor(const QString &title, EffectWidgets &widgets)
{
    auto *group = new QGroupBox(title, this);
    auto *layout = new QHBoxLayout(group);
    widgets.color = new QLineEdit(group);
    widgets.color->setMaximumWidth(100);
    widgets.mode = new QComboBox(group);
    widgets.mode->addItem(tr("Solid"), 1);
    widgets.mode->addItem(tr("Blink"), 2);
    widgets.mode->addItem(tr("Breath"), 3);
    widgets.mode->addItem(tr("Fast Blink"), 4);
    widgets.duration = new QSpinBox(group);
    widgets.duration->setRange(0, 86400);
    widgets.duration->setSuffix(tr(" s"));
    widgets.brightness = new QSpinBox(group);
    widgets.brightness->setRange(0, 100);
    widgets.brightness->setSuffix(QStringLiteral("%"));
    layout->addWidget(new QLabel(tr("Color"), group));
    layout->addWidget(widgets.color);
    layout->addWidget(new QLabel(tr("Mode"), group));
    layout->addWidget(widgets.mode);
    layout->addWidget(new QLabel(tr("Duration"), group));
    layout->addWidget(widgets.duration);
    layout->addWidget(new QLabel(tr("Brightness"), group));
    layout->addWidget(widgets.brightness);
    return group;
}

void MainWindow::createTray()
{
    tray_ = new KStatusNotifierItem(QStringLiteral("intelli-light"), this);
    tray_->setCategory(KStatusNotifierItem::SystemServices);
    tray_->setTitle(QStringLiteral("Intelli Light"));
    tray_->setToolTipTitle(QStringLiteral("Intelli Light"));
    tray_->setIconByPixmap(windowIcon());
    tray_->setStatus(KStatusNotifierItem::Active);
    tray_->setStandardActionsEnabled(false);

    QMenu *menu = tray_->contextMenu();
    trayGlobalState_ = menu->addAction(tr("Global: Idle"));
    trayCodexState_ = menu->addAction(tr("Codex: Idle"));
    trayClaudeState_ = menu->addAction(tr("Claude Code: Idle"));
    trayGlobalState_->setEnabled(false);
    trayCodexState_->setEnabled(false);
    trayClaudeState_->setEnabled(false);
    menu->addSeparator();
    auto *open = menu->addAction(tr("Open Intelli Light"));
    trayLightEnabled_ = menu->addAction(tr("GeorgeLight Enabled"));
    trayLightEnabled_->setCheckable(true);
    menu->addSeparator();
    auto *quit = menu->addAction(tr("Quit Desktop"));
    connect(open, &QAction::triggered, this, [this]() {
        show();
        raise();
        activateWindow();
    });
    connect(trayLightEnabled_, &QAction::toggled, this, [this](bool enabled) {
        if (updating_) {
            return;
        }
        lightEnabled_->setChecked(enabled);
        updateGeorgeLightConfig();
    });
    connect(quit, &QAction::triggered, this, &MainWindow::quitDesktop);
    connect(tray_, &KStatusNotifierItem::activateRequested, this, [this](bool, const QPoint &) {
        toggleWindow();
    });
}

void MainWindow::refresh()
{
    const IpcClient::Result result = ipc_.snapshot();
    if (!result.ok) {
        daemonStatus_->setText(tr("Unavailable: %1").arg(result.error));
        statusBar()->showMessage(tr("Waiting for intelli-light daemon"));
        tray_->setToolTipSubTitle(tr("Daemon unavailable"));
        return;
    }
    daemonStatus_->setText(tr("Connected"));
    statusBar()->clearMessage();
    applySnapshot(result.response.value(QStringLiteral("snapshot")).toObject());
}

void MainWindow::applySnapshot(const QJsonObject &snapshot)
{
    updating_ = true;
    const QString globalWire = snapshot.value(QStringLiteral("globalAgentState")).toString();
    const QString lightWire = snapshot.value(QStringLiteral("lightState")).toString();
    const QJsonObject providers = snapshot.value(QStringLiteral("providerStates")).toObject();
    const QString codexWire = providers.value(QStringLiteral("codex")).toString();
    const QString claudeWire = providers.value(QStringLiteral("claude")).toString();
    globalState_->setText(StatePresentation::agentName(globalWire));
    codexState_->setText(StatePresentation::agentName(codexWire));
    claudeState_->setText(StatePresentation::agentName(claudeWire));

    QString current = tr("None");
    const QString displayKey = snapshot.value(QStringLiteral("displaySession")).toString();
    for (const QJsonValue &value : snapshot.value(QStringLiteral("sessions")).toArray()) {
        const QJsonObject session = value.toObject();
        if (session.value(QStringLiteral("key")).toString() == displayKey) {
            const QString project = session.value(QStringLiteral("project")).toString();
            current = project.isEmpty() ? displayKey : tr("%1 — %2").arg(project, displayKey);
            break;
        }
    }
    currentSession_->setText(current);

    const QJsonArray enabled = snapshot.value(QStringLiteral("enabledProviders")).toArray();
    codexEnabled_->setChecked(enabled.contains(QStringLiteral("codex")));
    claudeEnabled_->setChecked(enabled.contains(QStringLiteral("claude")));

    georgeLightConfig_ = snapshot.value(QStringLiteral("georgeLight")).toObject();
    const bool lightEnabled = georgeLightConfig_.value(QStringLiteral("enabled")).toBool();
    lightEnabled_->setChecked(lightEnabled);
    trayLightEnabled_->setChecked(lightEnabled);
    lightAddress_->setText(DefaultSettings::georgeLightAddress(georgeLightConfig_));
    const QString connectivity = georgeLightConfig_.value(QStringLiteral("connectivity")).toString();
    lightConnectivity_->setText(
        tr("%1 — %2").arg(lightEnabled ? tr("Enabled") : tr("Disabled"), connectivity));
    const QJsonObject effects = georgeLightConfig_.value(QStringLiteral("effects")).toObject();
    setEffectWidgets(workingEffect_, effects.value(QStringLiteral("working")).toObject());
    setEffectWidgets(actionEffect_, effects.value(QStringLiteral("actionRequired")).toObject());
    setEffectWidgets(errorEffect_, effects.value(QStringLiteral("error")).toObject());
    setEffectWidgets(doneEffect_, effects.value(QStringLiteral("done")).toObject());

    trayGlobalState_->setText(tr("Global: %1").arg(StatePresentation::agentName(globalWire)));
    trayCodexState_->setText(tr("Codex: %1").arg(StatePresentation::agentName(codexWire)));
    trayClaudeState_->setText(tr("Claude Code: %1").arg(StatePresentation::agentName(claudeWire)));
    const QString icon = StatePresentation::iconName(lightWire);
    if (icon == QStringLiteral("intelli-light")) {
        tray_->setIconByPixmap(windowIcon());
    } else {
        tray_->setIconByName(icon);
    }
    tray_->setStatus(StatePresentation::needsAttention(lightWire) ? KStatusNotifierItem::NeedsAttention
                                                                  : KStatusNotifierItem::Active);
    tray_->setToolTipIconByName(icon);
    tray_->setToolTipSubTitle(StatePresentation::lightName(lightWire));
    updating_ = false;
}

void MainWindow::updateProviderConfig()
{
    if (updating_) {
        return;
    }
    if (!codexEnabled_->isChecked() && !claudeEnabled_->isChecked()) {
        updating_ = true;
        qobject_cast<QCheckBox *>(sender())->setChecked(true);
        updating_ = false;
        QMessageBox::information(this, tr("Agent Providers"), tr("At least one provider must remain enabled."));
        return;
    }
    QJsonArray providers;
    if (codexEnabled_->isChecked()) {
        providers.append(QStringLiteral("codex"));
    }
    if (claudeEnabled_->isChecked()) {
        providers.append(QStringLiteral("claude"));
    }
    const IpcClient::Result result = ipc_.request({
        {QStringLiteral("command"), QStringLiteral("setProviders")},
        {QStringLiteral("providers"), providers},
    });
    if (!result.ok) {
        showIpcError(result.error);
    }
    refresh();
}

void MainWindow::updateGeorgeLightConfig()
{
    if (updating_) {
        return;
    }
    QJsonObject effects;
    effects.insert(QStringLiteral("working"), effectFromWidgets(workingEffect_));
    effects.insert(QStringLiteral("actionRequired"), effectFromWidgets(actionEffect_));
    effects.insert(QStringLiteral("error"), effectFromWidgets(errorEffect_));
    effects.insert(QStringLiteral("done"), effectFromWidgets(doneEffect_));
    QJsonObject config{
        {QStringLiteral("enabled"), lightEnabled_->isChecked()},
        {QStringLiteral("address"), lightAddress_->text().trimmed()},
        {QStringLiteral("effects"), effects},
    };
    const IpcClient::Result result = ipc_.request({
        {QStringLiteral("command"), QStringLiteral("setGeorgeLight")},
        {QStringLiteral("georgeLight"), config},
    });
    if (!result.ok) {
        showIpcError(result.error);
    }
    refresh();
}

void MainWindow::showIpcError(const QString &message)
{
    QMessageBox::warning(this, tr("Intelli Light daemon"), message);
}

void MainWindow::toggleWindow()
{
    if (isVisible()) {
        hide();
    } else {
        show();
        raise();
        activateWindow();
    }
}

void MainWindow::quitDesktop()
{
    quitting_ = true;
    qApp->quit();
}

QJsonObject MainWindow::effectFromWidgets(const EffectWidgets &widgets) const
{
    return {
        {QStringLiteral("color"), widgets.color->text().trimmed()},
        {QStringLiteral("modeId"), widgets.mode->currentData().toInt()},
        {QStringLiteral("durationSec"), widgets.duration->value()},
        {QStringLiteral("brightness"), widgets.brightness->value()},
    };
}

void MainWindow::setEffectWidgets(EffectWidgets &widgets, const QJsonObject &effect)
{
    widgets.color->setText(effect.value(QStringLiteral("color")).toString());
    const int modeIndex = widgets.mode->findData(effect.value(QStringLiteral("modeId")).toInt());
    if (modeIndex >= 0) {
        widgets.mode->setCurrentIndex(modeIndex);
    }
    widgets.duration->setValue(effect.value(QStringLiteral("durationSec")).toInt());
    widgets.brightness->setValue(effect.value(QStringLiteral("brightness")).toInt());
}

void MainWindow::closeEvent(QCloseEvent *event)
{
    if (quitting_) {
        QMainWindow::closeEvent(event);
        return;
    }
    hide();
    event->ignore();
}
