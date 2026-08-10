#pragma once

#include "IpcClient.h"

#include <QJsonObject>
#include <QMainWindow>

class QAction;
class QCheckBox;
class QCloseEvent;
class QComboBox;
class QGroupBox;
class QLabel;
class QLineEdit;
class QPushButton;
class QSpinBox;
class QTimer;
class ColorEditWidget;
class KStatusNotifierItem;

class MainWindow : public QMainWindow
{
    Q_OBJECT

public:
    explicit MainWindow(QWidget *parent = nullptr);

protected:
    void closeEvent(QCloseEvent *event) override;

private:
    struct EffectWidgets {
        ColorEditWidget *color = nullptr;
        QComboBox *mode = nullptr;
        QSpinBox *duration = nullptr;
        QSpinBox *brightness = nullptr;
    };

    QWidget *createOverviewPage();
    QWidget *createAgentsPage();
    QWidget *createGeorgeLightPage();
    QGroupBox *createEffectEditor(const QString &title, EffectWidgets &widgets);
    void createTray();
    void refresh();
    void applySnapshot(const QJsonObject &snapshot);
    void updateProviderConfig();
    void updateGeorgeLightConfig();
    void showIpcError(const QString &message);
    void toggleWindow();
    void quitDesktop();
    QJsonObject effectFromWidgets(const EffectWidgets &widgets) const;
    void setEffectWidgets(EffectWidgets &widgets, const QJsonObject &effect);

    IpcClient ipc_;
    QTimer *refreshTimer_ = nullptr;
    KStatusNotifierItem *tray_ = nullptr;
    bool updating_ = false;
    bool quitting_ = false;
    QJsonObject georgeLightConfig_;

    QLabel *daemonStatus_ = nullptr;
    QLabel *globalState_ = nullptr;
    QLabel *codexState_ = nullptr;
    QLabel *claudeState_ = nullptr;
    QLabel *currentSession_ = nullptr;
    QLabel *lightConnectivity_ = nullptr;
    QCheckBox *codexEnabled_ = nullptr;
    QCheckBox *claudeEnabled_ = nullptr;
    QCheckBox *lightEnabled_ = nullptr;
    QLineEdit *lightAddress_ = nullptr;
    EffectWidgets workingEffect_;
    EffectWidgets actionEffect_;
    EffectWidgets errorEffect_;
    EffectWidgets doneEffect_;
    QAction *trayGlobalState_ = nullptr;
    QAction *trayCodexState_ = nullptr;
    QAction *trayClaudeState_ = nullptr;
    QAction *trayLightEnabled_ = nullptr;
};
