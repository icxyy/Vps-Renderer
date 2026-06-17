package com.example.autorender;

import net.fabricmc.api.ClientModInitializer;
import net.fabricmc.fabric.api.client.event.lifecycle.v1.ClientTickEvents;
import net.fabricmc.loader.api.FabricLoader;
import net.minecraft.client.Minecraft;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.io.File;
import java.io.FileWriter;
import java.lang.reflect.Constructor;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.util.Map;

/**
 * AutoRender — headless ReplayMod render trigger.
 *
 * Flow (client tick state machine):
 *   WAIT_MENU   -> title screen aane ka wait (game fully loaded)
 *   START       -> replay_recordings/<file> ko ReplayMod se kholo
 *   WAIT_LOADED -> ReplayHandler ready hone ka wait
 *   RENDER      -> saved timeline pick karke VideoRenderer chalao (blocking)
 *   DONE        -> done-marker likho + quit
 *
 * NOTE: ReplayMod ki internal API version-dar-version thodi badalti hai, isliye
 * yahan reflection use kiya hai — mod kisi bhi ReplayMod jar ke saath COMPILE ho
 * jaata hai. Agar runtime pe koi method/constructor na mile, log me saaf dikhega
 * ki kaunsa — wahi ek method (buildRenderSettings / startReplay) tweak karna.
 * Reference target: ReplayMod 26.1.x @ MC 26.1.2 (unobfuscated / Mojang mappings).
 */
public class AutoRenderMod implements ClientModInitializer {
    public static final Logger LOG = LoggerFactory.getLogger("AutoRender");

    private enum State { WAIT_MENU, START, WAIT_LOADED, RENDER, DONE, IDLE }
    private State state = State.WAIT_MENU;
    private RenderConfig cfg;
    private int ticks = 0;
    private Object replayHandler;

    @Override
    public void onInitializeClient() {
        cfg = RenderConfig.load(FabricLoader.getInstance().getGameDir().toFile());
        if (!cfg.valid) {
            LOG.warn("[AutoRender] valid config nahi — normal client ki tarah idle rahunga.");
            state = State.IDLE;
        } else {
            LOG.info("[AutoRender] armed. replay={} timeline='{}' {}x{}@{}fps",
                    cfg.replay, cfg.timeline, cfg.width, cfg.height, cfg.fps);
        }
        ClientTickEvents.END_CLIENT_TICK.register(this::onTick);
    }

    private void onTick(Minecraft mc) {
        if (state == State.IDLE || state == State.DONE) return;
        ticks++;
        try {
            switch (state) {
                case WAIT_MENU -> {
                    // Title screen + thodi der ka buffer (resource load hone do)
                    if (mc.screen != null && ticks > 60) {
                        state = State.START;
                    }
                }
                case START -> {
                    File gameDir = FabricLoader.getInstance().getGameDir().toFile();
                    File replayFile = new File(gameDir, "replay_recordings/" + cfg.replay);
                    if (!replayFile.isFile()) { fail("replay file nahi mila: " + replayFile); return; }
                    LOG.info("[AutoRender] replay khol raha hu: {}", replayFile.getName());
                    replayHandler = startReplay(replayFile);
                    state = State.WAIT_LOADED;
                    ticks = 0;
                }
                case WAIT_LOADED -> {
                    // ReplayMod ko replay load karne ka time do
                    if (ticks > 100 && mc.level != null) {
                        state = State.RENDER;
                    } else if (ticks > 1200) {
                        fail("replay 60s me load nahi hua");
                    }
                }
                case RENDER -> {
                    state = State.DONE; // re-entry rok do; render blocking hai
                    LOG.info("[AutoRender] render shuru...");
                    File out = renderTimeline();
                    writeDone(out);
                    LOG.info("[AutoRender] render complete: {}", out);
                    if (cfg.quitWhenDone) {
                        quitGame(mc);
                    }
                }
                default -> {}
            }
        } catch (Throwable t) {
            fail("exception: " + t);
            LOG.error("[AutoRender] state " + state + " me crash", t);
        }
    }

    // ---------------------------------------------------------------------
    // ReplayMod reflection bridge
    // ---------------------------------------------------------------------

