package app.roadtrip;

import android.content.Context;
import android.content.Intent;
import android.graphics.PixelFormat;
import android.os.Bundle;

import org.libsdl.app.SDLSurface;
import org.love2d.android.GameActivity;

/**
 * LÖVE's activity, plus one thing a launcher needs: knowing when the Home button is pressed
 * while Road Trip is already running. Android delivers that as a new HOME intent, which LÖVE
 * ignores; this counts them and Lua polls the count (LauncherBridge "homePresses").
 */
public class RoadTripActivity extends GameActivity {
    static volatile int homePresses = 0;

    // With the MapLibre map, LÖVE's surface goes over it and is see-through where Lua leaves
    // a hole (MapNative). That has to be set before the surface exists.
    @Override
    protected SDLSurface createSDLSurface(Context context) {
        SDLSurface s = super.createSDLSurface(context);
        if (MapNative.wanted(context)) {
            s.getHolder().setFormat(PixelFormat.TRANSLUCENT);
            s.setZOrderMediaOverlay(true);
        }
        return s;
    }

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        if (MapNative.wanted(this) && mLayout != null) MapNative.attach(this, mLayout);
    }

    @Override
    protected void onStart() {
        super.onStart();
        MapNative.onStart();
    }

    @Override
    protected void onStop() {
        MapNative.onStop();
        super.onStop();
    }

    @Override
    protected void onDestroy() {
        MapNative.onDestroy();
        super.onDestroy();
    }

    @Override
    public void onLowMemory() {
        super.onLowMemory();
        MapNative.onLowMemory();
    }

    @Override
    protected void onResume() {
        super.onResume();
        Overlay.roadTripResumed = true;
        MapNative.onResume();
    }

    @Override
    protected void onPause() {
        Overlay.roadTripResumed = false;
        MapNative.onPause();
        super.onPause();
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        if (intent != null && Intent.ACTION_MAIN.equals(intent.getAction())
                && intent.hasCategory(Intent.CATEGORY_HOME)) {
            homePresses++;
        }
    }
}
