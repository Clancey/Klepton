// See kl_questlink.h. Two threads: one feeds the headset's poses and buttons
// into kl_ovrp at ~500 Hz, the other hands each completed guest frame to
// QuestLinkMac, which normalises it on the GPU after ANGLE's fence and encodes.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include "kl_questlink.h"

#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "kl_env.h"
#include "kl_driver.h"
#include "kl_glfb.h"
#include "kl_ovrp.h"
#include "kl_view.h"
#include "klepton/stream.h"

static qlks *g_link;
static qlks_device g_device;
static atomic_int g_quit;
static pthread_t g_pose_thread, g_frame_thread;
static int g_threads;
static id<MTLSharedEvent> g_own_fence;

// Latest head sample, for the OpenXR path's timed query (kl_ovrp_set_head_at).
static pthread_mutex_t g_head_lock = PTHREAD_MUTEX_INITIALIZER;
static qlks_pose g_head;
static int g_head_ok;

static double monotonic_s(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

// QuestLinkMac stamps samples on the mach clock; kl_ovrp dates them on
// CLOCK_MONOTONIC. Darwin does not promise those share an epoch, so the offset
// is measured each time rather than assumed.
static double sample_time_s(int64_t mach_ns) {
    double now_mono = monotonic_s();
    int64_t now_mach = qlks_now_ns();
    return now_mono - (double)(now_mach - mach_ns) * 1e-9;
}

static int head_at(double time_s, float *pose7) {
    (void)time_s;
    pthread_mutex_lock(&g_head_lock);
    int ok = g_head_ok;
    if (ok) {
        memcpy(pose7, g_head.orientation, sizeof(float) * 4);
        memcpy(pose7 + 4, g_head.position, sizeof(float) * 3);
    }
    pthread_mutex_unlock(&g_head_lock);
    return ok;
}

static uint32_t hand_buttons(int hand, const qlks_hand *h, uint32_t *touches) {
    uint32_t b = 0, t = 0;
    const uint32_t lower = hand ? KL_OVRP_RAW_A : KL_OVRP_RAW_X;
    const uint32_t upper = hand ? KL_OVRP_RAW_B : KL_OVRP_RAW_Y;
    const uint32_t stick = hand ? KL_OVRP_RAW_RTHUMBSTICK : KL_OVRP_RAW_LTHUMBSTICK;
    const uint32_t trig = hand ? KL_OVRP_RAW_RINDEX_TRIGGER : KL_OVRP_RAW_LINDEX_TRIGGER;
    const uint32_t grip = hand ? KL_OVRP_RAW_RHAND_TRIGGER : KL_OVRP_RAW_LHAND_TRIGGER;
    if (h->pressed & QLKS_BUTTON_LOWER) b |= lower;
    if (h->pressed & QLKS_BUTTON_UPPER) b |= upper;
    if (h->pressed & QLKS_BUTTON_STICK) b |= stick;
    if (h->pressed & QLKS_BUTTON_MENU) b |= KL_OVRP_RAW_START;
    // Analog trigger/grip as buttons need hysteresis, or a value resting near
    // the threshold reads as press/release every poll (a gun drop in SUPERHOT).
    static int held[2][2];
    held[hand][0] = h->trigger >= (held[hand][0] ? 0.35f : 0.55f);
    held[hand][1] = h->squeeze >= (held[hand][1] ? 0.35f : 0.55f);
    if (held[hand][0]) b |= trig;
    if (held[hand][1]) b |= grip;
    if (h->pressed & QLKS_TOUCH_LOWER) t |= lower;
    if (h->pressed & QLKS_TOUCH_UPPER) t |= upper;
    if (h->pressed & QLKS_TOUCH_STICK) t |= stick;
    if (h->pressed & QLKS_TOUCH_TRIGGER) t |= trig;
    if (h->squeeze > 0.05f) t |= grip;
    // Snap turn reads only the right stick's direction bits, never the axis.
    if (hand) {
        static int latch[4];
        const float on = 0.5f, off = 0.4f;
        const float v[4] = { h->stick[1], -h->stick[1], -h->stick[0], h->stick[0] };
        const uint32_t bit[4] = { KL_OVRP_RAW_RTHUMBSTICK_UP, KL_OVRP_RAW_RTHUMBSTICK_DOWN,
                                  KL_OVRP_RAW_RTHUMBSTICK_LEFT, KL_OVRP_RAW_RTHUMBSTICK_RIGHT };
        for (int i = 0; i < 4; i++) {
            latch[i] = v[i] >= (latch[i] ? off : on);
            if (latch[i]) b |= bit[i];
        }
    }
    *touches = t | b;
    return b;
}

static void *pose_main(void *arg) {
    (void)arg;
    pthread_setname_np("kl.questlink.pose");
    int64_t last_head = 0;
    int was_tracking = -1;
    // KL_QUESTLINK_PAUSE_MS: how long the headset may be gone before the guest
    // is paused (Android's onPause on headset removal); 0 never pauses.
    const double pause_after = kl_env_uint("KL_QUESTLINK_PAUSE_MS", 2000) / 1000.0;
    double lost_at = -1;
    while (!atomic_load(&g_quit)) {
        qlks_tracking tr;
        int live = qlks_poll(g_link, &tr);
        int tracking = live && tr.head_valid;
        if (tracking != was_tracking) {
            fprintf(stderr, "  [questlink] headset tracking %s\n", tracking ? "live" : "lost");
            if (!tracking && was_tracking == 1) lost_at = monotonic_s();
            was_tracking = tracking;
        }
        if (tracking) {
            if (kl_driver_paused()) fprintf(stderr, "  [questlink] headset back; resuming game\n");
            kl_driver_set_paused(0);
            lost_at = -1;
        } else if (pause_after > 0 && lost_at >= 0 && monotonic_s() - lost_at >= pause_after) {
            fprintf(stderr, "  [questlink] headset gone %.1f s; pausing game\n", pause_after);
            kl_driver_set_paused(1);
            lost_at = -1;
        }
        if (tr.head_valid && tr.head_sample_ns != last_head) {
            last_head = tr.head_sample_ns;
            pthread_mutex_lock(&g_head_lock);
            g_head = tr.head;
            g_head_ok = 1;
            pthread_mutex_unlock(&g_head_lock);
            kl_ovrp_set_head_pose_time(sample_time_s(tr.head_sample_ns));
            kl_ovrp_set_head_pose(tr.head.position[0], tr.head.position[1], tr.head.position[2],
                                  tr.head.orientation[0], tr.head.orientation[1],
                                  tr.head.orientation[2], tr.head.orientation[3]);
        } else if (!tr.head_valid) {
            pthread_mutex_lock(&g_head_lock);
            g_head_ok = 0;
            pthread_mutex_unlock(&g_head_lock);
        }
        for (int hand = 0; hand < 2; hand++) {
            const qlks_hand *h = &tr.hands[hand];
            if (h->active)
                kl_ovrp_set_hand_pose(hand, h->grip.position[0], h->grip.position[1],
                                      h->grip.position[2], h->grip.orientation[0],
                                      h->grip.orientation[1], h->grip.orientation[2],
                                      h->grip.orientation[3]);
            uint32_t touches = 0;
            uint32_t buttons = hand_buttons(hand, h, &touches);
            kl_ovrp_set_controller_input(hand, buttons, touches, h->trigger, h->squeeze,
                                         h->stick[0], h->stick[1]);
        }
        usleep(2000);
    }
    return NULL;
}

static void uv_fraction(const kl_ovrp_render_pose *r, int eye, id<MTLTexture> tex, float out[4]) {
    out[0] = 0; out[1] = 0; out[2] = 1; out[3] = 1;
    const int *vp = r->viewport[eye];
    if (vp[2] <= 0 || vp[3] <= 0) return;
    // viewport_of is the texture the rect was measured against; without it the
    // texture in hand is the best available denominator.
    float w = r->viewport_of[0] > 0 ? (float)r->viewport_of[0] : (float)tex.width;
    float h = r->viewport_of[1] > 0 ? (float)r->viewport_of[1] : (float)tex.height;
    out[0] = vp[0] / w; out[1] = vp[1] / h;
    out[2] = vp[2] / w; out[3] = vp[3] / h;
}

static void *frame_main(void *arg) {
    (void)arg;
    pthread_setname_np("kl.questlink.frame");
    uint64_t last_value = 0;
    double first_texture = 0, last_report = monotonic_s();
    uint64_t sent = 0;
    int said_fence = 0, said_size = 0;
    while (!atomic_load(&g_quit)) {
        @autoreleasepool {
            int stage = kl_ovrp_last_complete_stage();
            if (stage < 0 || !kl_ovrp_eye_layer_live()) { usleep(2000); continue; }
            int slice[2] = { 0, 0 };
            void *tex[2] = { kl_glfb_eye_mtl_texture(0, stage, &slice[0]),
                             kl_glfb_eye_mtl_texture(1, stage, &slice[1]) };
            if (!tex[0]) { usleep(2000); continue; }
            if (!tex[1]) { tex[1] = tex[0]; slice[1] = slice[0]; }

            // The viewer registers ANGLE's fence once its compositor starts. A
            // run without a viewer window still needs one, so after a grace
            // period this frontend registers its own.
            if (!kl_glfb_has_gpu_fence()) {
                double now = monotonic_s();
                if (!first_texture) first_texture = now;
                if (now - first_texture > 3.0 && !g_own_fence) {
                    id<MTLDevice> dev = (__bridge id<MTLDevice>)kl_glfb_mtl_device();
                    g_own_fence = [dev newSharedEvent];
                    if (g_own_fence) kl_glfb_set_gpu_fence((__bridge void *)g_own_fence);
                    fprintf(stderr, "  [questlink] registered our own GPU fence\n");
                }
                usleep(2000);
                continue;
            }
            void *fence = kl_glfb_gpu_fence();
            kl_ovrp_render_pose r;
            if (!kl_ovrp_stage_render_pose(stage, &r)) { usleep(2000); continue; }
            uint64_t v = kl_glfb_gpu_fence_value();
            if (!v || v == last_value) { usleep(1000); continue; }
            if (!said_fence++) fprintf(stderr, "  [questlink] first guest frame on the fence\n");

            qlks_frame f;
            memset(&f, 0, sizeof f);
            f.size = sizeof f;
            f.abi = QLKS_ABI;
            f.head.position[0] = r.px; f.head.position[1] = r.py; f.head.position[2] = r.pz;
            f.head.orientation[0] = r.qx; f.head.orientation[1] = r.qy;
            f.head.orientation[2] = r.qz; f.head.orientation[3] = r.qw;
            for (int eye = 0; eye < 2; eye++) {
                id<MTLTexture> t = (__bridge id<MTLTexture>)tex[eye];
                f.eyes[eye].texture = tex[eye];
                f.eyes[eye].slice = (uint32_t)slice[eye];
                f.eyes[eye].top_left = (uint32_t)kl_glfb_eye_mtl_origin_top_left(eye, stage);
                uv_fraction(&r, eye, t, f.eyes[eye].uv_rect);
                memcpy(f.eyes[eye].tangents, r.tangents[eye], sizeof(float) * 4);
                if (!said_size++)
                    fprintf(stderr, "  [questlink] eye source %lux%lu type %lu fmt %lu, "
                                    "uv %.3f,%.3f %.3fx%.3f, top-left %u -> %ux%u\n",
                            (unsigned long)t.width, (unsigned long)t.height,
                            (unsigned long)t.textureType, (unsigned long)t.pixelFormat,
                            f.eyes[eye].uv_rect[0], f.eyes[eye].uv_rect[1],
                            f.eyes[eye].uv_rect[2], f.eyes[eye].uv_rect[3],
                            f.eyes[eye].top_left, g_device.views[0].width,
                            g_device.views[0].height);
            }
            f.wait_event = fence;
            f.wait_value = v;
            if (qlks_submit(g_link, &f)) sent++;
            last_value = v;

            double now = monotonic_s();
            if (now - last_report >= 5.0) {
                qlks_counters c;
                qlks_read_counters(g_link, &c);
                fprintf(stderr, "  [questlink] %.1f fps sent; submitted %llu accepted %llu "
                                "busy %llu unavailable %llu rejected %llu rebinds %llu gpu-fail %llu\n",
                        sent / (now - last_report), (unsigned long long)c.submitted,
                        (unsigned long long)c.accepted, (unsigned long long)c.dropped_busy,
                        (unsigned long long)c.dropped_unavailable, (unsigned long long)c.rejected,
                        (unsigned long long)c.sink_rebinds, (unsigned long long)c.gpu_failures);
                sent = 0;
                last_report = now;
            }
        }
    }
    return NULL;
}

int kl_questlink_start(void) {
    if (g_link) return 1;
    void *dev = kl_glfb_mtl_device();
    if (!dev) {
        fprintf(stderr, "  [questlink] no ANGLE MTLDevice — needs KL_GLFB=1\n");
        return 0;
    }
    if (!qlks_start(getenv("KL_QUESTLINK_ENDPOINT"), dev, &g_link)) {
        fprintf(stderr, "  [questlink] QuestLinkMac service is not reachable\n");
        return 0;
    }
    uint32_t wait_ms = (uint32_t)kl_env_int("KL_QUESTLINK_WAIT_MS", 30000);
    fprintf(stderr, "  [questlink] waiting up to %u ms for a headset...\n", wait_ms);
    if (!qlks_wait_device(g_link, wait_ms, &g_device)) {
        fprintf(stderr, "  [questlink] no headset connected\n");
        qlks_stop(g_link);
        g_link = NULL;
        return 0;
    }

    float hz = (float)(1e9 / (double)g_device.period_ns);
    kl_ovrp_set_display_frequency(hz);
    kl_ovrp_set_eye_texture_size((int)g_device.views[0].width, (int)g_device.views[0].height);
    for (int eye = 0; eye < 2; eye++) {
        const qlks_view *v = &g_device.views[eye];
        kl_ovrp_set_eye_frustum(eye, tanf(-v->fov[0]), tanf(v->fov[1]),
                                tanf(v->fov[2]), tanf(-v->fov[3]));
        kl_ovrp_set_eye_offset(eye, v->head_to_eye.position[0], v->head_to_eye.position[1],
                               v->head_to_eye.position[2]);
        kl_ovrp_set_eye_rotation(eye, v->head_to_eye.orientation[0], v->head_to_eye.orientation[1],
                                 v->head_to_eye.orientation[2], v->head_to_eye.orientation[3]);
        fprintf(stderr, "  [questlink] eye %d: %ux%u, fov L%.1f R%.1f U%.1f D%.1f deg, "
                        "offset %.4f,%.4f,%.4f\n",
                eye, v->width, v->height, v->fov[0] * 57.2958f, v->fov[1] * 57.2958f,
                v->fov[2] * 57.2958f, v->fov[3] * 57.2958f, v->head_to_eye.position[0],
                v->head_to_eye.position[1], v->head_to_eye.position[2]);
    }
    fprintf(stderr, "  [questlink] headset at %.2f Hz; guest told %.1f Hz\n", hz,
            (double)kl_ovrp_display_frequency());
    kl_ovrp_set_head_at(head_at);
    kl_view_external_pose = 1;

    atomic_store(&g_quit, 0);
    if (pthread_create(&g_pose_thread, NULL, pose_main, NULL) == 0) g_threads |= 1;
    if (pthread_create(&g_frame_thread, NULL, frame_main, NULL) == 0) g_threads |= 2;
    return g_threads == 3;
}

void kl_questlink_stop(void) {
    if (!g_link) return;
    atomic_store(&g_quit, 1);
    if (g_threads & 1) pthread_join(g_pose_thread, NULL);
    if (g_threads & 2) pthread_join(g_frame_thread, NULL);
    g_threads = 0;
    kl_ovrp_set_head_at(NULL);
    qlks_stop(g_link);
    g_link = NULL;
}
