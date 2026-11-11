#include "monitor_preferences.h"
#include "models/task_roots.h"
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QSaveFile>
#include <algorithm>
#include <cmath>
#include <stdexcept>

namespace codextop {
namespace MonitorScale {
double normalized(double value) {
    if (!std::isfinite(value))
        return 1;
    const double ticks = 1 / step;
    return std::clamp(std::round(std::clamp(value, minimum, maximum) * ticks) / ticks, minimum, maximum);
}
double renderingScale(double value) { return baseline * normalized(value); }
double displayScale(double value) { return std::isfinite(value) ? normalized(value / baseline) : 1; }
} // namespace MonitorScale

int MonitorPreferences::resolvedFinishedRetentionDays() const {
    const auto d = finishedRetentionDays.value_or(7);
    return d == 0 || d == 3 || d == 7 || d == 14 || d == 30 ? int(d) : 7;
}
int MonitorPreferences::resolvedVisibleTaskCount() const {
    return int(std::clamp<qint64>(visibleTaskCount.value_or(4), 1, 12));
}
PanelPlacement MonitorPreferences::resolvedPlacement() const {
    return placement.value_or(floating ? PanelPlacement::Floating : PanelPlacement::Top);
}
PanelPlacement MonitorPreferences::resolvedUnpinnedPlacement() const {
    const auto origin = floatingReturnPlacement.value_or(PanelPlacement::Top);
    return origin == PanelPlacement::Floating ? PanelPlacement::Top : origin;
}
double MonitorPreferences::resolvedDisplayScale() const {
    return MonitorScale::displayScale(uiScale.value_or(MonitorScale::baseline));
}
double MonitorPreferences::resolvedScale() const {
    return MonitorScale::renderingScale(resolvedDisplayScale());
}
void MonitorPreferences::setPlacement(PanelPlacement value) {
    if (value == PanelPlacement::Floating && resolvedPlacement() != PanelPlacement::Floating)
        floatingReturnPlacement = resolvedPlacement();
    placement = value;
    floating = value == PanelPlacement::Floating;
}

namespace {
[[noreturn]] void invalid() { throw std::runtime_error("Invalid monitor preferences"); }
QJsonValue encode(const QSet<QString> &set) {
    auto ordered = set.values();
    ordered.sort();
    return QJsonArray::fromStringList(ordered);
}
QJsonValue encode(double value) {
    if (!std::isfinite(value))
        invalid();
    return value;
}
QJsonValue encode(PanelTheme theme) {
    switch (theme) {
    case PanelTheme::Dark:
        return "dark";
    case PanelTheme::Light:
        return "light";
    case PanelTheme::System:
        return "system";
    }
    invalid();
}
QJsonValue encode(PanelPlacement placement) {
    switch (placement) {
    case PanelPlacement::Top:
        return "top";
    case PanelPlacement::Floating:
        return "floating";
    case PanelPlacement::Orb:
        return "orb";
    case PanelPlacement::MenuBar:
        return "menuBar";
    }
    invalid();
}
QJsonValue encode(OrbAppearance appearance) { return appearance == OrbAppearance::Ring ? "ring" : "twinArc"; }
QJsonValue encode(const QString &value) { return value; }
QJsonValue encode(bool value) { return value; }
QJsonValue encode(qint64 value) { return value; }
void decode(const QJsonValue &value, QString &out) {
    if (!value.isString())
        invalid();
    out = value.toString();
}
void decode(const QJsonValue &value, bool &out) {
    if (!value.isBool())
        invalid();
    out = value.toBool();
}
void decode(const QJsonValue &value, double &out) {
    if (!value.isDouble() || !std::isfinite(value.toDouble()))
        invalid();
    out = value.toDouble();
}
void decode(const QJsonValue &value, qint64 &out) {
    if (!value.isDouble())
        invalid();
    // toInteger returns its fallback for non-integral or out-of-range values.
    const auto a = value.toInteger(0), b = value.toInteger(1);
    if (a != b)
        invalid();
    out = a;
}
void decode(const QJsonValue &value, QSet<QString> &out) {
    if (!value.isArray())
        invalid();
    for (const auto &item : value.toArray()) {
        QString text;
        decode(item, text);
        out.insert(taskIDKey(text));
    }
}
void decode(const QJsonValue &value, PanelPlacement &out) {
    for (auto option :
         {PanelPlacement::Top, PanelPlacement::Floating, PanelPlacement::Orb, PanelPlacement::MenuBar}) {
        if (encode(option) == value) {
            out = option;
            return;
        }
    }
    invalid();
}
void decode(const QJsonValue &value, PanelTheme &out) {
    for (auto option : {PanelTheme::Dark, PanelTheme::Light, PanelTheme::System}) {
        if (encode(option) == value) {
            out = option;
            return;
        }
    }
    invalid();
}
void decode(const QJsonValue &value, OrbAppearance &out) {
    QString raw;
    decode(value, raw);
    out = (raw == "robot" || raw == "twinArc") ? OrbAppearance::TwinArc : OrbAppearance::Ring;
}
template <typename T> void read(const QJsonObject &json, const char *key, T &out) {
    decode(json.value(key), out);
}
template <typename T> void read(const QJsonObject &json, const char *key, std::optional<T> &out) {
    const auto value = json.value(key);
    if (!value.isUndefined() && !value.isNull())
        decode(value, out.emplace());
}
template <typename T> void write(QJsonObject &json, const char *key, const T &value) {
    json.insert(key, encode(value));
}
template <typename T> void write(QJsonObject &json, const char *key, const std::optional<T> &value) {
    if (value)
        write(json, key, *value);
}

// 对照 Swift Codable 的字段名；可选字段缺失时不落盘，旧版保留原有默认值。
template <typename P, typename Visitor> void fields(P &p, Visitor visit) {
    visit("selectedIDs", p.selectedIDs);
    visit("excludedIDs", p.excludedIDs);
    visit("initialized", p.initialized);
    visit("autoMonitor", p.autoMonitor);
    visit("autoBaselineIDs", p.autoBaselineIDs);
    visit("codexHome", p.codexHome);
    visit("preferredDisplay", p.preferredDisplay);
    visit("floating", p.floating);
    visit("floatingDisplay", p.floatingDisplay);
    visit("floatingX", p.floatingX);
    visit("floatingY", p.floatingY);
    visit("theme", p.theme);
    visit("orbAppearance", p.orbAppearance);
    visit("placement", p.placement);
    visit("floatingReturnPlacement", p.floatingReturnPlacement);
    visit("uiScale", p.uiScale);
    visit("visibleTaskCount", p.visibleTaskCount);
    visit("finishedRetentionDays", p.finishedRetentionDays);
    visit("automaticallyRemovedIDs", p.automaticallyRemovedIDs);
    visit("retentionProtectedIDs", p.retentionProtectedIDs);
    visit("claudeEnabled", p.claudeEnabled);
    visit("claudeHome", p.claudeHome);
    visit("claudeBaselineApplied", p.claudeBaselineApplied);
}
} // namespace

QJsonObject MonitorPreferences::toJson() const {
    QJsonObject json;
    if (!autoEnabledAt.isValid())
        invalid();
    json.insert("autoEnabledAt",
                PreciseTimestamp{autoEnabledAt, autoEnabledSubmillisecondNanoseconds}.referenceSeconds());
    fields(*this, [&](const char *key, const auto &value) { write(json, key, value); });
    return json;
}
MonitorPreferences MonitorPreferences::fromJson(const QJsonObject &json) {
    MonitorPreferences p;
    fields(p, [&](const char *key, auto &value) { read(json, key, value); });
    double referenceSeconds;
    read(json, "autoEnabledAt", referenceSeconds);
    const auto stamp = PreciseTimestamp::fromReferenceSeconds(referenceSeconds);
    if (!stamp)
        invalid();
    p.autoEnabledAt = stamp->date;
    p.autoEnabledSubmillisecondNanoseconds = stamp->submillisecondNanoseconds;
    return p;
}

MonitorPreferences PreferencesFile::load() const {
    QFile file(path_);
    if (!file.exists())
        return {};
    if (!file.open(QIODevice::ReadOnly))
        throw std::runtime_error(file.errorString().toStdString());
    const auto bytes = file.readAll();
    if (file.error() != QFileDevice::NoError)
        throw std::runtime_error(file.errorString().toStdString());
    QJsonParseError error;
    const auto doc = QJsonDocument::fromJson(bytes, &error);
    if (!doc.isObject() || error.error != QJsonParseError::NoError)
        invalid();
    return MonitorPreferences::fromJson(doc.object());
}
void PreferencesFile::save(const MonitorPreferences &preferences) const {
    const auto bytes = QJsonDocument(preferences.toJson()).toJson(QJsonDocument::Indented);
    if (!QDir().mkpath(QFileInfo(path_).absolutePath()))
        throw std::runtime_error("Cannot create preferences directory");
    QSaveFile file(path_);
    if (!file.open(QIODevice::WriteOnly) ||
        !file.setPermissions(QFileDevice::ReadOwner | QFileDevice::WriteOwner) ||
        file.write(bytes) != bytes.size() || !file.commit())
        throw std::runtime_error(file.errorString().toStdString());
}
} // namespace codextop
