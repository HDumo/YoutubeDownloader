package com.hdumo.ytdownloader;

import android.Manifest;
import android.app.Activity;
import android.app.DownloadManager;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.graphics.Color;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Environment;
import android.text.InputType;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.webkit.CookieManager;
import android.webkit.DownloadListener;
import android.webkit.JavascriptInterface;
import android.webkit.URLUtil;
import android.webkit.WebResourceError;
import android.webkit.WebResourceRequest;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.Button;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

/**
 * Thin native wrapper around the YouTube Downloader phone web app.
 * It remembers the server address (your Windows PC, or this phone via Termux), shows the web app
 * full screen, and saves downloaded MP3/MP4 files into the phone's Downloads folder.
 */
public class MainActivity extends Activity {
    private static final String PREFS = "ytdl";
    private static final String KEY_SERVER = "server";
    private static final String LOCAL_SERVER = "http://127.0.0.1:8765";
    private static final int DEFAULT_PORT = 8765;

    private SharedPreferences prefs;
    private WebView web;
    private LinearLayout setupPanel;
    private LinearLayout errorPanel;
    private EditText serverBox;
    private TextView setupMessage;
    private TextView errorText;
    private String serverUrl = "";

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        prefs = getSharedPreferences(PREFS, MODE_PRIVATE);
        getWindow().setStatusBarColor(0xFF1F2937);

        FrameLayout root = new FrameLayout(this);
        root.setBackgroundColor(0xFFF3F4F6);

