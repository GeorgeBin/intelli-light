#pragma once

#include <QWidget>

class QLabel;
class QLineEdit;
class QPushButton;

// Compact `[swatch] [#RRGGBB] [Choose…]` editor backed by Qt6's native
// QColorDialog. The dialog is only a convenience: the HEX line edit remains the
// source of truth and every value is validated before it leaves this widget.
class ColorEditWidget : public QWidget
{
    Q_OBJECT

public:
    explicit ColorEditWidget(QWidget *parent = nullptr);

    QString text() const;
    // Normalized uppercase #RRGGBB, or empty when the current text is invalid.
    QString hex() const;
    bool isValid() const;
    void setHex(const QString &hex);

private:
    void refreshSwatch();
    void chooseColor();

    QLabel *swatch_ = nullptr;
    QLineEdit *hexEdit_ = nullptr;
    QPushButton *choose_ = nullptr;
    QString lastValidHex_;
};