    /** ReplayModReplay.instance.startReplay(file) -> ReplayHandler */
    private Object startReplay(File file) throws Exception {
        Class<?> rmReplay = Class.forName("com.replaymod.replay.ReplayModReplay");
        Object instance = staticField(rmReplay, "instance");
        if (instance == null) instance = staticField(rmReplay, "INSTANCE");
        if (instance == null) throw new IllegalStateException("ReplayModReplay.instance null");

        // startReplay(File) ya startReplay(File, ...) — File arg wala dhundo
        for (Method m : rmReplay.getMethods()) {
            if (m.getName().equals("startReplay")
                    && m.getParameterCount() >= 1
                    && m.getParameterTypes()[0] == File.class) {
                Object[] args = new Object[m.getParameterCount()];
                args[0] = file;
                return m.invoke(instance, args);
            }
        }
        throw new NoSuchMethodException("ReplayModReplay.startReplay(File) nahi mila");
    }

    /**
     * Saved timeline pick karke VideoRenderer chalata hai. Return: output file.
     * Yahi method version-sensitive hai — RenderSettings constructor / timeline
     * source agar badle to yahan adjust karo.
     */
    private File renderTimeline() throws Exception {
        // 1. ReplayFile -> timelines map
        Object replayFile = invokeFirst(replayHandler, "getReplayFile", "getReplay");
        Object timelinesObj = invokeFirst(replayFile, "getTimelines");
        if (!(timelinesObj instanceof Map<?, ?> timelines) || timelines.isEmpty()) {
            throw new IllegalStateException("Koi saved timeline nahi mila .mcpr me — "
                    + "laptop pe ReplayMod me timeline SAVE kiya tha?");
        }
        Object timeline;
        if (!cfg.timeline.isEmpty() && timelines.containsKey(cfg.timeline)) {
            timeline = timelines.get(cfg.timeline);
        } else {
            Map.Entry<?, ?> e = timelines.entrySet().iterator().next();
            LOG.info("[AutoRender] timeline '{}' use kar raha hu", e.getKey());
            timeline = e.getValue();
        }

        // 2. Output file
        cfg.outputDir.mkdirs();
        String base = cfg.replay.replaceAll("\\.mcpr$", "");
        File outFile = new File(cfg.outputDir, base + ".mp4");

        // 3. RenderSettings banao (reflection — sabse pehla constructor jo fit ho)
        Object settings = buildRenderSettings(outFile);

        // 4. new VideoRenderer(settings, replayHandler, timeline).renderVideo()
        Class<?> vrClass = Class.forName("com.replaymod.render.rendering.VideoRenderer");
        Constructor<?> ctor = null;
        for (Constructor<?> c : vrClass.getConstructors()) {
            if (c.getParameterCount() == 3) { ctor = c; break; }
        }
        if (ctor == null) throw new NoSuchMethodException("VideoRenderer 3-arg ctor nahi mila");
        Object renderer = ctor.newInstance(settings, replayHandler, timeline);

        Method renderVideo = findMethod(vrClass, "renderVideo");
        if (renderVideo == null) renderVideo = findMethod(vrClass, "render");
        renderVideo.invoke(renderer);   // blocking — frames likhe jaate hain

        return outFile;
    }

    /**
     * RenderSettings reflection se. Default BLEND/MP4 method, di gayi res/fps.
     * ReplayMod 26.1.x constructor param order pe based — agar tumhari build alag
     * ho to log dekho aur niche values map karo.
     */
    private Object buildRenderSettings(File outFile) throws Exception {
        Class<?> rsClass = Class.forName("com.replaymod.render.RenderSettings");

        // RenderMethod.BLEND (default video) + EncodingPreset.MP4_DEFAULT type enums
        Object renderMethod = enumValueLoose(
                "com.replaymod.render.RenderSettings$RenderMethod", "BLEND", "DEFAULT");
        Object encodingPreset = enumValueLoose(
                "com.replaymod.render.RenderSettings$EncodingPreset", "MP4_DEFAULT", "MP4", "DEFAULT");

        // Sabse zyada params wala public constructor pakdo, aur known fields fill karo.
        Constructor<?> best = null;
        for (Constructor<?> c : rsClass.getConstructors()) {
            if (best == null || c.getParameterCount() > best.getParameterCount()) best = c;
        }
        if (best == null) throw new NoSuchMethodException("RenderSettings ctor nahi mila");

        Class<?>[] pt = best.getParameterTypes();
        Object[] args = new Object[pt.length];
        for (int i = 0; i < pt.length; i++) args[i] = defaultFor(pt[i]);

        // Known positions heuristically set karo (type-match based):
        boolean wSet = false, hSet = false, fpsSet = false, fileSet = false,
                methodSet = false, presetSet = false;
        for (int i = 0; i < pt.length; i++) {
            if (pt[i] == File.class && !fileSet)          { args[i] = outFile; fileSet = true; }
            else if (pt[i] == renderMethodType(rsClass) && renderMethod != null && !methodSet)
                                                          { args[i] = renderMethod; methodSet = true; }
            else if (encodingPreset != null && pt[i].isInstance(encodingPreset) && !presetSet)
                                                          { args[i] = encodingPreset; presetSet = true; }
            else if (pt[i] == int.class) {
                // teen int: width, height, fps — is order ka assume
                if (!wSet)        { args[i] = cfg.width;  wSet = true; }
                else if (!hSet)   { args[i] = cfg.height; hSet = true; }
                else if (!fpsSet) { args[i] = cfg.fps;    fpsSet = true; }
            }
        }
        LOG.info("[AutoRender] RenderSettings ctor ({} args): w={} h={} fps={} file={}",
                pt.length, wSet, hSet, fpsSet, fileSet);
        return best.newInstance(args);
    }