        web = new WebView(this);
        configureWebView();
        root.addView(web, new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));

        setupPanel = buildSetupPanel();
        errorPanel = buildErrorPanel();
        root.addView(setupPanel, new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
        root.addView(errorPanel, new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
        setContentView(root);

        askStoragePermissionIfNeeded();

        String saved = prefs.getString(KEY_SERVER, "");
        if (saved.length() == 0) {
            showSetup("");
        } else {
            loadServer(saved);
        }
    }

    // ------------------------------------------------------------------ web view
    private void configureWebView() {
        WebSettings s = web.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        s.setAllowFileAccess(false);
        s.setAllowContentAccess(false);
        s.setSupportZoom(false);
        s.setMixedContentMode(WebSettings.MIXED_CONTENT_COMPATIBILITY_MODE);
        CookieManager.getInstance().setAcceptCookie(true);
        web.addJavascriptInterface(new Bridge(), "Android");

        web.setWebViewClient(new WebViewClient() {
            // Called on Android 7+ (API 24); compiled against API 23 stubs, so no @Override here.
            public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
                return openExternally(request.getUrl());
            }

            @Override
            @SuppressWarnings("deprecation")
            public boolean shouldOverrideUrlLoading(WebView view, String url) {
                return openExternally(Uri.parse(url));
            }

            @Override
            public void onReceivedError(WebView view, WebResourceRequest request, WebResourceError error) {
                if (request.isForMainFrame()) {
                    showError(String.valueOf(error.getDescription()));
                }
            }

            @Override
            public void onPageFinished(WebView view, String url) {
                CookieManager.getInstance().flush();
            }
        });

        web.setDownloadListener(new DownloadListener() {
            @Override
            public void onDownloadStart(String url, String userAgent, String contentDisposition, String mimeType, long length) {
                saveToDownloads(url, userAgent, contentDisposition, mimeType);
            }
        });
    }

    /** Links that leave the downloader server open in the normal browser instead of inside the app. */
    private boolean openExternally(Uri target) {
        Uri base = Uri.parse(serverUrl);
        boolean sameHost = target.getHost() != null && target.getHost().equalsIgnoreCase(base.getHost())
                && portOf(target) == portOf(base);
        if (sameHost) {
            return false;
        }
        try {
            startActivity(new Intent(Intent.ACTION_VIEW, target));
        } catch (Exception ignored) {
            // no browser available - ignore
        }
        return true;
    }

    private static int portOf(Uri u) {
        if (u.getPort() != -1) {
            return u.getPort();
        }
        return "https".equalsIgnoreCase(u.getScheme()) ? 443 : 80;
    }

    private void saveToDownloads(String url, String userAgent, String contentDisposition, String mimeType) {
        try {
            String name = URLUtil.guessFileName(url, contentDisposition, mimeType);
            DownloadManager.Request r = new DownloadManager.Request(Uri.parse(url));
            String cookie = CookieManager.getInstance().getCookie(url);
            if (cookie != null) {
                r.addRequestHeader("Cookie", cookie);       // the PIN sign-in cookie
            }
            if (userAgent != null) {
                r.addRequestHeader("User-Agent", userAgent);
            }
            r.setTitle(name);
            r.setMimeType(mimeType);
            r.allowScanningByMediaScanner();
            r.setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED);
            r.setDestinationInExternalPublicDir(Environment.DIRECTORY_DOWNLOADS, "YouTubeDownloader/" + name);
            DownloadManager dm = (DownloadManager) getSystemService(Context.DOWNLOAD_SERVICE);
            dm.enqueue(r);
            Toast.makeText(this, "Saving " + name + " to Downloads/YouTubeDownloader", Toast.LENGTH_LONG).show();
        } catch (Exception e) {
            Toast.makeText(this, "Could not save the file: " + e.getMessage(), Toast.LENGTH_LONG).show();
        }
    }

    private void askStoragePermissionIfNeeded() {
        // Android 9 and older need this permission to write into the public Downloads folder.
        if (Build.VERSION.SDK_INT >= 23 && Build.VERSION.SDK_INT <= 28
                && checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[]{Manifest.permission.WRITE_EXTERNAL_STORAGE}, 1);
        }
    }

    /** Called from the web page ("Change server" button). */
    private class Bridge {
        @JavascriptInterface
        public void changeServer() {
            runOnUiThread(new Runnable() {
                @Override
                public void run() {
                    showSetup(serverUrl);
                }
            });
        }
    }

    // ------------------------------------------------------------------ screens
    private void loadServer(String url) {
        serverUrl = url;
        prefs.edit().putString(KEY_SERVER, url).apply();
        setupPanel.setVisibility(View.GONE);
        errorPanel.setVisibility(View.GONE);
        web.loadUrl(url);
    }

    private void showSetup(String prefill) {
        serverBox.setText(prefill == null || prefill.length() == 0 ? "http://" : prefill);
        serverBox.setSelection(serverBox.getText().length());
        setupMessage.setText("");
        errorPanel.setVisibility(View.GONE);
        setupPanel.setVisibility(View.VISIBLE);
    }

    private void showError(String description) {
        errorText.setText("Could not reach the downloader at\n" + serverUrl + "\n\n" + description
                + "\n\nCheck that the phone server is running and that this phone is on the same Wi-Fi.");
        errorPanel.setVisibility(View.VISIBLE);
    }

    /** Turns "192.168.1.20" or "pc-name:9000/" into "http://192.168.1.20:8765" style addresses. */
    static String normalizeServer(String raw) {
        String t = raw == null ? "" : raw.trim();
        if (t.length() == 0 || t.equals("http://") || t.equals("https://")) {
            return null;
        }
        if (!t.toLowerCase().startsWith("http://") && !t.toLowerCase().startsWith("https://")) {
            t = "http://" + t;
        }
        Uri u = Uri.parse(t);
        if (u.getHost() == null || u.getHost().length() == 0) {
            return null;
        }
        int port = u.getPort();
        String scheme = u.getScheme().toLowerCase();
        StringBuilder sb = new StringBuilder(scheme).append("://").append(u.getHost());
        if (port != -1) {
            sb.append(':').append(port);
        } else if (scheme.equals("http")) {
            sb.append(':').append(DEFAULT_PORT);
        }
        return sb.toString();
    }

    private LinearLayout column() {
        LinearLayout l = new LinearLayout(this);
        l.setOrientation(LinearLayout.VERTICAL);
        l.setPadding(dp(24), dp(24), dp(24), dp(24));
        return l;
    }

    private TextView text(String s, int sp, int color, boolean bold) {
        TextView t = new TextView(this);
        t.setText(s);
        t.setTextSize(sp);
        t.setTextColor(color);
        if (bold) {
            t.setTypeface(t.getTypeface(), android.graphics.Typeface.BOLD);
        }
        t.setPadding(0, dp(6), 0, dp(6));
        return t;
    }

    private Button button(String s, boolean primary) {
        Button b = new Button(this);
        b.setText(s);
        b.setAllCaps(false);
        b.setTextSize(16);
        b.setMinHeight(dp(52));
        if (primary) {
            b.setBackgroundColor(0xFFDC2626);
            b.setTextColor(Color.WHITE);
        }
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        lp.topMargin = dp(12);
        b.setLayoutParams(lp);
        return b;
    }

    private LinearLayout buildSetupPanel() {
        LinearLayout outer = new LinearLayout(this);
        outer.setBackgroundColor(0xFFF3F4F6);
        outer.setOrientation(LinearLayout.VERTICAL);
        ScrollView scroll = new ScrollView(this);
        LinearLayout col = column();
        col.addView(text("YouTube Downloader", 24, 0xFF111827, true));
        col.addView(text("Type the address of your downloader server. It is shown in the window where the phone server runs "
                + "(for example http://192.168.1.20:8765). Your phone must be on the same Wi-Fi.", 15, 0xFF4B5563, false));
        serverBox = new EditText(this);
        serverBox.setSingleLine(true);
        serverBox.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_URI);
        serverBox.setHint("http://192.168.1.20:8765");
        serverBox.setTextSize(18);
        col.addView(serverBox, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));
        setupMessage = text("", 14, 0xFFB91C1C, false);
        col.addView(setupMessage);

        Button connect = button("Connect", true);
        connect.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                String url = normalizeServer(serverBox.getText().toString());
                if (url == null) {
                    setupMessage.setText("That does not look like an address. Example: http://192.168.1.20:8765");
                    return;
                }
                loadServer(url);
            }
        });
        col.addView(connect);

        Button local = button("This phone (Termux)  -  127.0.0.1", false);
        local.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                loadServer(LOCAL_SERVER);
            }
        });
        col.addView(local);
        col.addView(text("Using this phone as the server needs the free Termux app - see the setup guide in the project's docs.", 13, 0xFF6B7280, false));
        scroll.addView(col);
        outer.addView(scroll, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
        return outer;
    }

    private LinearLayout buildErrorPanel() {
        LinearLayout outer = new LinearLayout(this);
        outer.setBackgroundColor(0xFFF3F4F6);
        outer.setOrientation(LinearLayout.VERTICAL);
        outer.setGravity(Gravity.CENTER);
        LinearLayout col = column();
        col.addView(text("Can't connect", 22, 0xFF111827, true));
        errorText = text("", 15, 0xFF4B5563, false);
        col.addView(errorText);
        Button retry = button("Try again", true);
        retry.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                errorPanel.setVisibility(View.GONE);
                web.loadUrl(serverUrl);
            }
        });
        col.addView(retry);
        Button change = button("Change server", false);
        change.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                showSetup(serverUrl);
            }
        });
        col.addView(change);
        outer.addView(col, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));
        return outer;
    }

    private int dp(int v) {
        return (int) (v * getResources().getDisplayMetrics().density + 0.5f);
    }

    @Override
    public void onBackPressed() {
        if (setupPanel.getVisibility() == View.VISIBLE && serverUrl.length() > 0) {
            setupPanel.setVisibility(View.GONE);
        } else if (web.canGoBack()) {
            web.goBack();
        } else {
            super.onBackPressed();
        }
    }

    @Override
    protected void onPause() {
        CookieManager.getInstance().flush();
        super.onPause();
    }
}
