#include "led/led_layout.h"
#include <QtTest>
#include <cmath>

using namespace led;
namespace {
Layout example(int running = 0, int waiting = 0, int failed = 0, bool done = false) {
    return layout(groups(running, waiting, failed, 0, done, false, false));
}
QStringList texts(const QList<Group> &values) {
    QStringList result;
    for (const auto &group : values)
        result.append(group.text);
    return result;
}
QList<Tone> tones(const QList<Group> &values) {
    QList<Tone> result;
    for (const auto &group : values)
        result.append(group.tone);
    return result;
}
} // namespace
class LEDOrbLayoutTests : public QObject {
    Q_OBJECT
  private slots:
    void testGroupsShowOnlyWhatExists() {
        QCOMPARE(texts(groups(3, 0, 0, 0, false, false, false)), QStringList{"3"});
        QCOMPARE(tones(groups(2, 1, 4, 0, false, false, false)),
                 QList<Tone>({Tone::Running, Tone::Waiting, Tone::Failed}));
        QCOMPARE(tones(groups(0, 2, 0, 0, false, false, false)), QList<Tone>({Tone::Idle, Tone::Waiting}));
        QCOMPARE(texts(groups(0, 0, 0, 0, true, false, false)), QStringList{"OK"});
        QCOMPARE(texts(groups(0, 0, 0, 0, true, true, false)), QStringList{"Zz"});
        QCOMPARE(tones(groups(3, 0, 1, 2, false, false, false)),
                 QList<Tone>({Tone::Running, Tone::Failed, Tone::Done}));
        QCOMPARE(texts(groups(5, 1, 0, 0, false, false, true)), QStringList{"?"});
        QCOMPARE(texts(groups(120, 0, 0, 0, false, false, false)), QStringList{"99+"});
    }
    void testEverythingSitsOnWholePoints() {
        for (const auto &value : {example(3), example(12, 10, 3), example(120, 1)}) {
            auto rects = value.dividers + value.ring;
            for (const auto &dot : value.dots)
                rects.append(dot.rect);
            for (const auto &rect : rects) {
                QCOMPARE(rect.left(), std::round(rect.left()));
                QCOMPARE(rect.top(), std::round(rect.top()));
                QVERIFY(rect.left() >= 0 && rect.right() <= value.width && rect.top() >= 0 &&
                        rect.bottom() <= height);
            }
            QCOMPARE(value.width, std::round(value.width));
        }
    }
    void testWidthGrowsWithGroupsAndStartsAt45() {
        QCOMPARE(example(3).width, 45);
        QCOMPARE(example(0, 0, 0, true).width, 49);
        QVERIFY(example(2, 1, 1).width > example(2, 1).width);
        QCOMPARE(int(example(12, 10).width - 9) % 4, 0);
    }
    void testRingRunsClockwiseWithEmptyCorners() {
        const auto ring = example(3).ring;
        QCOMPARE(ring.size(), 32);
        QList<QPointF> centers;
        for (const auto &rect : ring)
            centers.append(rect.center());
        QVERIFY(centers[1].x() > centers[0].x());
        auto firstRight =
            std::find_if(centers.cbegin(), centers.cend(), [](QPointF p) { return p.x() == 45 - 4.5; });
        QVERIFY(firstRight != centers.cend() && std::next(firstRight) != centers.cend());
        QVERIFY(std::next(firstRight)->y() > firstRight->y());
        for (auto corner : QList<QPointF>{{4.5, 4.5}, {40.5, 4.5}, {40.5, 40.5}, {4.5, 40.5}})
            QVERIFY(!centers.contains(corner));
        for (qsizetype i = 0; i < centers.size(); i++) {
            auto delta = centers[(i + 1) % centers.size()] - centers[i];
            double distance = std::hypot(delta.x(), delta.y());
            QVERIFY(distance >= 4);
            QVERIFY(distance <= 5.66);
        }
    }
    void testDividersSitBetweenGroups() {
        auto value = example(2, 1, 1);
        QCOMPARE(value.dividers.size(), 2);
        QList<qreal> xs;
        for (const auto &dot : value.dots)
            if (dot.tone == Tone::Waiting)
                xs.append(dot.rect.left());
        QVERIFY(!xs.isEmpty());
        QVERIFY(value.dividers[0].right() < *std::min_element(xs.cbegin(), xs.cend()));
    }
};
QTEST_APPLESS_MAIN(LEDOrbLayoutTests)
#include "test_led_orb_layout.moc"
