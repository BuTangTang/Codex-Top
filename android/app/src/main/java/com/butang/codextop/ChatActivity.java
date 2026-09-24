package com.butang.codextop;

import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.content.res.Configuration;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.net.Uri;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.text.Editable;
import android.text.TextWatcher;
import android.view.Gravity;
import android.view.View;
import android.view.WindowInsets;
import android.view.WindowInsetsController;
import android.view.WindowManager;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import java.util.List;
import java.util.UUID;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/** 通知和列表共用的原生对话页，只把文字发送到固定来源电脑的固定会话。 */
public final class ChatActivity extends Activity {
    private final Handler main = new Handler(Looper.getMainLooper());
    private final ExecutorService worker = Executors.newSingleThreadExecutor();
    private final MobileApi api = new MobileApi();
    private final Runnable poll = this::tick;
    private ConversationRoute route;
    private SessionStore.Session session;
    private State state;
    private boolean demo, active, busy;
    private volatile boolean closed;
    private Long before;
    private long receivedAt;
    private int background, surface, ink, muted, blue;
    private LinearLayout root, messages;
    private ScrollView scroll;
    private TextView title, source, status;
    private EditText editor;
    private Button send, older, latest;

    /** 内存保留草稿和未确认消息身份，旋转不会生成新的消息 ID，也不写入状态 Bundle。 */
    private static final class State {
        String address, draft = "", pendingId, pendingBody;
        ConversationData.History history;
    }

    /** 构造内部对话 Intent；只有不透明身份进入地址，退出登录后旧地址失效。 */
    public static Intent intent(Context context, SessionStore.Session session, String source, String thread, boolean demo) {
        String scope = demo ? "0".repeat(64) : ConversationRoute.scope(session.server(), session.token());
        ConversationRoute route = new ConversationRoute(scope, source, thread);
        return new Intent(context, ChatActivity.class).setData(Uri.parse(route.address())).putExtra("demo", demo);
    }

    /** 校验路由后创建固定聊天布局，再到后台恢复登录和对话。 */
    @Override public void onCreate(Bundle saved) {
        super.onCreate(saved);
        if (!BuildConfig.DEBUG) getWindow().addFlags(WindowManager.LayoutParams.FLAG_SECURE);
        try {
            Uri address = getIntent().getData();
            if (address == null || !"codextop".equals(address.getScheme()) || !"conversation".equals(address.getHost()) || address.getQuery() != null || address.getFragment() != null) throw new IllegalArgumentException();
            List<String> parts = address.getPathSegments();
            if (parts.size() != 3) throw new IllegalArgumentException();
            route = new ConversationRoute(parts.get(0), parts.get(1), parts.get(2));
        } catch (RuntimeException invalid) { finish(); return; }
        demo = getIntent().getBooleanExtra("demo", false);
        Object retained = getLastNonConfigurationInstance();
        state = retained instanceof State && route.address().equals(((State) retained).address) ? (State) retained : new State();
        state.address = route.address();
        build();
        if (demo) {
            String name = route.source().equals("mini-demo") ? "Mac mini" : route.source().equals("windows-demo") ? "Windows PC" : "MacBook Pro";
            String label = "示例对话";
            for (TaskData.Task task : TaskData.demo(System.currentTimeMillis(), 0).tasks()) if (task.id().equals(route.thread()) && task.sourceId().equals(route.source())) label = task.title();
            state.history = new ConversationData.History(route.source(), route.thread(), label, name, false,
                List.of(new ConversationData.Message("example-1", "user", "通知点进去直接就是对话。", "received", 0),
                    new ConversationData.Message("example-2", "assistant", "这里是合成对话预览。连接真实服务后，消息会发送到本对话所属的电脑。", "received", 0)), null);
            showHistory(true); status.setText("合成示例 · 不向电脑发送消息"); editor.setHint("合成示例，不发送");
        } else refresh();
    }

    /** 草稿只跨当前进程的配置变化保留，系统恢复和备份不会持久保存正文。 */
    @Override public Object onRetainNonConfigurationInstance() { return state; }

    /** 返回前台后恢复消息轮询，旧历史页不被自动替换。 */
    @Override public void onStart() { super.onStart(); active = true; main.postDelayed(poll, 5000); }

