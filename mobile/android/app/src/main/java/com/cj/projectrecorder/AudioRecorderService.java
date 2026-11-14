package com.cj.projectrecorder;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.media.MediaRecorder;
import android.os.Build;
import android.os.IBinder;

import androidx.core.app.NotificationCompat;

import java.io.File;

/** Foreground audio recorder so meetings keep recording with the screen off. */
public class AudioRecorderService extends Service {

    public static final String ACTION_START = "com.cj.projectrecorder.RECORD_START";
    public static final String ACTION_STOP = "com.cj.projectrecorder.RECORD_STOP";
    public static final String EXTRA_MEETING = "meeting_id";

    public static volatile boolean recording = false;
    public static volatile String meetingId = "";
    public static volatile long startedAt = 0L;
    public static volatile String outputPath = "";

    private static final String CHANNEL = "meeting-recording";
    private MediaRecorder recorder;

    @Override
    public IBinder onBind(Intent intent) { return null; }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent == null) return START_NOT_STICKY;
        String action = intent.getAction();
        if (ACTION_STOP.equals(action)) {
            stopRecording();
            return START_NOT_STICKY;
        }
        String id = intent.getStringExtra(EXTRA_MEETING);
        if (ACTION_START.equals(action) && id != null && !recording) {
            startRecording(id);
        }
        return START_STICKY;
    }

    private void startRecording(String id) {
        try {
            File dir = new File(getFilesDir(), "meetings");
            if (!dir.exists()) dir.mkdirs();
            File output = new File(dir, id + ".m4a");
            recorder = new MediaRecorder();
            recorder.setAudioSource(MediaRecorder.AudioSource.MIC);
            recorder.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4);
            recorder.setAudioEncoder(MediaRecorder.AudioEncoder.AAC);
            recorder.setAudioSamplingRate(16000);
            recorder.setAudioEncodingBitRate(24000);
            recorder.setAudioChannels(1);
            recorder.setOutputFile(output.getAbsolutePath());
            recorder.prepare();
            recorder.start();
            recording = true;
            meetingId = id;
            startedAt = System.currentTimeMillis();
            outputPath = output.getAbsolutePath();
            startForeground(7101, buildNotification());
        } catch (Exception error) {
            recording = false;
            outputPath = "";
            try { if (recorder != null) recorder.release(); } catch (Exception ignored) {}
            recorder = null;
            stopSelf();
        }
    }

    private Notification buildNotification() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            NotificationManager manager =
                    (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
            NotificationChannel channel = new NotificationChannel(
                    CHANNEL, "Meeting recording", NotificationManager.IMPORTANCE_LOW);
            channel.setDescription("Shown while a meeting is recording");
            if (manager != null) manager.createNotificationChannel(channel);
        }
        Intent open = new Intent(this, MainActivity.class);
        open.setFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP);
        PendingIntent pending = PendingIntent.getActivity(
                this, 0, open,
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.M
                        ? PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE
                        : PendingIntent.FLAG_UPDATE_CURRENT);
        return new NotificationCompat.Builder(this, CHANNEL)
                .setSmallIcon(android.R.drawable.ic_btn_speak_now)
                .setContentTitle("正在录音")
                .setContentText("会议录音进行中，锁屏也会继续")
                .setOngoing(true)
                .setContentIntent(pending)
                .build();
    }

    private void stopRecording() {
        try {
            if (recorder != null) recorder.stop();
        } catch (Exception ignored) {
        }
        try {
            if (recorder != null) recorder.release();
        } catch (Exception ignored) {}
        recorder = null;
        recording = false;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE);
        } else {
            stopForeground(true);
        }
        stopSelf();
    }

    @Override
    public void onDestroy() {
        if (recording) stopRecording();
        super.onDestroy();
    }
}
