#pragma once

#include "models/models.h"
#include <QJsonObject>
#include <QSet>

namespace codextop {

enum class PanelTheme { Dark, Light, System };
enum class PanelPlacement { Top, Floating, Orb, MenuBar };
enum class OrbAppearance { Ring, TwinArc };

namespace MonitorScale {
constexpr double minimum = 0.8, maximum = 1.2, step = 0.05, baseline = 0.75;
double normalized(double value);
double renderingScale(double displayScale);
double displayScale(double renderingScale);
} // namespace MonitorScale

struct MonitorPreferences {
    QSet<QString> selectedIDs, excludedIDs;
    bool initialized = false;
    bool autoMonitor = true;
    QDateTime autoEnabledAt = QDateTime::currentDateTimeUtc();
    int autoEnabledSubmillisecondNanoseconds = 0;
    std::optional<QSet<QString>> autoBaselineIDs;
    std::optional<QString> codexHome, preferredDisplay;
    bool floating = false;
    std::optional<QString> floatingDisplay;
    double floatingX = 0.72, floatingY = 0.7;
    std::optional<PanelTheme> theme;
    std::optional<OrbAppearance> orbAppearance;
    std::optional<PanelPlacement> placement, floatingReturnPlacement;
    std::optional<double> uiScale;
    std::optional<qint64> visibleTaskCount, finishedRetentionDays;
    std::optional<QSet<QString>> automaticallyRemovedIDs, retentionProtectedIDs;
    std::optional<bool> claudeEnabled;
    std::optional<QString> claudeHome;
    std::optional<bool> claudeBaselineApplied;

    bool resolvedClaudeEnabled() const { return claudeEnabled.value_or(true); }
    int resolvedFinishedRetentionDays() const;
    int resolvedVisibleTaskCount() const;
    PanelPlacement resolvedPlacement() const;
    OrbAppearance resolvedOrbAppearance() const { return orbAppearance.value_or(OrbAppearance::Ring); }
    PanelPlacement resolvedUnpinnedPlacement() const;
    double resolvedScale() const;
    double resolvedDisplayScale() const;
    void setPlacement(PanelPlacement value);
    bool operator==(const MonitorPreferences &) const = default;
    QJsonObject toJson() const;
    static MonitorPreferences fromJson(const QJsonObject &json);
};

class PreferencesFile {
  public:
    explicit PreferencesFile(QString path) : path_(std::move(path)) {}
    MonitorPreferences load() const;
    void save(const MonitorPreferences &preferences) const;

  private:
    QString path_;
};

} // namespace codextop
