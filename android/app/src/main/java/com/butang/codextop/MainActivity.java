package com.butang.codextop;

import android.Manifest;
import android.app.Activity;
import android.app.AlertDialog;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.content.res.Configuration;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.provider.Settings;
import android.text.InputType;
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
import android.widget.Toast;
import java.text.DateFormat;
import java.util.Date;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/** 原生手机界面；真实服务与合成示例显式分离，不读取本机 Codex 数据。 */
public final class MainActivity extends Activity {
    private final Handler main = new Handler(Looper.getMainLooper());
    private final Runnable refreshLoop = this::tick;
    private final ExecutorService worker = Executors.newSingleThreadExecutor();
    private final MobileApi api = new MobileApi();
    private SessionStore store;
    private SessionStore.Session session;
    private NotificationCenter notices;
    private TaskData.Snapshot snapshot;
    private boolean demo, busy, visible, notificationMode;
    private volatile boolean closed;
    private volatile int generation;
    private int tab;
    private String settingsPage = "";
    private String selected, message = "", serverInput = "", userInput = "";
    private LinearLayout root, content;
    private ScrollView scroll;
    private int background, surface, ink, muted, line, blue, green, amber, red;

    /** 创建界面并异步恢复会话，初始化阶段不阻塞首帧。 */
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        // 登录和任务内容不进入系统最近任务缩略图，也不允许外部录屏。
        if (!BuildConfig.DEBUG) getWindow().addFlags(WindowManager.LayoutParams.FLAG_SECURE);
        store = new SessionStore(this);
        notices = new NotificationCenter(this);
        if (state != null) {
            notificationMode = state.getBoolean("notificationMode"); tab = state.getInt("tab"); settingsPage = state.getString("settingsPage", ""); demo = state.getBoolean("demo");
            serverInput = state.getString("server", ""); userInput = state.getString("user", "");
        }
        if (android.os.Build.VERSION.SDK_INT >= 33) getOnBackInvokedDispatcher().registerOnBackInvokedCallback(0, this::navigateBack);
        render();
        // 解密在工作线程，回调必须确认 Activity 尚未销毁。
        worker.execute(() -> {
            SessionStore.Session saved = store.load();
            main.post(() -> {
                if (closed) return;
                session = saved;
                if (session != null) demo = false;
                if (demo) snapshot = TaskData.demo(System.currentTimeMillis(), SystemClock.elapsedRealtime());
                render();
                if (session != null) refresh();
            });
        });
    }

    /** 前台恢复定时刷新，后台由用户显式启动的独立服务负责。 */
    @Override public void onStart() { super.onStart(); visible = true; main.removeCallbacks(refreshLoop); main.postDelayed(refreshLoop, 15_000); }

    /** 从系统设置返回时同步权限显示，不重建正在填写的登录表单。 */
    @Override public void onResume() { super.onResume(); if (root != null && tab == 1 && (session != null || demo)) render(); }

    /** 页面不可见后停止刷新，不把普通 Activity 伪装成后台推送。 */
    @Override public void onStop() { visible = false; main.removeCallbacks(refreshLoop); super.onStop(); }

    /** 保存导航和非敏感输入；明文密码不进入状态 Bundle。 */
    @Override public void onSaveInstanceState(Bundle state) {
        state.putBoolean("notificationMode", notificationMode); state.putInt("tab", tab); state.putString("settingsPage", settingsPage); state.putBoolean("demo", demo);
        state.putString("server", serverInput); state.putString("user", userInput);
        super.onSaveInstanceState(state);
    }

    /** 销毁时使请求回调失效，避免旧页面覆盖新页面或重复显示结果。 */
    @Override public void onDestroy() { closed = true; generation++; worker.shutdownNow(); main.removeCallbacksAndMessages(null); super.onDestroy(); }

    /** 自动刷新只在前台执行；示例时间保持真实经过，过期同样明确展示。 */
    private void tick() {
        if (!visible || closed) return;
        if (session != null) refresh();
        else if (demo) render();
        main.postDelayed(refreshLoop, 15_000);
    }

    /** 手机系统返回先回列表；根页面回到桌面，保留用户主动开启的提醒。 */
    private void navigateBack() {
        if (selected != null) { selected = null; render(); }
        else if (tab != 0 && !settingsPage.isEmpty()) { settingsPage = ""; scroll.scrollTo(0, 0); render(); }
        else if (tab != 0 && (session != null || demo)) { tab = 0; scroll.scrollTo(0, 0); render(); }
        else moveTaskToBack(true);
    }

    /** 为 Android 12 及以下保留一致返回行为。 */
    @Override public void onBackPressed() { navigateBack(); }

    /** 显式使用两套语义颜色，不依赖厂商动态主题改变任务状态含义。 */
    private void palette() {
        boolean dark = (getResources().getConfiguration().uiMode & Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES;
        background = Color.parseColor(dark ? "#15181D" : "#F3F5F9");
        surface = Color.parseColor(dark ? "#20252B" : "#FFFFFF");
        ink = Color.parseColor(dark ? "#F0F3F9" : "#20242A");
        muted = Color.parseColor(dark ? "#B1BCCD" : "#626D79");
        line = Color.parseColor(dark ? "#3D4758" : "#E9ECF0");
        blue = Color.parseColor(dark ? "#92B7FF" : "#245BC4");
        green = Color.parseColor(dark ? "#7AD6A4" : "#187447");
        amber = Color.parseColor(dark ? "#F0C078" : "#895500");
        red = Color.parseColor(dark ? "#FFA4A4" : "#B52E35");
    }

    /** 内容窗口附着后设置系统栏颜色，避免首帧尚无 DecorView 时崩溃。 */
    private void applySystemBars() {
        boolean dark = (getResources().getConfiguration().uiMode & Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES;
        WindowInsetsController controller = root.getWindowInsetsController();
        if (controller == null) return;
        controller.setSystemBarsAppearance(
            dark ? 0 : WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS | WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS,
            WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS | WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS);
    }

    /** 重新绘制当前页面并保留滚动；系统栏和键盘空间通过 Insets 处理。 */
    private void render() {
        if (closed) return;
        int position = scroll == null ? 0 : scroll.getScrollY();
        palette();
        root = column(); root.setBackgroundColor(background);
        root.setOnApplyWindowInsetsListener((view, insets) -> {
            // 取系统栏与键盘的最大边距，确保按钮不被手势区或输入法遮挡。
            android.graphics.Insets bars = insets.getInsets(WindowInsets.Type.systemBars() | WindowInsets.Type.displayCutout() | WindowInsets.Type.ime());
            view.setPadding(bars.left, bars.top, bars.right, bars.bottom);
            return insets;
        });
        scroll = new ScrollView(this); scroll.setFillViewport(true);
        content = column(); content.setPadding(dp(20), dp(16), dp(20), dp(24));
        scroll.addView(content); root.addView(scroll, new LinearLayout.LayoutParams(-1, 0, 1));
        if (session == null && !demo) loginScreen();
        else {
            if (tab == 0) taskScreen();
            else settingsScreen();
        }
        setContentView(root);
        root.post(this::applySystemBars);
        ScrollView currentScroll = scroll;
        currentScroll.post(() -> currentScroll.scrollTo(0, position));
    }

    /** 首次登录明确提示自有服务器用途，示例模式不冒充登录成功。 */
    private void loginScreen() {
        android.widget.ImageView logo = new android.widget.ImageView(this);
        logo.setImageResource(R.drawable.app_logo); logo.setContentDescription("Codex Top 标志");
        content.addView(logo, new LinearLayout.LayoutParams(dp(64), dp(64)));
        gap(content, 16); text(content, "连接 Codex Top", 22, ink, true);
        gap(content, 8); text(content, "接收电脑的任务通知", 14, muted, false); gap(content, 24);
        EditText server = field(content, "服务地址", "https://top.example.com", serverInput, InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_URI);
        EditText username = field(content, "账号", "输入自己的账号", userInput, InputType.TYPE_CLASS_TEXT);
        EditText password = field(content, "密码", "输入密码", "", InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD);
        password.setSaveEnabled(false);
        TextView error = text(content, message, 14, red, false); error.setAccessibilityLiveRegion(View.ACCESSIBILITY_LIVE_REGION_POLITE);
        gap(content, 8);
        Button login = button(content, "登录", true, null);
        // 先校验并记录非敏感输入，再发出网络请求；错误保留当前表单供修正。
        login.setOnClickListener(view -> {
            serverInput = server.getText().toString().trim(); userInput = username.getText().toString().trim();
            try {
                String address = MobileApi.normalizeServer(serverInput, BuildConfig.DEBUG);
                if (userInput.isEmpty() || password.getText().length() == 0) throw new IllegalArgumentException("请填写账号和密码");
                if (userInput.length() > 120 || password.getText().length() > 512) throw new IllegalArgumentException("账号或密码过长");
                login(address, userInput, password.getText().toString(), password, login, error);
            } catch (IllegalArgumentException invalid) { error.setText(invalid.getMessage()); }
        });
        button(content, "先体验示例", false, view -> {
            if (busy) { toast("正在登录，请等待当前请求完成"); return; }
            generation++; demo = true; message = ""; tab = 0;
            snapshot = TaskData.demo(System.currentTimeMillis(), SystemClock.elapsedRealtime()); render();
        });
        gap(content, 12);
        text(content, "账号由你的服务管理员创建。尚未部署服务时，可以先查看合成示例。", 13, muted, false);
    }

    /** 登录成功后加密保存；切换页面或销毁后不允许旧请求回写登录状态。 */
    private void login(String address, String username, String password, EditText passwordField, Button button, TextView error) {
        if (busy) return;
        busy = true; button.setEnabled(false); button.setText("正在登录…"); error.setText("");
        int requestGeneration = ++generation;
        worker.execute(() -> {
            try {
                SessionStore.Session result = api.login(address, username, password);
                if (closed || requestGeneration != generation) return;
                store.save(result);
                main.post(() -> {
                    if (closed || requestGeneration != generation) return;
                    passwordField.setText(""); busy = false; demo = false; session = result; message = "";
                    snapshot = null; selected = null; tab = 0; render(); refresh();
                });
            } catch (Exception failure) {
                main.post(() -> {
                    if (closed || requestGeneration != generation) return;
                    busy = false; button.setEnabled(true); button.setText("登录");
                    error.setText(loginError(failure));
                });
            }
        });
    }

    /** 用固定文案区分网络、协议和安全存储故障，不显示可能含秘密的异常正文。 */
    private String loginError(Exception failure) {
        if (failure instanceof MobileApi.ApiException) return failure.getMessage();
        String message;
        if (failure instanceof java.net.ConnectException) message = "无法连接服务，请检查服务是否启动；USB 联调需重新建立端口转发";
        else if (failure instanceof java.net.UnknownHostException) message = "找不到服务地址，请检查域名与网络";
        else if (failure instanceof javax.net.ssl.SSLException) message = "无法验证服务证书，请检查 HTTPS 配置";
        else if (failure instanceof java.net.SocketTimeoutException) message = "服务连接超时，请稍后重试";
        else if (failure instanceof org.json.JSONException) message = "服务响应格式不兼容，请检查是否连接 Codex Top 账号服务";
        else if (failure instanceof java.security.GeneralSecurityException) message = "手机安全存储暂不可用，请重启 App 后再试";
        else message = "登录未完成，请检查服务连接和手机存储";
        return BuildConfig.DEBUG ? message + "（" + failure.getClass().getSimpleName() + "）" : message;
    }

    /** 顺序刷新完整快照；401 清理登录，普通断网保留已知数据并标明连接失败。 */
    private void refresh() {
        if (busy || session == null || closed) return;
        busy = true;
        int requestGeneration = generation;
        SessionStore.Session current = session;
        worker.execute(() -> {
            TaskData.Snapshot result = null;
            Exception failure = null;
            try { result = api.snapshot(current); } catch (Exception error) { failure = error; }
            TaskData.Snapshot response = result;
            Exception error = failure;
            main.post(() -> {
                if (closed || generation != requestGeneration) return;
                busy = false;
                if (error == null) {
                    if (snapshot != null && response.serverTime() < snapshot.serverTime()) message = "服务返回旧数据，等待下一次刷新。";
                    else { snapshot = response; message = ""; }
                }
                else if (error instanceof MobileApi.ApiException && ((MobileApi.ApiException) error).status == 401) {
                    stopService(new Intent(this, MonitorService.class)); store.clearIf(current); notices.clear();
                    session = null; snapshot = null; selected = null; generation++; message = "登录已失效，请重新登录";
                } else message = "连接中断，以下是上次取得的数据。点击刷新重试。";
                render();
            });
        });
    }

    /** 对话入口展示全部共享任务，通知入口仅显示三类提醒，两者均直接进入固定来源对话。 */
    private void taskScreen() {
        content.setPadding(0, 0, 0, dp(12)); content.setBackgroundColor(surface);
        LinearLayout toolbar = row(); toolbar.setMinimumHeight(dp(52));
        toolbar.setPadding(dp(16), 0, dp(8), 0); toolbar.setBackgroundColor(background);
        TextView title = new TextView(this); title.setText(notificationMode ? "通知" : "对话"); title.setTextSize(18); title.setTextColor(ink);
        title.setTypeface(Typeface.DEFAULT, Typeface.BOLD); toolbar.addView(title);
        TextView state = new TextView(this); state.setTextSize(12); state.setTextColor(muted); state.setPadding(dp(12), 0, dp(8), 0);
        boolean current = snapshot != null && message.isEmpty()
            && SystemClock.elapsedRealtime() - snapshot.receivedElapsed() <= TaskData.FRESH_MS;
        state.setText(demo ? "合成示例" : current ? "已连接服务" : snapshot == null ? "正在连接" : "连接待确认");
        toolbar.addView(state, new LinearLayout.LayoutParams(0, -2, 1));
        android.widget.ImageButton settings = new android.widget.ImageButton(this);
        settings.setImageResource(R.drawable.ic_settings); settings.setImageTintList(android.content.res.ColorStateList.valueOf(ink));
        settings.setContentDescription("设置"); settings.setBackground(ripple(background)); settings.setPadding(dp(12), dp(12), dp(12), dp(12));
        settings.setOnClickListener(view -> { tab = 1; settingsPage = ""; selected = null; scroll.scrollTo(0, 0); render(); });
        toolbar.addView(settings, new LinearLayout.LayoutParams(dp(48), dp(48)));
        // 顶栏固定在列表上方，长列表滚动不丢失设置入口。
        root.addView(toolbar, 0);
        LinearLayout navigation = row(); navigation.setBackgroundColor(surface);
        for (boolean notifications : new boolean[]{false, true}) {
            Button entry = new Button(this); entry.setText(notifications ? "通知" : "对话"); entry.setAllCaps(false); entry.setTextSize(14);
            entry.setTextColor(notificationMode == notifications ? blue : muted); entry.setMinimumHeight(dp(52)); entry.setBackground(ripple(surface));
            entry.setOnClickListener(view -> { notificationMode = notifications; scroll.scrollTo(0, 0); render(); });
            navigation.addView(entry, new LinearLayout.LayoutParams(0, -2, 1));
        }
        root.addView(navigation);
        if (!message.isEmpty()) compactNotice("连接中断，显示上次记录", red);
        if (snapshot == null) { compactNotice(busy ? "正在读取通知…" : "尚未取得通知，请到设置重试", muted); return; }
        java.util.List<TaskData.Task> ordered = notificationMode ? TaskData.notificationItems(snapshot) : new java.util.ArrayList<>(snapshot.tasks());
        for (TaskData.Task task : ordered) taskRow(task);
        if (ordered.isEmpty()) compactNotice(notificationMode ? "暂无通知" : "还没有共享的对话", muted);
    }

    /** 请求失败与来源过期都会收回实时状态，不将历史记录描述成当前指令。 */
    private boolean fresh(TaskData.Task task) { return message.isEmpty() && snapshot.fresh(task, SystemClock.elapsedRealtime()); }

    /** 用两行文字呈现名称、状态和来源；大字号时自然增高，整行仍可点击。 */
    private void taskRow(TaskData.Task task) {
        LinearLayout item = row(); item.setMinimumHeight(dp(76)); item.setPadding(dp(16), dp(12), dp(16), dp(12));
        item.setBackground(ripple(surface)); item.setFocusable(true); item.setClickable(true);
        boolean current = fresh(task);
        int color = current ? phaseColor(task.phase()) : muted;
        android.widget.ImageView icon = new android.widget.ImageView(this);
        icon.setImageResource(task.phase().equals("waiting") ? R.drawable.ic_waiting : task.phase().equals("failed") ? R.drawable.ic_failed : task.phase().equals("completed") ? R.drawable.ic_done : R.drawable.ic_conversation);
        icon.setImageTintList(android.content.res.ColorStateList.valueOf(color));
        icon.setPadding(dp(7), dp(7), dp(7), dp(7)); icon.setBackground(shape((color & 0x00FFFFFF) | 0x12000000, 8, Color.TRANSPARENT));
        icon.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO);
        LinearLayout.LayoutParams iconParams = new LinearLayout.LayoutParams(dp(32), dp(32)); iconParams.rightMargin = dp(12); item.addView(icon, iconParams);
        LinearLayout words = column(); item.addView(words, new LinearLayout.LayoutParams(0, -2, 1));
        LinearLayout first = row(); words.addView(first);
        TextView name = new TextView(this); name.setText(task.title()); name.setTextSize(16); name.setTextColor(ink);
        name.setSingleLine(true); name.setEllipsize(android.text.TextUtils.TruncateAt.END);
        first.addView(name, new LinearLayout.LayoutParams(0, -2, 1));
        TextView time = new TextView(this); time.setText(shortDate(task.eventAt())); time.setTextSize(12); time.setTextColor(muted);
        time.setPadding(dp(8), 0, 0, 0); first.addView(time);
        TaskData.Device source = snapshot.device(task.sourceId());
        String state = current ? noticeLabel(task.phase()) : "上次记录：" + noticeLabel(task.phase());
        TextView summary = text(words, state + " · " + (source == null ? "来源未知" : source.name()), 13, muted, false);
        summary.setPadding(0, dp(4), 0, 0); summary.setMaxLines(getResources().getConfiguration().fontScale > 1.3f ? 2 : 1);
        summary.setEllipsize(android.text.TextUtils.TruncateAt.END);
        item.setOnClickListener(view -> startActivity(ChatActivity.intent(this, session, task.sourceId(), task.id(), demo)));
        content.addView(item, new LinearLayout.LayoutParams(-1, -2));
        View divider = new View(this); divider.setBackgroundColor(line);
        LinearLayout.LayoutParams separator = new LinearLayout.LayoutParams(-1, dp(1)); separator.leftMargin = dp(60); content.addView(divider, separator);
    }

    /** 设置使用紧凑分组；连接详情和多电脑状态进入二级页，不增加后台接口。 */
    private void settingsScreen() {
        content.setPadding(dp(16), dp(12), dp(16), dp(24));
        settingsToolbar(settingsPage.isEmpty() ? "设置" : settingsPage);
        if (settingsPage.equals("云端连接")) { connectionSettings(); return; }
        if (settingsPage.equals("已连接电脑")) { computerSettings(); return; }
        if (settingsPage.equals("通知设置")) { notificationSettings(); return; }
        if (settingsPage.equals("关于")) { aboutSettings(); return; }
        LinearLayout account = settingsGroup("账号与连接");
        settingsRow(account, "账号", demo ? "合成示例" : session.account(), null);
        settingsRow(account, "云端连接", connectionLabel(), view -> openSettings("云端连接"));
        settingsRow(account, "已连接电脑", snapshot == null ? "尚未读取" : snapshot.devices().size() + " 台", view -> openSettings("已连接电脑"));
        LinearLayout notifications = settingsGroup("通知");
        settingsRow(notifications, "通知设置", notices.enabled() ? "已允许" : "未开启", view -> openSettings("通知设置"));
        settingsRow(notifications, "发送测试通知", "", view -> testNotification());
        LinearLayout about = settingsGroup("关于");
        settingsRow(about, "Codex Top", BuildConfig.VERSION_NAME, view -> openSettings("关于"));
        gap(content, 24);
        TextView exit = text(content, demo ? "退出示例，连接服务" : "退出登录", 15, red, false);
        exit.setGravity(Gravity.CENTER); exit.setMinimumHeight(dp(48)); exit.setBackground(ripple(surface));
        exit.setFocusable(true); exit.setOnClickListener(view -> {
            if (demo) { demo = false; snapshot = null; selected = null; tab = 0; settingsPage = ""; generation++; busy = false; render(); }
            else new AlertDialog.Builder(this).setTitle("退出这台手机？").setMessage("停止后台提醒并清除手机登录状态。").setNegativeButton("取消", null)
                .setPositiveButton("退出登录", (dialog, which) -> logout()).show();
        });
    }

    /** 固定小标题与返回图标；系统返回和顶栏返回共用同一导航规则。 */
    private void settingsToolbar(String title) {
        LinearLayout toolbar = row(); toolbar.setBackgroundColor(surface); toolbar.setMinimumHeight(dp(52));
        android.widget.ImageButton back = new android.widget.ImageButton(this);
        back.setImageResource(R.drawable.ic_back); back.setImageTintList(android.content.res.ColorStateList.valueOf(ink));
        back.setContentDescription("返回"); back.setPadding(dp(14), dp(14), dp(14), dp(14)); back.setBackground(ripple(surface));
        back.setOnClickListener(view -> navigateBack()); toolbar.addView(back, new LinearLayout.LayoutParams(dp(48), dp(48)));
        TextView heading = new TextView(this); heading.setText(title); heading.setTextSize(18); heading.setTextColor(ink);
        heading.setTypeface(Typeface.DEFAULT, Typeface.BOLD); toolbar.addView(heading, new LinearLayout.LayoutParams(0, -2, 1));
        root.addView(toolbar, 0);
    }

    /** 打开二级设置时重置滚动，不携带上一个长页面的滚动位置。 */
    private void openSettings(String page) { settingsPage = page; scroll.scrollTo(0, 0); render(); }

    /** 创建小标题加白底分组，所有行共用边界，避免每个设置都成为大卡片。 */
    private LinearLayout settingsGroup(String title) {
        TextView label = text(content, title, 13, muted, false); label.setPadding(dp(12), dp(12), 0, dp(8));
        LinearLayout group = column(); group.setBackground(shape(surface, 12, Color.TRANSPARENT));
        group.setClipToOutline(true); content.addView(group, new LinearLayout.LayoutParams(-1, -2)); gap(content, 8); return group;
    }

    /** 设置行至少 52dp；放大字体后改为上下排布，名称和值不争抢水平空间。 */
    private void settingsRow(LinearLayout parent, String title, String value, View.OnClickListener action) {
        if (parent.getChildCount() > 0) {
            View divider = new View(this); divider.setBackgroundColor(line);
            LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(-1, dp(1)); params.leftMargin = dp(14); params.rightMargin = dp(14); parent.addView(divider, params);
        }
        boolean large = getResources().getConfiguration().fontScale > 1.3f;
        LinearLayout row = row(); row.setMinimumHeight(dp(52)); row.setPadding(dp(14), dp(12), dp(14), dp(12));
        LinearLayout words = large ? column() : row(); row.addView(words, new LinearLayout.LayoutParams(0, -2, 1));
        TextView name = new TextView(this); name.setText(title); name.setTextSize(15); name.setTextColor(ink);
        words.addView(name, large ? new LinearLayout.LayoutParams(-1, -2) : new LinearLayout.LayoutParams(0, -2, 1));
        if (!value.isEmpty()) {
            TextView detail = new TextView(this); detail.setText(value); detail.setTextSize(13); detail.setTextColor(muted);
            detail.setPadding(large ? 0 : dp(10), large ? dp(4) : 0, 0, 0);
            if (!large) { detail.setMaxWidth(dp(156)); detail.setGravity(Gravity.END); }
            words.addView(detail, new LinearLayout.LayoutParams(large ? -1 : -2, -2));
        }
        if (action != null) {
            TextView arrow = new TextView(this); arrow.setText("›"); arrow.setTextSize(22); arrow.setTextColor(muted); arrow.setPadding(dp(12), 0, 0, 0);
            arrow.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO); row.addView(arrow);
            row.setBackground(ripple(surface)); row.setFocusable(true); row.setOnClickListener(action);
        }
        parent.addView(row, new LinearLayout.LayoutParams(-1, -2));
    }

    /** 服务连接与电脑在线分开描述，合成模式不显示真实连接成功。 */
    private String connectionLabel() {
        if (demo) return "合成示例";
        if (!message.isEmpty()) return "连接中断";
        if (snapshot == null) return busy ? "正在连接" : "尚未连接";
        return SystemClock.elapsedRealtime() - snapshot.receivedElapsed() <= TaskData.FRESH_MS ? "已连接" : "状态已过期";
    }

    /** 服务地址只在连接详情出现；刷新复用原快照请求，不新建探活接口。 */
    private void connectionSettings() {
        LinearLayout group = settingsGroup("服务状态");
        settingsRow(group, "连接", connectionLabel(), null);
        settingsRow(group, "服务地址", demo ? "合成数据，无真实服务器" : session.server(), null);
        settingsRow(group, "刷新连接", busy ? "正在刷新…" : "", view -> {
            if (busy) return;
            if (demo) snapshot = TaskData.demo(System.currentTimeMillis(), SystemClock.elapsedRealtime());
            else refresh();
            render();
        });
        if (!message.isEmpty()) compactNotice(message, red);
    }

    /** 使用已有来源快照显示多台电脑，只显示状态，不提供未经实现的设备管理操作。 */
    private void computerSettings() {
        if (snapshot == null) { compactNotice("尚未读取电脑信息，请到云端连接刷新。", muted); return; }
        LinearLayout group = settingsGroup(demo ? "合成电脑" : "来源电脑");
        if (snapshot.devices().isEmpty()) { compactNotice("还没有电脑共享状态。", muted); return; }
        for (TaskData.Device device : snapshot.devices()) {
            long age = snapshot.now(SystemClock.elapsedRealtime()) - device.observedAt();
            String state = !device.connected() ? "离线" : !device.readState().equals("ready") ? "读取异常"
                : !message.isEmpty() || age < 0 || age > TaskData.FRESH_MS ? "状态已过期" : "在线";
            settingsRow(group, device.name(), state, null);
        }
        compactNotice("每个对话归属固定的电脑，单台离线不代表其他电脑离线。", muted);
    }

    /** 通知权限与后台运行各自显示真实状态，不用无效开关承诺全天推送。 */
    private void notificationSettings() {
        LinearLayout group = settingsGroup("系统通知");
        settingsRow(group, "系统通知设置", notices.enabled() ? "已允许" : "未开启", view -> startActivity(new Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, getPackageName())));
        settingsRow(group, "发送测试通知", "", view -> testNotification());
        LinearLayout monitor = settingsGroup("临时后台提醒");
        settingsRow(monitor, MonitorService.running ? "停止后台提醒" : "开启 1 小时提醒", demo ? "示例不可开启" : MonitorService.running ? "已开启" : "未开启", demo ? null : view -> toggleMonitor());
        compactNotice("手动开启，最多持续 1 小时。每 15 秒检查一次，省电或断网可能延迟。", muted);
    }

    /** 关于页沿用原 Logo，并明确当前包与示例的性质。 */
    private void aboutSettings() {
        android.widget.ImageView logo = new android.widget.ImageView(this); logo.setImageResource(R.drawable.app_logo);
        logo.setContentDescription("Codex Top"); LinearLayout.LayoutParams size = new LinearLayout.LayoutParams(dp(64), dp(64));
        size.gravity = Gravity.CENTER_HORIZONTAL; size.topMargin = dp(24); size.bottomMargin = dp(16); content.addView(logo, size);
        LinearLayout group = settingsGroup("应用信息");
        settingsRow(group, "版本", BuildConfig.VERSION_NAME + (BuildConfig.DEBUG ? " · 调试包" : ""), null);
        settingsRow(group, "外观", "跟随系统", null);
        if (demo) compactNotice("当前为合成示例，没有连接真实电脑。", muted);
    }

    /** 保留与系统通知一致的三类状态文字，不显示只有颜色才能识别的标记。 */
    private String noticeLabel(String phase) { return switch (phase) { case "waiting" -> "需要你确认"; case "failed" -> "运行失败"; case "completed" -> "已完成"; default -> TaskData.label(phase); }; }

    /** 行内时间以服务端日期为基准，缺失时间不以手机当前时间补造。 */
    private String shortDate(long time) {
        if (time <= 0) return "未知";
        java.time.ZoneId zone = java.time.ZoneId.systemDefault();
        java.time.LocalDate day = java.time.Instant.ofEpochMilli(time).atZone(zone).toLocalDate();
        java.time.LocalDate today = java.time.Instant.ofEpochMilli(snapshot.now(SystemClock.elapsedRealtime())).atZone(zone).toLocalDate();
        if (day.equals(today)) return android.text.format.DateFormat.getTimeFormat(this).format(new Date(time));
        if (day.equals(today.minusDays(1))) return "昨天";
        return android.text.format.DateFormat.getDateFormat(this).format(new Date(time));
    }

    /** 列表提示用窄行呈现，不再占用大面积卡片或宣传文案。 */
    private void compactNotice(String value, int color) {
        TextView note = text(content, value, 13, color, false); note.setPadding(dp(16), dp(10), dp(16), dp(10));
        note.setAccessibilityLiveRegion(View.ACCESSIBILITY_LIVE_REGION_POLITE);
    }

    /** 原生水波纹不改变布局，整行与图标按钮共享一致的按压反馈。 */
    private android.graphics.drawable.RippleDrawable ripple(int color) {
        return new android.graphics.drawable.RippleDrawable(android.content.res.ColorStateList.valueOf(0x184477AA), shape(color, 0, Color.TRANSPARENT), null);
    }

    /** 请求通知权限后由用户再次点击测试，不能把授权弹窗当作已送达。 */
    private void testNotification() {
        if (android.os.Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS}, 7); return;
        }
        if (!notices.enabled()) { toast("请先在系统通知设置中打开任务提醒"); return; }
        notices.test(); toast("已提交本机测试通知，请查看通知栏");
    }

    /** 只有真实会话且通知可见时，才允许用户启动带常驻状态的后台服务。 */
    private void toggleMonitor() {
        if (MonitorService.running) { stopService(new Intent(this, MonitorService.class)); main.postDelayed(this::render, 200); return; }
        if (session == null || demo) return;
        if (!notices.enabled()) { testNotification(); return; }
        try { startForegroundService(new Intent(this, MonitorService.class)); main.postDelayed(this::render, 300); }
        catch (RuntimeException restricted) { toast("系统暂不允许后台提醒，请稍后重新开启"); }
    }

    /** 权限结果只更新权限状态，不自动替用户启动后台服务或发送实际任务提醒。 */
    @Override public void onRequestPermissionsResult(int request, String[] permissions, int[] results) {
        super.onRequestPermissionsResult(request, permissions, results);
        if (request == 7) { render(); toast(notices.enabled() ? "通知已允许，可以发送测试通知" : "通知仍未开启，可稍后到系统设置调整"); }
    }

    /** 先停止本地工作并清除会话，再尝试服务器撤销；断网时诚实说明远端未确认。 */
    private void logout() {
        SessionStore.Session old = session;
        generation++; stopService(new Intent(this, MonitorService.class)); notices.clear(); store.clear();
        session = null; snapshot = null; selected = null; demo = false; busy = false; tab = 0; message = ""; render();
        int requestGeneration = generation;
        worker.execute(() -> {
            try { api.logout(old); }
            catch (Exception failure) { main.post(() -> {
                if (!closed && generation == requestGeneration) { message = "手机已退出；服务器撤销未确认，请在服务端检查登录设备。"; render(); }
            }); }
        });
    }

    /** 按语义返回状态色，未知状态始终使用次要文字色。 */
    private int phaseColor(String phase) { return switch (phase) { case "running" -> blue; case "waiting" -> amber; case "completed" -> green; case "failed" -> red; default -> muted; }; }

    /** 添加不依赖颜色的说明条，读屏同样可以知道示例或网络异常。 */
    private void banner(String text, int color) { TextView note = text(content, text, 14, color, true); note.setPadding(0, 0, 0, dp(20)); }

    /** 空状态说明原因与下一步，避免用样例填充真实空列表。 */
    private void empty(String title, String detail) { gap(content, 24); text(content, title, 21, ink, true); gap(content, 12); text(content, detail, 15, muted, false); gap(content, 24); }

    /** 详情信息纵向排布，在大字号或长设备名下允许自然换行。 */
    private void property(String name, String value) { text(content, name, 13, muted, false); gap(content, 5); text(content, value, 17, ink, false); gap(content, 18); }

    /** 创建有显式标签的输入框，系统能读取标签且允许密码管理器识别。 */
    private EditText field(LinearLayout parent, String label, String hint, String value, int type) {
        TextView caption = text(parent, label, 14, ink, true); gap(parent, 8);
        EditText field = new EditText(this); field.setId(View.generateViewId()); caption.setLabelFor(field.getId());
        field.setTextSize(16); field.setTextColor(ink); field.setHintTextColor(muted); field.setHint(hint); field.setText(value);
        field.setSingleLine(true); field.setInputType(type); field.setPadding(dp(14), dp(12), dp(14), dp(12));
        field.setBackground(shape(surface, 10, line)); field.setMinimumHeight(dp(54));
        field.setAutofillHints(label.equals("密码") ? View.AUTOFILL_HINT_PASSWORD : label.equals("账号") ? View.AUTOFILL_HINT_USERNAME : "");
        parent.addView(field, new LinearLayout.LayoutParams(-1, -2)); gap(parent, 18); return field;
    }

    /** 主操作使用实色底，其他操作保持轻量；所有按钮有原生按压反馈。 */
    private Button button(LinearLayout parent, String label, boolean primary, View.OnClickListener action) {
        Button button = smallButton(label, primary); button.setOnClickListener(action);
        LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(-1, -2); params.topMargin = dp(8);
        parent.addView(button, params); return button;
    }

    /** 创建可换行的原生按钮，最小 48dp，兼容系统字体放大。 */
    private Button smallButton(String title, boolean selected) {
        Button button = new Button(this); button.setText(title); button.setAllCaps(false); button.setTextSize(15);
        button.setTextColor(new android.content.res.ColorStateList(new int[][]{new int[]{-android.R.attr.state_enabled}, new int[]{}}, new int[]{muted, selected ? surface : ink}));
        button.setMinHeight(dp(48)); button.setMinimumHeight(dp(48)); button.setPadding(dp(10), dp(10), dp(10), dp(10));
        button.setStateListAnimator(null); button.setElevation(0);
        android.graphics.drawable.StateListDrawable states = new android.graphics.drawable.StateListDrawable();
        states.addState(new int[]{-android.R.attr.state_enabled}, shape(background, 12, line));
        states.addState(new int[]{}, shape(selected ? blue : surface, 12, selected ? blue : line));
        button.setBackground(new android.graphics.drawable.RippleDrawable(android.content.res.ColorStateList.valueOf(0x224477DD), states, null));
        return button;
    }

    /** 添加跟随系统字号的文本，不固定行高或裁切中文。 */
    private TextView text(LinearLayout parent, String value, int size, int color, boolean bold) {
        TextView view = new TextView(this); view.setText(value); view.setTextSize(size); view.setTextColor(color);
        view.setTypeface(Typeface.create("sans-serif", bold ? Typeface.BOLD : Typeface.NORMAL)); view.setLineSpacing(dp(3), 1);
        parent.addView(view, new LinearLayout.LayoutParams(-1, -2)); return view;
    }

    /** 为相关信息区创建纯色圆角边界，不叠加阴影装饰。 */
    private GradientDrawable shape(int color, int radius, int border) {
        GradientDrawable shape = new GradientDrawable(); shape.setColor(color); shape.setCornerRadius(dp(radius)); shape.setStroke(dp(1), border); return shape;
    }

    /** 创建纵向容器，避免布局参数在不同父控件之间混用。 */
    private LinearLayout column() { LinearLayout layout = new LinearLayout(this); layout.setOrientation(LinearLayout.VERTICAL); return layout; }

    /** 创建横向容器，垂直居中用于统计与导航。 */
    private LinearLayout row() { LinearLayout layout = new LinearLayout(this); layout.setOrientation(LinearLayout.HORIZONTAL); layout.setGravity(Gravity.CENTER_VERTICAL); return layout; }

    /** 用统一间距控制内容节奏，数值单位为 dp。 */
    private void gap(LinearLayout parent, int size) { parent.addView(new View(this), new LinearLayout.LayoutParams(1, dp(size))); }

    /** 将逻辑尺寸转换为当前屏幕像素，避免在小米高密度屏幕上缩小触控目标。 */
    private int dp(int value) { return Math.round(value * getResources().getDisplayMetrics().density); }

    /** 缺失或非法时间显示未知，禁止用本机当前时间补造。 */
    private String date(long time) { return time <= 0 ? "未知" : DateFormat.getDateTimeInstance(DateFormat.SHORT, DateFormat.MEDIUM).format(new Date(time)); }

    /** 短操作结果使用系统提示，不把提示当成实际投递回执。 */
    private void toast(String message) { Toast.makeText(this, message, Toast.LENGTH_LONG).show(); }
}
