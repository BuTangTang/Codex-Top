#include "policy/monitor_preferences.h"
#include <QtTest>
#include <QTemporaryDir>
#include <cmath>
#include <limits>

using namespace codextop;
using Mode = PanelPlacement;
namespace {
const QList<Mode> modes{Mode::Top, Mode::Floating, Mode::Orb, Mode::MenuBar};
MonitorPreferences roundTrip(const MonitorPreferences &prefs) {
    return MonitorPreferences::fromJson(
        QJsonDocument::fromJson(QJsonDocument(prefs.toJson()).toJson()).object());
}
} // namespace
class PreferencesTests : public QObject {
    Q_OBJECT
  private slots:
    void testUnpinReturnsToEveryOriginAfterSavingAndReloadingPreferences() {
        for (auto origin : {Mode::Top, Mode::Orb, Mode::MenuBar}) {
            MonitorPreferences p;
            p.selectedIDs = {"selected"};
            p.excludedIDs = {"excluded"};
            p.setPlacement(origin);
            p.setPlacement(Mode::Floating);
            QCOMPARE(p.resolvedPlacement(), Mode::Floating);
            QVERIFY(p.floating);
            auto restored = roundTrip(p);
            QCOMPARE(restored.resolvedUnpinnedPlacement(), origin);
            restored.setPlacement(restored.resolvedUnpinnedPlacement());
            QCOMPARE(restored.resolvedPlacement(), origin);
            QVERIFY(!restored.floating);
            QCOMPARE(restored.selectedIDs, QSet<QString>{"selected"});
            QCOMPARE(restored.excludedIDs, QSet<QString>{"excluded"});
        }
    }
    void testRepeatedPinPreservesOriginAndNextPinRemembersNewMode() {
        MonitorPreferences p;
        p.setPlacement(Mode::Orb);
        p.setPlacement(Mode::Floating);
        p.setPlacement(Mode::Floating);
        QCOMPARE(p.resolvedUnpinnedPlacement(), Mode::Orb);
        p.setPlacement(Mode::MenuBar);
        QCOMPARE(p.resolvedPlacement(), Mode::MenuBar);
        p.setPlacement(Mode::Floating);
        QCOMPARE(p.resolvedUnpinnedPlacement(), Mode::MenuBar);
        p.setPlacement(p.resolvedUnpinnedPlacement());
        QCOMPARE(p.resolvedPlacement(), Mode::MenuBar);
    }
    void testOlderPreferencesAndFloatingReturnTargetFallBackToTop() {
        MonitorPreferences p;
        p.floating = true;
        QVERIFY(!p.toJson().contains("floatingReturnPlacement"));
        auto restored = roundTrip(p);
        QCOMPARE(restored.resolvedPlacement(), Mode::Floating);
        QCOMPARE(restored.resolvedUnpinnedPlacement(), Mode::Top);
        restored.floatingReturnPlacement = Mode::Floating;
        QCOMPARE(restored.resolvedUnpinnedPlacement(), Mode::Top);
    }
    void testOlderPreferencesKeepFourVisibleRowsWithoutMigration() {
        MonitorPreferences p;
        QVERIFY(!p.toJson().contains("visibleTaskCount"));
        QCOMPARE(roundTrip(p).resolvedVisibleTaskCount(), 4);
    }
    void testVisibleRowPreferenceSurvivesModeChangesAndClampsInvalidSavedValues() {
        const QList<std::pair<qint64, int>> cases{
            {std::numeric_limits<qint64>::min(), 1}, {0, 1}, {1, 1}, {6, 6}, {12, 12},
            {std::numeric_limits<qint64>::max(), 12}};
        for (const auto &[saved, expected] : cases) {
            MonitorPreferences p;
            p.visibleTaskCount = saved;
            for (auto mode : modes) {
                p.setPlacement(mode);
                QCOMPARE(roundTrip(p).resolvedVisibleTaskCount(), expected);
            }
        }
    }
    void testScaleDefaultsAndBounds() {
        using namespace MonitorScale;
        QCOMPARE(minimum, 0.8);
        QCOMPARE(maximum, 1.2);
        QCOMPARE(step, 0.05);
        for (double v : {qQNaN(), qInf(), -qInf()})
            QCOMPARE(normalized(v), 1.0);
        for (double v : {-std::numeric_limits<double>::max(), -1.0, 0.0, 0.79})
            QCOMPARE(normalized(v), 0.8);
        for (double v : {1.21, 2.0, std::numeric_limits<double>::max()})
            QCOMPARE(normalized(v), 1.2);
    }
    void testEveryScaleAndHalfStepSnapIsStable() {
        QList<double> scales;
        for (int percent = 80; percent <= 120; percent += 5)
            scales.append(percent / 100.0);
        QCOMPARE(scales.size(), 9);
        for (double scale : scales) {
            QCOMPARE(MonitorScale::normalized(scale), scale);
            QCOMPARE(MonitorScale::normalized(MonitorScale::normalized(scale)), scale);
            QCOMPARE(MonitorScale::normalized(scale - 0.024), scale);
            QCOMPARE(MonitorScale::normalized(scale + 0.024), scale);
        }
        for (int i = 0; i < 8; ++i) {
            const double midpoint = (82.5 + 5 * i) / 100.0;
            QCOMPARE(MonitorScale::normalized(midpoint), scales[i + 1]);
            QCOMPARE(MonitorScale::normalized(midpoint - 0.000001), scales[i]);
            QCOMPARE(MonitorScale::normalized(midpoint + 0.000001), scales[i + 1]);
        }
    }
    void testPreferencesNormalizeWithoutChangingLegacySelections() {
        MonitorPreferences p;
        p.selectedIDs = {"kept-task"};
        QCOMPARE(p.resolvedDisplayScale(), 1.0);
        QCOMPARE(p.resolvedScale(), 0.75);
        for (int percent = 80; percent <= 120; percent += 5) {
            double scale = percent / 100.0;
            p.uiScale = MonitorScale::renderingScale(scale);
            auto restored = roundTrip(p);
            QCOMPARE(restored.resolvedDisplayScale(), scale);
            QVERIFY(std::abs(restored.resolvedScale() - scale * 0.75) <= 0.000001);
            QCOMPARE(restored.selectedIDs, QSet<QString>{"kept-task"});
        }
        for (double value : {qQNaN(), qInf(), -qInf(), -1.0, 0.724, 1.076, 2.0}) {
            p.uiScale = value;
            QCOMPARE(p.resolvedDisplayScale(), MonitorScale::displayScale(value));
        }
    }
    void testLegacy75Becomes100WithoutChangingRenderedSizeOrStoredData() {
        MonitorPreferences p;
        p.uiScale = 0.75;
        p.selectedIDs = {"kept"};
        p.excludedIDs = {"removed"};
        auto restored = roundTrip(p);
        QCOMPARE(restored.resolvedDisplayScale(), 1.0);
        QCOMPARE(restored.resolvedScale(), 0.75);
        QCOMPARE(restored.uiScale, std::optional{0.75});
        QCOMPARE(restored.selectedIDs, QSet<QString>{"kept"});
        QCOMPARE(restored.excludedIDs, QSet<QString>{"removed"});
        QCOMPARE(410 * restored.resolvedScale(), 307.5);
        QVERIFY(std::abs(MonitorScale::renderingScale(0.8) - 0.6) <= 0.000001);
        QVERIFY(std::abs(MonitorScale::renderingScale(1.2) - 0.9) <= 0.000001);
    }
    void testLegacyOutOfRangeSizesClampAndNewKeyboardStepsStayOnTicks() {
        for (auto [old, shown] : QList<std::pair<double, double>>{
                 {0.6, 0.8}, {0.75, 1}, {0.8, 1.05}, {0.9, 1.2}, {1, 1.2}, {1.2, 1.2}})
            QCOMPARE(MonitorScale::displayScale(old), shown);
        MonitorPreferences p;
        for (int i = 0; i < 30; ++i)
            p.uiScale = MonitorScale::renderingScale(p.resolvedDisplayScale() + MonitorScale::step);
        QCOMPARE(p.resolvedDisplayScale(), 1.2);
        for (int i = 0; i < 30; ++i)
            p.uiScale = MonitorScale::renderingScale(p.resolvedDisplayScale() - MonitorScale::step);
        QCOMPARE(p.resolvedDisplayScale(), 0.8);
        p.uiScale = MonitorScale::renderingScale(1);
        QCOMPARE(p.resolvedScale(), 0.75);
    }
    void testPreferencesRoundTripAndCorruptionIsNotSilentlyOverwritten() {
        QTemporaryDir dir;
        QVERIFY(dir.isValid());
        QString path = dir.filePath("preferences.json");
        PreferencesFile saved(path);
        MonitorPreferences p;
        p.selectedIDs = {"a"};
        p.preferredDisplay = "display-one";
        p.floating = true;
        saved.save(p);
        QCOMPARE(saved.load(), p);
        QFile f(path);
        QVERIFY(f.open(QIODevice::WriteOnly));
        QCOMPARE(f.write("broken"), 6);
        f.close();
        QVERIFY_THROWS_EXCEPTION(std::runtime_error, saved.load());
        QVERIFY(f.open(QIODevice::ReadOnly));
        QCOMPARE(f.readAll(), QByteArray("broken"));
    }
    void testThemeAdditionKeepsOlderPreferencesReadable() {
        MonitorPreferences p;
        p.selectedIDs = {"kept-task"};
        p.theme = PanelTheme::Light;
        QCOMPARE(roundTrip(p).theme, std::optional{PanelTheme::Light});
        auto legacy = p.toJson();
        legacy.remove("theme");
        auto restored = MonitorPreferences::fromJson(legacy);
        QCOMPARE(restored.selectedIDs, QSet<QString>{"kept-task"});
        QVERIFY(!restored.theme);
    }
    void testDisplayModesAndScalePreserveLegacyPreferencesAndTaskSelection() {
        MonitorPreferences p;
        p.floating = true;
        p.selectedIDs = {"kept"};
        const auto legacy = roundTrip(p);
        QCOMPARE(legacy.resolvedPlacement(), Mode::Floating);
        QCOMPARE(legacy.resolvedScale(), 0.75);
        for (auto mode : modes) {
            p.placement = mode;
            p.uiScale = 0.8;
            auto restored = roundTrip(p);
            QCOMPARE(restored.resolvedPlacement(), mode);
            QVERIFY(std::abs(restored.resolvedScale() - 0.7875) <= 0.000001);
            QCOMPARE(restored.selectedIDs, QSet<QString>{"kept"});
        }
        p.uiScale = -5;
        QVERIFY(std::abs(p.resolvedScale() - 0.6) <= 0.000001);
        p.uiScale = 8;
        QVERIFY(std::abs(p.resolvedScale() - 0.9) <= 0.000001);
    }
};
QTEST_APPLESS_MAIN(PreferencesTests)
#include "test_preferences.moc"
