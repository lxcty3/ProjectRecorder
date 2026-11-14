package com.cj.projectrecorder;

import android.Manifest;
import android.content.Intent;
import android.os.Build;
import android.util.Base64;

import com.getcapacitor.JSObject;
import com.getcapacitor.PermissionState;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;
import com.getcapacitor.annotation.Permission;
import com.getcapacitor.annotation.PermissionCallback;

import java.io.File;
import java.io.FileInputStream;
import java.io.ByteArrayOutputStream;

@CapacitorPlugin(
        name = "AudioRecorder",
        permissions = {
                @Permission(
                        alias = "microphone",
                        strings = { Manifest.permission.RECORD_AUDIO }
                )
        }
)
public class AudioRecorderPlugin extends Plugin {

    @PluginMethod
    public void start(PluginCall call) {
        if (getPermissionState("microphone") != PermissionState.GRANTED) {
            requestPermissionForAlias("microphone", call, "microphoneCallback");
            return;
        }
        startRecording(call);
    }

    @PermissionCallback
    private void microphoneCallback(PluginCall call) {
        if (getPermissionState("microphone") == PermissionState.GRANTED) {
            startRecording(call);
        } else {
            call.reject("microphone permission denied");
        }
    }

    private void startRecording(PluginCall call) {
        String meetingId = call.getString("meetingId", "");
        if (meetingId == null || meetingId.isEmpty()) {
            call.reject("meetingId is required");
            return;
        }
        if (AudioRecorderService.recording) {
            call.reject("already recording");
            return;
        }
        Intent intent = new Intent(getContext(), AudioRecorderService.class);
        intent.setAction(AudioRecorderService.ACTION_START);
        intent.putExtra(AudioRecorderService.EXTRA_MEETING, meetingId);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            getContext().startForegroundService(intent);
        } else {
            getContext().startService(intent);
        }
        JSObject result = new JSObject();
        result.put("started", true);
        result.put("meetingId", meetingId);
        result.put("startedAt", System.currentTimeMillis());
        call.resolve(result);
    }

    @PluginMethod
    public void stop(PluginCall call) {
        String path = AudioRecorderService.outputPath;
        stopService();
        // Wait briefly for MediaRecorder to finalize the MP4 file.
        long deadline = System.currentTimeMillis() + 2500;
        while (AudioRecorderService.recording && System.currentTimeMillis() < deadline) {
            try { Thread.sleep(80); } catch (InterruptedException ignored) {}
        }
        File file = path == null || path.isEmpty() ? null : new File(path);
        if (file == null || !file.exists() || file.length() == 0) {
            call.reject("recording file is empty");
            return;
        }
        new Thread(() -> {
            try {
                byte[] bytes = readAll(file);
                JSObject result = new JSObject();
                result.put("path", file.getAbsolutePath());
                result.put("size", bytes.length);
                result.put("mime", "audio/mp4");
                result.put("base64", Base64.encodeToString(bytes, Base64.NO_WRAP));
                call.resolve(result);
            } catch (Exception error) {
                call.reject("read recording failed: " + error.getMessage());
            }
        }).start();
    }

    @PluginMethod
    public void cancel(PluginCall call) {
        String path = AudioRecorderService.outputPath;
        stopService();
        if (path != null && !path.isEmpty()) {
            File file = new File(path);
            if (file.exists()) file.delete();
        }
        call.resolve();
    }

    @PluginMethod
    public void status(PluginCall call) {
        JSObject result = new JSObject();
        result.put("recording", AudioRecorderService.recording);
        result.put("meetingId", AudioRecorderService.meetingId);
        result.put("startedAt", AudioRecorderService.startedAt);
        call.resolve(result);
    }

    private void stopService() {
        Intent intent = new Intent(getContext(), AudioRecorderService.class);
        intent.setAction(AudioRecorderService.ACTION_STOP);
        getContext().startService(intent);
    }

    private static byte[] readAll(File file) throws Exception {
        try (FileInputStream input = new FileInputStream(file);
             ByteArrayOutputStream output = new ByteArrayOutputStream()) {
            byte[] buffer = new byte[8192];
            int read;
            while ((read = input.read(buffer)) != -1) {
                output.write(buffer, 0, read);
            }
            return output.toByteArray();
        }
    }
}
