#include "codex/question_reply_receipt.h"

#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QTest>
#include <QTimeZone>
#include <limits>

using namespace codextop;

class QuestionReplyReceiptTests : public QObject {
    Q_OBJECT

    const QString thread = "11111111-1111-4111-8111-111111111111";
    const QString turn = "33333333-3333-4333-8333-333333333333";
    const QString client = "44444444-4444-4444-8444-444444444444";
    const QDateTime now = QDateTime::fromSecsSinceEpoch(1800000000, QTimeZone::UTC);

    QString reply(QList<QPair<QString,int>> items = {{"call_first",0}}, QJsonValue answer = "继续",
                  QJsonValue rawIndex = QJsonValue::Undefined, QString tool = "request_user_input_async")
    {
        QJsonArray replies;
        for (const auto &[call,index] : items) {
            const auto key = QJsonDocument(QJsonArray{tool,call,rawIndex.isUndefined() ? QJsonValue(index) : rawIndex})
                                .toJson(QJsonDocument::Compact);
            replies.append(QJsonObject{{"questionItemId",QString::fromUtf8(key)},{"question","Synthetic"},{"answer",answer}});
        }
        return "<send_user_message_question_reply>\n" + QString::fromUtf8(QJsonDocument(replies).toJson(QJsonDocument::Compact))
               + "\n</send_user_message_question_reply>";
    }

private slots:
    void testMultipleQuestionsUnicodeAndEscapesYieldOnlyAssociationMetadata()
    {
        const auto input = reply({{"call_first",0},{"call_first",1},{"call_second-A",0}},
                                 "继续中文调试\n\"引号\" \\ 机器人😀");
        const auto r = QuestionReplyReceipt::parse("\n " + input + " \n", thread, turn, client, now);
        QVERIFY(r);
        QCOMPARE(r->threadID, thread);
        QCOMPARE(r->turnID, turn);
        QCOMPARE(r->clientID, client);
        QCOMPARE(r->receivedAt, now);
        const QuestionItems expected{{"call_first",{0,1}},{"call_second-A",{0}}};
        QCOMPARE(r->questionItems, expected);
        // 分解全部字段，若新增正文成员，测试编译就会报错。
        const auto &[threadField,turnField,clientField,timeField,itemsField,preciseTime] = *r;
        QVERIFY(!preciseTime);
        const auto metadata = threadField + turnField + clientField + timeField.toString() + itemsField.keys().join(' ');
        QVERIFY(!metadata.contains("继续"));
        QVERIFY(!metadata.contains("answer"));
    }

    void testOrdinaryMessagesLogInjectionAndMalformedWrappersFailClosed()
    {
        const auto valid = reply();
        auto wrongTag = valid; wrongTag.replace("send_user_message_question_reply", "user_message");
        const QString fence(3, QChar(96));
        for (const QString &input : QStringList{"普通回复","请分析：" + valid,valid + "还有一句话",
                fence + "\n" + valid + "\n" + fence,"Submission { text: \"" + valid + "\" }",valid + valid,
                "<send_user_message_question_reply>invalid JSON</send_user_message_question_reply>",
                "<send_user_message_question_reply>{}</send_user_message_question_reply>",
                "<send_user_message_question_reply>[]</send_user_message_question_reply>",
                valid.chopped(1),valid.mid(1),wrongTag})
            QVERIFY(!QuestionReplyReceipt::parseQuestionItems(input));
    }

    void testAnswersCallIdentifiersAndQuestionIndexesAreStrictlyValidated()
    {
        const QList<QPair<QString,int>> first{{"call_first",0}};
        for (const auto &answer : QJsonArray{""," \n\t",7,true,QJsonValue::Null,QJsonObject{{"text","继续"}}})
            QVERIFY(!QuestionReplyReceipt::parseQuestionItems(reply(first,answer)));
        for (const auto &index : QJsonArray{true,false,-1,0.5,64,"0",QJsonValue::Null})
            QVERIFY(!QuestionReplyReceipt::parseQuestionItems(reply(first,"继续",index)));
        for (const QString &call : QStringList{"call_","other_call","call_has space","call_injected\nline",
                                             "call_" + QString(252, 'x')})
            QVERIFY(!QuestionReplyReceipt::parseQuestionItems(reply({{call,0}})));
        QVERIFY(!QuestionReplyReceipt::parseQuestionItems(reply({{"call_same",0},{"call_same",0}})));
        QVERIFY(!QuestionReplyReceipt::parseQuestionItems(reply(first,"继续",QJsonValue::Undefined,"request_user_input")));
        const QuestionItems expected{{"call_last",{63}}};
        QCOMPARE(QuestionReplyReceipt::parseQuestionItems(reply({{"call_last",63}})).value(), expected);
    }

    void testAssociationIdentifiersAndNonfiniteDatesAreRejected()
    {
        const auto input = reply();
        auto compact = thread; compact.remove('-');
        for (const QString &invalid : QStringList{"","not-a-uuid",compact," " + thread,thread + "\n"}) {
            QVERIFY(!QuestionReplyReceipt::parse(input,invalid,turn,client,now));
            QVERIFY(!QuestionReplyReceipt::parse(input,thread,invalid,client,now));
            QVERIFY(!QuestionReplyReceipt::parse(input,thread,turn,invalid,now));
        }
        for (double invalid : {std::numeric_limits<double>::infinity(),-std::numeric_limits<double>::infinity(),
                               std::numeric_limits<double>::quiet_NaN()})
            QVERIFY(!QuestionReplyReceipt::parse(input,thread,turn,client,invalid));
        QVERIFY(!QuestionReplyReceipt::parse(input,thread,turn,client,QDateTime()));
    }

    void testInputBytesAndQuestionCountRemainBounded()
    {
        QVERIFY(!QuestionReplyReceipt::parseQuestionItems(reply({{"call_first",0}},QString(22000, QChar(0x4e2d)))));
        QList<QPair<QString,int>> items;
        for (int i = 0; i < 65; ++i) items.append({"call_" + QString::number(i),0});
        QVERIFY(!QuestionReplyReceipt::parseQuestionItems(reply(items)));
        items.removeLast();
        const auto maximum = QuestionReplyReceipt::parseQuestionItems(reply(items));
        QVERIFY(maximum);
        QCOMPARE(maximum->size(),64);
    }
};

QTEST_GUILESS_MAIN(QuestionReplyReceiptTests)
#include "test_question_reply_receipt.moc"
