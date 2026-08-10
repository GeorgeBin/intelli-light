#include "ColorEditWidget.h"

#include "ColorUtils.h"

#include <QColorDialog>
#include <QHBoxLayout>
#include <QLabel>
#include <QLineEdit>
#include <QPushButton>

ColorEditWidget::ColorEditWidget(QWidget *parent)
    : QWidget(parent)
{
    auto *layout = new QHBoxLayout(this);
    layout->setContentsMargins(0, 0, 0, 0);
    layout->setSpacing(6);

    swatch_ = new QLabel(this);
    swatch_->setFixedSize(20, 20);

    hexEdit_ = new QLineEdit(this);
    hexEdit_->setMaxLength(7);
    hexEdit_->setMaximumWidth(90);

    choose_ = new QPushButton(tr("Choose…"), this);

    layout->addWidget(swatch_);
    layout->addWidget(hexEdit_);
    layout->addWidget(choose_);

    connect(hexEdit_, &QLineEdit::textEdited, this, [this]() { refreshSwatch(); });
    connect(choose_, &QPushButton::clicked, this, &ColorEditWidget::chooseColor);
    refreshSwatch();
}

QString ColorEditWidget::text() const
{
    return hexEdit_->text();
}

QString ColorEditWidget::hex() const
{
    return ColorUtils::normalizeHex(hexEdit_->text().trimmed());
}

bool ColorEditWidget::isValid() const
{
    return !hex().isEmpty();
}

void ColorEditWidget::setHex(const QString &hex)
{
    hexEdit_->setText(hex);
    refreshSwatch();
}

void ColorEditWidget::refreshSwatch()
{
    const QString value = hex();
    if (!value.isEmpty()) {
        lastValidHex_ = value;
        swatch_->setStyleSheet(QStringLiteral("background-color: %1; border: 1px solid gray;").arg(value));
        swatch_->setToolTip(value);
        return;
    }
    swatch_->setStyleSheet(QStringLiteral("background-color: #FFFFFF; border: 1px solid #C00;"));
    swatch_->setToolTip(tr("Invalid #RRGGBB color"));
}

void ColorEditWidget::chooseColor()
{
    // Start from the current value when valid, otherwise the last valid color
    // this effect had. QColorDialog::getColor returns an invalid color on cancel,
    // in which case nothing is changed.
    const QColor initial = ColorUtils::colorFromHex(isValid() ? hex() : lastValidHex_);
    const QColor chosen = QColorDialog::getColor(initial, this, tr("Choose Color"));
    if (!chosen.isValid()) {
        return;
    }
    hexEdit_->setText(ColorUtils::hexFromColor(chosen));
    refreshSwatch();
}
