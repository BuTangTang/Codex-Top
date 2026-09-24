package com.butang.codextop;

import android.content.Context;
import android.content.SharedPreferences;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import android.util.Base64;
import org.json.JSONObject;
import java.nio.charset.StandardCharsets;
import java.security.KeyStore;
import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;

/** 只保存本服务会话；密码、Codex 凭据、任务内容均不落盘。加解密由后台线程调用。 */
public final class SessionStore {
    private static final String ALIAS = "codex-top-mobile-session-v1";
    private final SharedPreferences preferences;
    public record Session(String server, String token, String account) { }

    /** 打开应用私有存储，备份由 Manifest 禁止。 */
    public SessionStore(Context context) { preferences = context.getSharedPreferences("session", Context.MODE_PRIVATE); }

    /** 获取应用专属 AES 密钥；密钥保留在 Android Keystore 中。 */
    private SecretKey key() throws Exception {
        KeyStore store = KeyStore.getInstance("AndroidKeyStore");
        store.load(null);
        if (store.containsAlias(ALIAS)) return (SecretKey) store.getKey(ALIAS, null);
        KeyGenerator generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore");
        generator.init(new KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT | KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build());
        return generator.generateKey();
    }

    /** 加密保存会话；失败向调用者报告，不能显示已记住登录。 */
    public void save(Session session) throws Exception {
        synchronized (SessionStore.class) {
        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(Cipher.ENCRYPT_MODE, key());
        String json = new JSONObject().put("server", session.server()).put("token", session.token()).put("account", session.account()).toString();
        String encrypted = Base64.encodeToString(cipher.doFinal(json.getBytes(StandardCharsets.UTF_8)), Base64.NO_WRAP);
        String iv = Base64.encodeToString(cipher.getIV(), Base64.NO_WRAP);
        if (!preferences.edit().putString("encrypted", encrypted).putString("iv", iv).commit()) throw new IllegalStateException("会话保存失败");
        }
    }

    /** 解密本服务会话；损坏或密钥失效时清除残留并回到登录页。 */
    public Session load() {
        synchronized (SessionStore.class) {
        String encrypted = preferences.getString("encrypted", "");
        if (encrypted.isEmpty()) return null;
        try {
            Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
            cipher.init(Cipher.DECRYPT_MODE, key(), new GCMParameterSpec(128, Base64.decode(preferences.getString("iv", ""), Base64.NO_WRAP)));
            JSONObject json = new JSONObject(new String(cipher.doFinal(Base64.decode(encrypted, Base64.NO_WRAP)), StandardCharsets.UTF_8));
            return new Session(json.getString("server"), json.getString("token"), json.getString("account"));
        } catch (Exception ignored) { clear(); return null; }
        }
    }

    /** 退出时同步删除本地凭据，防止后台线程稍后重新使用。 */
    @android.annotation.SuppressLint("ApplySharedPref")
    public void clear() { synchronized (SessionStore.class) { preferences.edit().clear().commit(); } }

    /** 旧网络请求失效时，只清理其对应会话，不能删除后来新登录的账号。 */
    public void clearIf(Session expected) {
        synchronized (SessionStore.class) { if (expected.equals(load())) clear(); }
    }
}
