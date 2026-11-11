package com.cj.projectrecorder;

import android.content.Intent;
import android.net.Uri;
import android.os.Build;
import android.provider.Settings;

import androidx.core.content.FileProvider;

import com.getcapacitor.JSObject;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;

import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.security.MessageDigest;

/**
 * In-app APK update: download the release APK to the app cache, verify its
 * SHA-256 when the manifest provides one, then hand it to the system package
 * installer through the existing FileProvider.
 *
 * The APK must be signed with the same key as the installed app; Android will
 * reject a mismatched signature. Re-installing over the top keeps app data.
 */
@CapacitorPlugin(name = "AppUpdate")
public class AppUpdatePlugin extends Plugin {

    private static final String UPDATE_DIR = "updates";
    private volatile boolean cancelled = false;
    private volatile HttpURLConnection activeConnection = null;

    private File updateDir() {
        File dir = new File(getContext().getCacheDir(), UPDATE_DIR);
        if (!dir.exists()) {
            //noinspection ResultOfMethodCallIgnored
            dir.mkdirs();
        }
        return dir;
    }

    private File resolveApk(String fileName) {
        String name = fileName == null ? "" : fileName.trim();
        name = name.replaceAll("[^A-Za-z0-9._-]", "_");
        if (name.isEmpty()) name = "ProjectRecorder-latest.apk";
        if (!name.toLowerCase().endsWith(".apk")) name = "ProjectRecorder-latest.apk";
        return new File(updateDir(), name);
    }

    private boolean canRequestInstalls() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            return getContext().getPackageManager().canRequestPackageInstalls();
        }
        return true;
    }

    @PluginMethod
    public void canInstall(PluginCall call) {
        JSObject result = new JSObject();
        result.put("allowed", canRequestInstalls());
        call.resolve(result);
    }

    @PluginMethod
    public void openInstallSettings(PluginCall call) {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Intent intent = new Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES);
                intent.setData(Uri.parse("package:" + getContext().getPackageName()));
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                getContext().startActivity(intent);
            }
            call.resolve();
        } catch (Exception error) {
            call.reject("settings_failed", "settings_failed");
        }
    }

    @PluginMethod
    public void cancel(PluginCall call) {
        cancelled = true;
        HttpURLConnection connection = activeConnection;
        if (connection != null) {
            try {
                connection.disconnect();
            } catch (Exception ignored) {
            }
        }
        call.resolve();
    }

    @PluginMethod
    public void download(PluginCall call) {
        String url = call.getString("url");
        String fileName = call.getString("fileName", "ProjectRecorder-latest.apk");
        String expectedSha = call.getString("expectedSha256", "");
        if (url == null || url.trim().isEmpty()) {
            call.reject("empty_url", "empty_url");
            return;
        }
        final File target = resolveApk(fileName);
        cancelled = false;

        new Thread(() -> {
            HttpURLConnection connection = null;
            try {
                URL urlObject = new URL(url);
                connection = (HttpURLConnection) urlObject.openConnection();
                activeConnection = connection;
                connection.setConnectTimeout(20000);
                connection.setReadTimeout(60000);
                connection.setInstanceFollowRedirects(true);
                connection.setRequestProperty("User-Agent", "ProjectRecorder-Android");
                connection.connect();
                int code = connection.getResponseCode();
                if (code < 200 || code >= 300) {
                    throw new IllegalStateException("http_" + code);
                }
                long total = connection.getContentLengthLong();
                MessageDigest digest = MessageDigest.getInstance("SHA-256");
                InputStream input = connection.getInputStream();
                FileOutputStream output = new FileOutputStream(target);
                byte[] buffer = new byte[8192];
                long downloaded = 0;
                int lastPercent = -1;
                int read;
                while ((read = input.read(buffer)) != -1) {
                    if (cancelled) throw new IllegalStateException("cancelled");
                    output.write(buffer, 0, read);
                    digest.update(buffer, 0, read);
                    downloaded += read;
                    if (total > 0) {
                        int percent = (int) Math.min(100, downloaded * 100 / total);
                        if (percent != lastPercent) {
                            lastPercent = percent;
                            JSObject progress = new JSObject();
                            progress.put("percent", percent);
                            progress.put("downloaded", downloaded);
                            progress.put("total", total);
                            notifyListeners("updateProgress", progress);
                        }
                    }
                }
                output.flush();
                output.close();
                input.close();
                String sha = toHex(digest.digest());
                if (expectedSha != null && !expectedSha.isEmpty()
                        && !sha.equalsIgnoreCase(expectedSha.trim())) {
                    //noinspection ResultOfMethodCallIgnored
                    target.delete();
                    call.reject("sha_mismatch", "sha_mismatch");
                    return;
                }
                JSObject done = new JSObject();
                done.put("fileName", target.getName());
                done.put("size", target.length());
                done.put("sha256", sha);
                call.resolve(done);
            } catch (Exception error) {
                //noinspection ResultOfMethodCallIgnored
                if (target.exists()) target.delete();
                call.reject("download_failed:" + error.getMessage(), "download_failed");
            } finally {
                if (connection != null) connection.disconnect();
                activeConnection = null;
            }
        }).start();
    }

    @PluginMethod
    public void install(PluginCall call) {
        String fileName = call.getString("fileName", "");
        File apk = resolveApk(fileName);
        if (!apk.exists()) {
            call.reject("apk_missing", "apk_missing");
            return;
        }
        if (!canRequestInstalls()) {
            call.reject("install_permission_required", "install_permission_required");
            return;
        }
        try {
            Uri uri = FileProvider.getUriForFile(
                    getContext(),
                    getContext().getPackageName() + ".fileprovider",
                    apk
            );
            Intent intent = new Intent(Intent.ACTION_VIEW);
            intent.setDataAndType(uri, "application/vnd.android.package-archive");
            intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            getContext().startActivity(intent);
            JSObject result = new JSObject();
            result.put("started", true);
            call.resolve(result);
        } catch (Exception error) {
            call.reject("installer_failed:" + error.getMessage(), "installer_failed");
        }
    }

    private static String toHex(byte[] bytes) {
        StringBuilder builder = new StringBuilder(bytes.length * 2);
        for (byte value : bytes) {
            builder.append(String.format("%02x", value));
        }
        return builder.toString();
    }
}