    // ---------------------------------------------------------------------
    // reflection utils
    // ---------------------------------------------------------------------
    private static Class<?> renderMethodType(Class<?> rsClass) {
        try { return Class.forName("com.replaymod.render.RenderSettings$RenderMethod"); }
        catch (Exception e) { return Void.class; }
    }

    private static Object staticField(Class<?> c, String name) {
        try { Field f = c.getField(name); return f.get(null); }
        catch (Exception e) { return null; }
    }

    private static Object invokeFirst(Object target, String... names) throws Exception {
        for (String n : names) {
            Method m = findMethod(target.getClass(), n);
            if (m != null) return m.invoke(target);
        }
        throw new NoSuchMethodException("koi method nahi mila: " + String.join("/", names)
                + " on " + target.getClass());
    }

    private static Method findMethod(Class<?> c, String name) {
        for (Method m : c.getMethods()) if (m.getName().equals(name) && m.getParameterCount() == 0) return m;
        return null;
    }

    private static Object enumValueLoose(String enumClass, String... candidates) {
        try {
            Class<?> ec = Class.forName(enumClass);
            Object[] consts = ec.getEnumConstants();
            for (String want : candidates)
                for (Object e : consts)
                    if (e.toString().equalsIgnoreCase(want)) return e;
            return consts.length > 0 ? consts[0] : null;   // fallback: pehla
        } catch (Exception e) { return null; }
    }

    private static Object defaultFor(Class<?> t) {
        if (!t.isPrimitive()) return null;
        if (t == boolean.class) return false;
        if (t == int.class)     return 0;
        if (t == long.class)    return 0L;
        if (t == float.class)   return 0f;
        if (t == double.class)  return 0d;
        if (t == short.class)   return (short) 0;
        if (t == byte.class)    return (byte) 0;
        if (t == char.class)    return (char) 0;
        return null;
    }

    // ---------------------------------------------------------------------
    private void writeDone(File out) {
        try {
            cfg.doneMarker.getParentFile().mkdirs();
            try (FileWriter w = new FileWriter(cfg.doneMarker)) {
                w.write(out.getAbsolutePath() + "\n");
            }
        } catch (Exception e) {
            LOG.error("[AutoRender] done-marker likhne me fail", e);
        }
    }

    private void fail(String msg) {
        LOG.error("[AutoRender] FAIL: {}", msg);
        try {
            cfg.doneMarker.getParentFile().mkdirs();
            try (FileWriter w = new FileWriter(new File(cfg.doneMarker.getParentFile(),
                    ".autorender_error"))) {
                w.write(msg + "\n");
            }
        } catch (Exception ignored) {}
        state = State.DONE;
        if (cfg.quitWhenDone) quitGame(Minecraft.getInstance());
    }

    /**
     * Game ko gracefully band karta hai. 26.1 unobfuscated hai isliye runtime
     * method names = source names; reflection se "scheduleStop" (clean) ya "stop"
     * try karte hain taaki mapping-name pe hard dependency na ho.
     */
    private static void quitGame(Minecraft mc) {
        for (String name : new String[]{"scheduleStop", "stop"}) {
            try {
                Method m = mc.getClass().getMethod(name);
                m.invoke(mc);
                return;
            } catch (Exception ignored) {}
        }
        LOG.warn("[AutoRender] quit method nahi mila — process khud band karna padega.");
    }
}
