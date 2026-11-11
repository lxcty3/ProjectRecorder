package com.cj.projectrecorder;

import android.os.Bundle;
import com.getcapacitor.BridgeActivity;

/** Main Capacitor activity; Getui initialization is explicitly consent-gated. */
public class MainActivity extends BridgeActivity {

    @Override
    public void onCreate(Bundle savedInstanceState) {
        // Push SDK initialization is explicitly consent-gated from JavaScript.
        registerPlugin(NotificationSettingsPlugin.class);
        registerPlugin(GetuiPushPlugin.class);
        registerPlugin(AppUpdatePlugin.class);
        super.onCreate(savedInstanceState);
    }
}
