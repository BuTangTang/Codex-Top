package com.butang.codextop;

import org.junit.Test;
import static org.junit.Assert.*;

/** 固定错误策略测试不读取网络、手机账号或真实对话。 */
public class MobileApiPolicyTest {
    /** 明确拒绝需要状态与白名单码同时匹配，代理错误不能解除未知发送保护。 */
    @Test public void onlyRecognizesMatchingRejectionCodes() {
        assertEquals("computer_offline", MobileApi.knownError("computer_offline", 409));
        assertEquals("message_id_conflict", MobileApi.knownError("message_id_conflict", 409));
        assertEquals("message_quota", MobileApi.knownError("message_quota", 429));
        assertEquals("", MobileApi.knownError("computer_offline", 500));
        assertEquals("", MobileApi.knownError("unknown_server_detail", 409));
    }

    /** 错误正文不能拼接进入界面，同时保留现有异常构造接口。 */
    @Test public void usesFixedMessagesAndCompatibleException() {
        String untrusted = "untrusted_private_server_detail";
        assertFalse(MobileApi.errorMessage(500, untrusted).contains(untrusted));
        assertNotEquals(MobileApi.errorMessage(409, "computer_offline"), MobileApi.errorMessage(409, "message_id_conflict"));
        assertEquals("", new MobileApi.ApiException(401, "固定提示").code);
        assertEquals("computer_offline", new MobileApi.ApiException(409, "computer_offline", "固定提示").code);
    }
}