    /** 页面离开后停止轮询，不将聊天 Activity 当成可靠后台推送。 */
    @Override public void onStop() { active = false; main.removeCallbacks(poll); super.onStop(); }

    /** 销毁后丢弃异步界面回调；未确认发送身份保留在内存状态中供新 Activity 核对。 */
    @Override public void onDestroy() { closed = true; worker.shutdownNow(); main.removeCallbacksAndMessages(null); super.onDestroy(); }

    /** 每五秒刷新最新消息，不在历史翻页时强制跳回底部。 */
    private void tick() {
        if (!active || closed) return;
        if (!demo && before == null) refresh();
        main.postDelayed(poll, 5000);
    }

    /** 创建固定顶栏、可滚动消息和键盘上方输入框，网络刷新不重建输入控件。 */
    private void build() {
        boolean dark = (getResources().getConfiguration().uiMode & Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES;
        background = Color.parseColor(dark ? "#15181D" : "#FAFBFD"); surface = Color.parseColor(dark ? "#20252B" : "#F0F3F8");
        ink = Color.parseColor(dark ? "#F0F3F9" : "#20242A"); muted = Color.parseColor(dark ? "#B1BCCD" : "#626D79"); blue = Color.parseColor(dark ? "#9BBFFF" : "#245BC4");
        root = column(); root.setBackgroundColor(background);
        root.setOnApplyWindowInsetsListener((view, insets) -> {
            android.graphics.Insets edges = insets.getInsets(WindowInsets.Type.systemBars() | WindowInsets.Type.displayCutout() | WindowInsets.Type.ime());
            view.setPadding(edges.left, edges.top, edges.right, edges.bottom); return insets;
        });
        LinearLayout bar = row(); bar.setMinimumHeight(dp(56));
        android.widget.ImageButton back = new android.widget.ImageButton(this); back.setImageResource(R.drawable.ic_back);
        back.setImageTintList(android.content.res.ColorStateList.valueOf(ink)); back.setContentDescription("返回"); back.setBackgroundColor(Color.TRANSPARENT);
        back.setOnClickListener(view -> finish()); bar.addView(back, new LinearLayout.LayoutParams(dp(48), dp(48)));
        LinearLayout heading = column(); title = label("对话", 17, ink); title.setTypeface(Typeface.DEFAULT, Typeface.BOLD); heading.addView(title);
        source = label("正在读取来源…", 12, muted); heading.addView(source); bar.addView(heading, new LinearLayout.LayoutParams(0, -2, 1));
        Button reload = button("刷新"); reload.setOnClickListener(view -> refresh()); bar.addView(reload); root.addView(bar);
        status = label("正在读取对话…", 12, muted); status.setPadding(dp(16), dp(6), dp(16), dp(6)); status.setAccessibilityLiveRegion(View.ACCESSIBILITY_LIVE_REGION_POLITE); root.addView(status);
        LinearLayout paging = row(); paging.setGravity(Gravity.CENTER);
        older = button("更早消息"); older.setVisibility(View.GONE); older.setOnClickListener(view -> { if (state.history != null) { before = state.history.olderCursor(); refresh(); } }); paging.addView(older);
        latest = button("返回最新"); latest.setVisibility(View.GONE); latest.setOnClickListener(view -> { before = null; refresh(); }); paging.addView(latest); root.addView(paging);
        scroll = new ScrollView(this); messages = column(); messages.setPadding(dp(16), dp(12), dp(16), dp(16)); scroll.addView(messages);
        root.addView(scroll, new LinearLayout.LayoutParams(-1, 0, 1));
        LinearLayout composer = row(); composer.setPadding(dp(12), dp(8), dp(8), dp(8));
        editor = new EditText(this); editor.setSaveEnabled(false); editor.setTextColor(ink); editor.setHintTextColor(muted); editor.setTextSize(15);
        editor.setHint("发送消息…"); editor.setInputType(android.text.InputType.TYPE_CLASS_TEXT | android.text.InputType.TYPE_TEXT_FLAG_MULTI_LINE);
        editor.setMaxLines(5); editor.setMinHeight(dp(48)); editor.setBackground(shape(surface)); editor.setPadding(dp(12), dp(10), dp(12), dp(10));
        editor.setFilters(new android.text.InputFilter[]{new android.text.InputFilter.LengthFilter(8000)}); editor.setText(state.draft);
        editor.addTextChangedListener(new TextWatcher() {
            /** 输入前不改动路由或消息身份。 */
            public void beforeTextChanged(CharSequence s, int start, int count, int after) { }
            /** 同步内存草稿，刷新消息列表不会吞掉正在输入的文本。 */
            public void onTextChanged(CharSequence s, int start, int before, int count) { state.draft = s.toString(); }
            /** 输入变化后同步发送按钮状态。 */
            public void afterTextChanged(Editable value) { updateComposer(); }
        });
        composer.addView(editor, new LinearLayout.LayoutParams(0, -2, 1)); send = button("发送"); send.setOnClickListener(view -> sendMessage()); composer.addView(send); root.addView(composer);
        setContentView(root);
        root.post(() -> {
            if (root.getWindowInsetsController() != null) root.getWindowInsetsController().setSystemBarsAppearance(dark ? 0 : WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS | WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS,
                WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS | WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS);
        });
        updateComposer();
    }

    /** 每次访问前核对当前登录，旧通知不能沿用后来登录账号或另一服务器。 */
    private SessionStore.Session currentSession() throws Exception {
        SessionStore.Session current = new SessionStore(this).load();
        if (current == null || !route.scope().equals(ConversationRoute.scope(current.server(), current.token()))) throw new MobileApi.ApiException(401, "此通知所属登录已失效，请返回首页重新进入对话");
        return current;
    }

    /** 异步读取固定目标，消息页不会因全局电脑选择发生变化。 */
    private void refresh() {
        if (demo || busy || closed) return;
        busy = true; updateComposer();
        Long cursor = before;
        worker.execute(() -> {
            try {
                SessionStore.Session current = currentSession();
                ConversationData.History result = api.history(current, route, cursor);
                currentSession();
                main.post(() -> {
                    if (closed) return;
                    boolean initial = state.history == null; session = current; state.history = result; receivedAt = SystemClock.elapsedRealtime(); busy = false;
                    if (state.pendingId != null) for (ConversationData.Message item : result.messages()) if (state.pendingId.equals(item.id())) { clearPending(); break; }
                    showHistory(initial); status.setText(result.online() ? "" : "来源电脑离线，可查看已同步消息"); updateComposer();
                });
            } catch (Exception error) { main.post(() -> showError(error)); }
        });
    }

    /** 首次提交固定消息 ID，网络结果不明时保留正文和 ID，仅允许确认同一条消息。 */
    private void sendMessage() {
        if (busy || demo || state.draft.isBlank() || closed) return;
        if (state.pendingId == null) { state.pendingId = UUID.randomUUID().toString(); state.pendingBody = state.draft; }
        String id = state.pendingId, body = state.pendingBody;
        busy = true; status.setText("正在提交消息…"); updateComposer();
        worker.execute(() -> {
            try {
                SessionStore.Session current = currentSession(); api.send(current, route, id, body); currentSession();
                main.post(() -> { if (closed) return; busy = false; clearPending(); before = null; status.setText("服务已收到，正在读取回执…"); refresh(); });
            } catch (Exception error) {
                main.post(() -> {
                    if (closed) return;
                    // 明确拒绝没有新建消息；网络超时则保留原 ID，不能伪装为失败后换 ID 重发。
                    if (error instanceof MobileApi.ApiException && java.util.Set.of(400, 401, 403, 404, 413, 429).contains(((MobileApi.ApiException) error).status)) {
                        state.pendingId = null; state.pendingBody = null;
                    }
                    showError(error);
                });
            }
        });
    }

    /** 明确找到原消息后清理对应草稿，保留用户在其他流程已编辑的新草稿。 */
    private void clearPending() {
        if (state.draft.equals(state.pendingBody)) { state.draft = ""; editor.setText(""); }
        state.pendingId = null; state.pendingBody = null;
    }

    /** 更新消息区域；阅读上方历史时保留位置，不因每次轮询强制跳到底部。 */
    private void showHistory(boolean bottom) {
        ConversationData.History history = state.history;
        int oldY = scroll.getScrollY(); boolean nearBottom = messages.getHeight() - (oldY + scroll.getHeight()) < dp(80);
        title.setText(history.title()); source.setText(history.device() + (demo ? " · 合成示例" : history.online() ? " · 在线" : " · 离线"));
        messages.removeAllViews();
        for (ConversationData.Message message : history.messages()) {
            LinearLayout wrapper = column(); boolean outgoing = message.role().equals("user");
            wrapper.setGravity(outgoing ? Gravity.END : Gravity.START); wrapper.setPadding(0, 0, 0, dp(16));
            TextView body = label(message.text().isEmpty() && message.state().equals("expired") ? "消息正文已过保留期" : message.text(), 15, ink);
            body.setTextIsSelectable(true); body.setPadding(dp(12), dp(10), dp(12), dp(10));
            body.setMaxWidth(Math.max(dp(180), getResources().getDisplayMetrics().widthPixels - dp(72)));
            body.setBackground(shape(outgoing ? ((blue & 0x00FFFFFF) | 0x20000000) : surface)); wrapper.addView(body, new LinearLayout.LayoutParams(-2, -2));
            if (outgoing) { TextView receipt = label(ConversationData.stateLabel(message.state()), 11, muted); receipt.setPadding(0, dp(5), 0, 0); wrapper.addView(receipt); }
            messages.addView(wrapper, new LinearLayout.LayoutParams(-1, -2));
        }
        if (history.messages().isEmpty()) messages.addView(label("暂无已同步消息", 14, muted));
        older.setVisibility(history.olderCursor() == null ? View.GONE : View.VISIBLE); latest.setVisibility(before == null ? View.GONE : View.VISIBLE);
        scroll.post(() -> { if (bottom || (before == null && nearBottom)) scroll.fullScroll(View.FOCUS_DOWN); else scroll.scrollTo(0, oldY); });
        updateComposer();
    }

    /** 失败保留可用历史但明确标注；权限消失时立即清除屏幕上的旧正文。 */
    private void showError(Exception error) {
        if (closed) return;
        busy = false; receivedAt = 0;
        if (error instanceof MobileApi.ApiException && java.util.Set.of(401, 403, 404).contains(((MobileApi.ApiException) error).status)) {
            state.history = null; messages.removeAllViews(); source.setText("对话不可用");
        } else if (state.history != null) source.setText(state.history.device() + " · 连接待确认");
        status.setText(error instanceof MobileApi.ApiException ? error.getMessage() : "连接中断，请刷新确认；未确认的发送保留原消息身份。"); updateComposer();
    }

    /** 离线和过期状态禁止新发送；结果不明时只允许使用原 ID 确认，不编辑成新命令。 */
    private void updateComposer() {
        if (send == null) return;
        boolean pending = state.pendingId != null;
        editor.setEnabled(!demo && !busy && !pending);
        boolean fresh = state.history != null && state.history.online() && receivedAt > 0 && SystemClock.elapsedRealtime() - receivedAt <= TaskData.FRESH_MS;
        send.setText(pending ? "确认发送" : "发送"); send.setEnabled(!demo && !busy && !state.draft.isBlank() && (pending || fresh));
    }

    /** 创建跟随系统字号的聊天文本。 */
    private TextView label(String text, int size, int color) { TextView view = new TextView(this); view.setText(text); view.setTextSize(size); view.setTextColor(color); return view; }
    /** 创建触控区域至少 48dp 的轻量操作按钮。 */
    private Button button(String title) { Button button = new Button(this); button.setText(title); button.setTextSize(13); button.setAllCaps(false); button.setTextColor(blue); button.setMinWidth(dp(64)); button.setMinimumHeight(dp(48)); button.setBackgroundColor(Color.TRANSPARENT); return button; }
    /** 创建聊天气泡与输入框共用的纯色圆角。 */
    private GradientDrawable shape(int color) { GradientDrawable shape = new GradientDrawable(); shape.setColor(color); shape.setCornerRadius(dp(12)); return shape; }
    /** 纵向布局不依赖固定高度，支持系统大字体。 */
    private LinearLayout column() { LinearLayout view = new LinearLayout(this); view.setOrientation(LinearLayout.VERTICAL); return view; }
    /** 横向布局对齐消息操作和输入框。 */
    private LinearLayout row() { LinearLayout view = new LinearLayout(this); view.setGravity(Gravity.CENTER_VERTICAL); return view; }
    /** 将逻辑尺寸转换为当前设备像素。 */
    private int dp(int value) { return Math.round(value * getResources().getDisplayMetrics().density); }
}
