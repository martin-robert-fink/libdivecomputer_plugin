/**
 * jni_bridge.cpp — JNI bridge between Kotlin and libdivecomputer C API.
 *
 * On iOS/macOS, Swift calls the C API directly via bridging headers.
 * On Android, we need this JNI layer. The design mirrors the Swift plugin:
 *
 *   Kotlin DiveComputerPlugin
 *     → JNI native methods (this file)
 *       → libdivecomputer C API
 *         → dc_custom_open callbacks (this file)
 *           → JNI calls back into Kotlin BleTransport
 *
 * Threading: libdivecomputer calls our C callbacks from a background thread.
 * We must attach that thread to the JVM before making JNI calls.
 */

#include <jni.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <android/log.h>

// libdivecomputer headers
#include <libdivecomputer/common.h>
#include <libdivecomputer/context.h>
#include <libdivecomputer/descriptor.h>
#include <libdivecomputer/device.h>
#include <libdivecomputer/parser.h>
#include <libdivecomputer/iostream.h>
#include <libdivecomputer/custom.h>
#include <libdivecomputer/version.h>

#define TAG "libdivecomputer_plugin-JNI"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN,  TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)
#define LOGD(...) __android_log_print(ANDROID_LOG_DEBUG, TAG, __VA_ARGS__)

// ---------------------------------------------------------------------------
// Global JVM reference (set once in JNI_OnLoad)
// ---------------------------------------------------------------------------

static JavaVM *g_jvm = nullptr;

/**
 * Helper: get JNIEnv for the current thread, attaching if needed.
 * Returns nullptr on failure. Caller must detach if `attached` is set true.
 */
static JNIEnv* getEnv(bool *attached) {
    *attached = false;
    JNIEnv *env = nullptr;
    if (g_jvm->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6) == JNI_OK) {
        return env;
    }
    if (g_jvm->AttachCurrentThread(&env, nullptr) == JNI_OK) {
        *attached = true;
        return env;
    }
    LOGE("Failed to attach thread to JVM");
    return nullptr;
}

static void detachIfNeeded(bool attached) {
    if (attached) {
        g_jvm->DetachCurrentThread();
    }
}

JNIEXPORT jint JNI_OnLoad(JavaVM *vm, void * /*reserved*/) {
    g_jvm = vm;
    LOGI("JNI_OnLoad: libdivecomputer_plugin_jni loaded");
    return JNI_VERSION_1_6;
}

// ---------------------------------------------------------------------------
// Transport userdata: stored in dc_custom_open, passed to all callbacks
// ---------------------------------------------------------------------------

struct TransportUserdata {
    jobject  transport;    // Global ref to Kotlin BleTransport
    jclass   transportCls; // Global ref to the Class object (cached)
    // Cached method IDs
    jmethodID midRead;
    jmethodID midWrite;
    jmethodID midGetName;
    jmethodID midGetAccessCode;
    jmethodID midSetAccessCode;
    jmethodID midClose;
    jmethodID midGetAvailable;
    jmethodID midSetTimeout;
    jmethodID midSleep;
};

// ---------------------------------------------------------------------------
// dc_custom_cbs_t callback implementations
// ---------------------------------------------------------------------------

static dc_status_t cb_set_timeout(void *userdata, int timeout) {
    auto *td = static_cast<TransportUserdata*>(userdata);
    bool attached;
    JNIEnv *env = getEnv(&attached);
    if (!env) return DC_STATUS_IO;

    env->CallVoidMethod(td->transport, td->midSetTimeout, (jint)timeout);
    detachIfNeeded(attached);
    return DC_STATUS_SUCCESS;
}

static dc_status_t cb_set_break(void * /*userdata*/, unsigned int /*value*/) {
    return DC_STATUS_SUCCESS; // No-op for BLE
}

static dc_status_t cb_set_dtr(void * /*userdata*/, unsigned int /*value*/) {
    return DC_STATUS_SUCCESS; // No-op for BLE
}

static dc_status_t cb_set_rts(void * /*userdata*/, unsigned int /*value*/) {
    return DC_STATUS_SUCCESS; // No-op for BLE
}

static dc_status_t cb_get_lines(void * /*userdata*/, unsigned int * /*value*/) {
    return DC_STATUS_SUCCESS; // No-op for BLE
}

static dc_status_t cb_get_available(void *userdata, size_t *value) {
    auto *td = static_cast<TransportUserdata*>(userdata);
    bool attached;
    JNIEnv *env = getEnv(&attached);
    if (!env) return DC_STATUS_IO;

    jint available = env->CallIntMethod(td->transport, td->midGetAvailable);
    *value = (size_t)available;
    detachIfNeeded(attached);
    return DC_STATUS_SUCCESS;
}

static dc_status_t cb_configure(void * /*userdata*/, unsigned int /*baudrate*/,
                                 unsigned int /*databits*/, dc_parity_t /*parity*/,
                                 dc_stopbits_t /*stopbits*/, dc_flowcontrol_t /*flowcontrol*/) {
    return DC_STATUS_SUCCESS; // No-op for BLE
}

static dc_status_t cb_poll(void * /*userdata*/, int /*timeout*/) {
    return DC_STATUS_SUCCESS; // Always ready
}

/**
 * Read callback: called by libdivecomputer to receive BLE data.
 * Calls Kotlin BleTransport.nativeRead(size) which returns a ByteArray
 * containing one BLE notification packet (or null on timeout/error).
 */
static dc_status_t cb_read(void *userdata, void *data, size_t size, size_t *actual) {
    auto *td = static_cast<TransportUserdata*>(userdata);
    bool attached;
    JNIEnv *env = getEnv(&attached);
    if (!env) return DC_STATUS_IO;

    // Call Kotlin: fun nativeRead(maxSize: Int): ByteArray?
    jbyteArray result = (jbyteArray)env->CallObjectMethod(
        td->transport, td->midRead, (jint)size
    );

    if (result == nullptr) {
        // Check for exception
        if (env->ExceptionCheck()) {
            env->ExceptionDescribe();
            env->ExceptionClear();
        }
        *actual = 0;
        detachIfNeeded(attached);
        return DC_STATUS_TIMEOUT;
    }

    jsize len = env->GetArrayLength(result);
    if (len > (jsize)size) len = (jsize)size;

    env->GetByteArrayRegion(result, 0, len, reinterpret_cast<jbyte*>(data));
    env->DeleteLocalRef(result);
    *actual = (size_t)len;
    detachIfNeeded(attached);
    return DC_STATUS_SUCCESS;
}

/**
 * Write callback: called by libdivecomputer to send BLE data.
 * Calls Kotlin BleTransport.nativeWrite(data) which returns a status int.
 */
static dc_status_t cb_write(void *userdata, const void *data, size_t size, size_t *actual) {
    auto *td = static_cast<TransportUserdata*>(userdata);
    bool attached;
    JNIEnv *env = getEnv(&attached);
    if (!env) return DC_STATUS_IO;

    jbyteArray jdata = env->NewByteArray((jint)size);
    env->SetByteArrayRegion(jdata, 0, (jint)size, reinterpret_cast<const jbyte*>(data));

    // Call Kotlin: fun nativeWrite(data: ByteArray): Int
    jint status = env->CallIntMethod(td->transport, td->midWrite, jdata);
    env->DeleteLocalRef(jdata);

    if (status == 0) { // 0 = DC_STATUS_SUCCESS
        *actual = size;
        detachIfNeeded(attached);
        return DC_STATUS_SUCCESS;
    } else {
        *actual = 0;
        detachIfNeeded(attached);
        return (dc_status_t)status;
    }
}

/**
 * Ioctl callback: handles BLE-specific ioctls.
 * Mirrors the Swift implementation's Ioctl enum.
 */
static dc_status_t cb_ioctl(void *userdata, unsigned int request,
                             void *data, size_t size) {
    auto *td = static_cast<TransportUserdata*>(userdata);

    // Decode ioctl request (same macros as Swift Ioctl enum)
    unsigned int dir  = (request >> 30) & 0x03;
    unsigned int type = (request >>  8) & 0xFF;
    unsigned int nr   = (request >>  0) & 0xFF;

    // Only handle BLE ioctls (type = 'b' = 0x62)
    if (type != 0x62) {
        return DC_STATUS_UNSUPPORTED;
    }

    bool attached;
    JNIEnv *env = getEnv(&attached);
    if (!env) return DC_STATUS_IO;

    dc_status_t result = DC_STATUS_UNSUPPORTED;

    switch (nr) {
        case 0: { // DC_IOCTL_BLE_GET_NAME
            if ((dir & 1) == 0 || !data || size == 0) {
                result = DC_STATUS_INVALIDARGS;
                break;
            }
            // Call Kotlin: fun nativeGetName(): String
            jstring jname = (jstring)env->CallObjectMethod(td->transport, td->midGetName);
            if (jname) {
                const char *name = env->GetStringUTFChars(jname, nullptr);
                size_t len = strlen(name);
                size_t copyLen = (len + 1 < size) ? len + 1 : size;
                memcpy(data, name, copyLen);
                ((char*)data)[copyLen - 1] = '\0';
                env->ReleaseStringUTFChars(jname, name);
                env->DeleteLocalRef(jname);
            }
            result = DC_STATUS_SUCCESS;
            break;
        }
        case 2: { // DC_IOCTL_BLE_GET/SET_ACCESSCODE
            if (dir & 1) { // READ — get access code
                jbyteArray jcode = (jbyteArray)env->CallObjectMethod(
                    td->transport, td->midGetAccessCode
                );
                if (jcode && data) {
                    jsize len = env->GetArrayLength(jcode);
                    size_t copyLen = ((size_t)len < size) ? (size_t)len : size;
                    env->GetByteArrayRegion(jcode, 0, (jint)copyLen,
                                            reinterpret_cast<jbyte*>(data));
                    env->DeleteLocalRef(jcode);
                }
                result = DC_STATUS_SUCCESS;
            } else if (dir & 2) { // WRITE — set access code
                if (!data || size == 0) {
                    result = DC_STATUS_INVALIDARGS;
                    break;
                }
                jbyteArray jcode = env->NewByteArray((jint)size);
                env->SetByteArrayRegion(jcode, 0, (jint)size,
                                        reinterpret_cast<const jbyte*>(data));
                env->CallVoidMethod(td->transport, td->midSetAccessCode, jcode);
                env->DeleteLocalRef(jcode);
                LOGI("Access code set (%zu bytes)", size);
                result = DC_STATUS_SUCCESS;
            }
            break;
        }
        default:
            LOGW("Unsupported ioctl: type=0x%02x nr=%u dir=%u", type, nr, dir);
            result = DC_STATUS_UNSUPPORTED;
            break;
    }

    detachIfNeeded(attached);
    return result;
}

static dc_status_t cb_flush(void * /*userdata*/) {
    return DC_STATUS_SUCCESS;
}

static dc_status_t cb_purge(void * /*userdata*/, dc_direction_t /*direction*/) {
    return DC_STATUS_SUCCESS;
}

static dc_status_t cb_sleep(void *userdata, unsigned int milliseconds) {
    auto *td = static_cast<TransportUserdata*>(userdata);
    bool attached;
    JNIEnv *env = getEnv(&attached);
    if (!env) {
        // Fallback: just sleep
        usleep(milliseconds * 1000);
        return DC_STATUS_SUCCESS;
    }

    env->CallVoidMethod(td->transport, td->midSleep, (jint)milliseconds);
    detachIfNeeded(attached);
    return DC_STATUS_SUCCESS;
}

static dc_status_t cb_close(void *userdata) {
    auto *td = static_cast<TransportUserdata*>(userdata);
    bool attached;
    JNIEnv *env = getEnv(&attached);
    if (!env) return DC_STATUS_IO;

    env->CallVoidMethod(td->transport, td->midClose);

    // Release global references
    env->DeleteGlobalRef(td->transport);
    env->DeleteGlobalRef(td->transportCls);
    detachIfNeeded(attached);
    delete td;
    return DC_STATUS_SUCCESS;
}

// ---------------------------------------------------------------------------
// Download callbacks
// ---------------------------------------------------------------------------

struct DownloadUserdata {
    jobject   downloader;     // Global ref to Kotlin DiveDownloader
    jclass    downloaderCls;
    jmethodID midOnProgress;
    jmethodID midOnDevInfo;
    jmethodID midOnDive;
    jmethodID midIsCancelled;
};

static void download_event_callback(dc_device_t * /*device*/, dc_event_type_t event,
                                     const void *data, void *userdata) {
    auto *dd = static_cast<DownloadUserdata*>(userdata);
    bool attached;
    JNIEnv *env = getEnv(&attached);
    if (!env) return;

    if (event == DC_EVENT_PROGRESS && data) {
        const dc_event_progress_t *progress =
            static_cast<const dc_event_progress_t*>(data);
        env->CallVoidMethod(dd->downloader, dd->midOnProgress,
                            (jint)progress->current, (jint)progress->maximum);
    } else if (event == DC_EVENT_DEVINFO && data) {
        const dc_event_devinfo_t *devinfo =
            static_cast<const dc_event_devinfo_t*>(data);
        env->CallVoidMethod(dd->downloader, dd->midOnDevInfo,
                            (jint)devinfo->model, (jint)devinfo->firmware,
                            (jint)devinfo->serial);
    }

    detachIfNeeded(attached);
}

static int download_cancel_callback(void *userdata) {
    auto *dd = static_cast<DownloadUserdata*>(userdata);
    bool attached;
    JNIEnv *env = getEnv(&attached);
    if (!env) return 0;

    jboolean cancelled = env->CallBooleanMethod(dd->downloader, dd->midIsCancelled);
    detachIfNeeded(attached);
    return cancelled ? 1 : 0;
}

static int download_dive_callback(const unsigned char *data, unsigned int size,
                                   const unsigned char *fingerprint, unsigned int fsize,
                                   void *userdata) {
    auto *dd = static_cast<DownloadUserdata*>(userdata);
    bool attached;
    JNIEnv *env = getEnv(&attached);
    if (!env) return 0;

    // Pass raw dive data to Kotlin for parsing
    jbyteArray jdata = env->NewByteArray((jint)size);
    env->SetByteArrayRegion(jdata, 0, (jint)size, reinterpret_cast<const jbyte*>(data));

    jbyteArray jfp = nullptr;
    if (fingerprint && fsize > 0) {
        jfp = env->NewByteArray((jint)fsize);
        env->SetByteArrayRegion(jfp, 0, (jint)fsize,
                                reinterpret_cast<const jbyte*>(fingerprint));
    }

    // Call Kotlin: fun onDive(data: ByteArray, fingerprint: ByteArray?): Boolean
    jboolean continueDownload = env->CallBooleanMethod(
        dd->downloader, dd->midOnDive, jdata, jfp
    );

    env->DeleteLocalRef(jdata);
    if (jfp) env->DeleteLocalRef(jfp);
    detachIfNeeded(attached);
    return continueDownload ? 1 : 0;
}

// ---------------------------------------------------------------------------
// JNI EXPORTS: Library info
// ---------------------------------------------------------------------------

extern "C" JNIEXPORT jstring JNICALL
Java_com_example_libdivecomputer_1plugin_DiveComputerPlugin_nativeGetVersion(JNIEnv *env, jobject) {
    dc_version_t version;
    dc_version(&version);
    char buf[64];
    snprintf(buf, sizeof(buf), "libdivecomputer %u.%u.%u",
             version.major, version.minor, version.micro);
    return env->NewStringUTF(buf);
}

extern "C" JNIEXPORT jobjectArray JNICALL
Java_com_example_libdivecomputer_1plugin_DiveComputerPlugin_nativeGetDescriptors(JNIEnv *env, jobject) {
    // First pass: count descriptors
    dc_iterator_t *iterator = nullptr;
    dc_descriptor_t *descriptor = nullptr;
    int count = 0;

    if (dc_descriptor_iterator_new(&iterator, NULL) == DC_STATUS_SUCCESS) {
        while (dc_iterator_next(iterator, &descriptor) == DC_STATUS_SUCCESS) {
            dc_descriptor_free(descriptor);
            count++;
        }
        dc_iterator_free(iterator);
    }

    // Find HashMap class for creating result maps
    jclass mapClass = env->FindClass("java/util/HashMap");
    jmethodID mapInit = env->GetMethodID(mapClass, "<init>", "()V");
    jmethodID mapPut = env->GetMethodID(mapClass, "put",
        "(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;");

    // Create array of Maps
    jobjectArray result = env->NewObjectArray(count, mapClass, nullptr);

    // Second pass: populate
    if (dc_descriptor_iterator_new(&iterator, NULL) == DC_STATUS_SUCCESS) {
        int i = 0;
        while (dc_iterator_next(iterator, &descriptor) == DC_STATUS_SUCCESS && i < count) {
            const char *vendor  = dc_descriptor_get_vendor(descriptor);
            const char *product = dc_descriptor_get_product(descriptor);
            dc_family_t family  = dc_descriptor_get_type(descriptor);
            unsigned int model  = dc_descriptor_get_model(descriptor);
            unsigned int transports = dc_descriptor_get_transports(descriptor);

            jobject map = env->NewObject(mapClass, mapInit);

            // Helper lambda for putting String values
            auto putString = [&](const char* key, const char* value) {
                env->CallObjectMethod(map, mapPut,
                    env->NewStringUTF(key), env->NewStringUTF(value));
            };
            auto putInt = [&](const char* key, int value) {
                jclass intCls = env->FindClass("java/lang/Integer");
                jmethodID valueOf = env->GetStaticMethodID(intCls, "valueOf",
                    "(I)Ljava/lang/Integer;");
                env->CallObjectMethod(map, mapPut,
                    env->NewStringUTF(key),
                    env->CallStaticObjectMethod(intCls, valueOf, value));
                env->DeleteLocalRef(intCls);
            };

            putString("vendor", vendor ? vendor : "");
            putString("product", product ? product : "");
            putInt("family", (int)family);
            putInt("model", (int)model);
            putInt("transports", (int)transports);

            env->SetObjectArrayElement(result, i, map);
            env->DeleteLocalRef(map);

            dc_descriptor_free(descriptor);
            i++;
        }
        dc_iterator_free(iterator);
    }

    env->DeleteLocalRef(mapClass);
    return result;
}

// ---------------------------------------------------------------------------
// JNI EXPORTS: Context and device lifecycle
// ---------------------------------------------------------------------------

static void logfunc_callback(dc_context_t * /*context*/, dc_loglevel_t loglevel,
                              const char * /*file*/, unsigned int /*line*/,
                              const char * /*function*/, const char *message,
                              void * /*userdata*/) {
    if (!message) return;
    switch (loglevel) {
        case DC_LOGLEVEL_ERROR:   LOGE("[libdc] %s", message); break;
        case DC_LOGLEVEL_WARNING: LOGW("[libdc] %s", message); break;
        case DC_LOGLEVEL_INFO:    LOGI("[libdc] %s", message); break;
        case DC_LOGLEVEL_DEBUG:   LOGD("[libdc] %s", message); break;
        default: break;
    }
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_example_libdivecomputer_1plugin_DiveComputerPlugin_nativeCreateContext(JNIEnv *, jobject) {
    dc_context_t *context = nullptr;
    dc_status_t status = dc_context_new(&context);
    if (status != DC_STATUS_SUCCESS || !context) {
        LOGE("dc_context_new failed: %d", (int)status);
        return 0;
    }
    dc_context_set_loglevel(context, DC_LOGLEVEL_WARNING);
    dc_context_set_logfunc(context, logfunc_callback, nullptr);
    LOGI("dc_context created: %p", context);
    return reinterpret_cast<jlong>(context);
}

extern "C" JNIEXPORT void JNICALL
Java_com_example_libdivecomputer_1plugin_DiveComputerPlugin_nativeFreeContext(JNIEnv *, jobject, jlong ptr) {
    if (ptr) {
        dc_context_free(reinterpret_cast<dc_context_t*>(ptr));
        LOGI("dc_context freed");
    }
}

// ---------------------------------------------------------------------------
// JNI EXPORTS: Custom iostream creation
// ---------------------------------------------------------------------------

extern "C" JNIEXPORT jlong JNICALL
Java_com_example_libdivecomputer_1plugin_BleTransport_nativeCreateIostream(
        JNIEnv *env, jobject thiz, jlong contextPtr) {
    dc_context_t *context = reinterpret_cast<dc_context_t*>(contextPtr);

    // Build userdata with global refs and cached method IDs
    auto *td = new TransportUserdata();
    td->transport = env->NewGlobalRef(thiz);
    jclass cls = env->GetObjectClass(thiz);
    td->transportCls = (jclass)env->NewGlobalRef(cls);

    td->midRead          = env->GetMethodID(cls, "nativeRead",          "(I)[B");
    td->midWrite         = env->GetMethodID(cls, "nativeWrite",         "([B)I");
    td->midGetName       = env->GetMethodID(cls, "nativeGetName",       "()Ljava/lang/String;");
    td->midGetAccessCode = env->GetMethodID(cls, "nativeGetAccessCode", "()[B");
    td->midSetAccessCode = env->GetMethodID(cls, "nativeSetAccessCode", "([B)V");
    td->midClose         = env->GetMethodID(cls, "nativeOnClose",       "()V");
    td->midGetAvailable  = env->GetMethodID(cls, "nativeGetAvailable",  "()I");
    td->midSetTimeout    = env->GetMethodID(cls, "nativeSetTimeout",    "(I)V");
    td->midSleep         = env->GetMethodID(cls, "nativeOnSleep",       "(I)V");

    env->DeleteLocalRef(cls);

    // Set up the dc_custom_cbs_t struct
    dc_custom_cbs_t callbacks;
    memset(&callbacks, 0, sizeof(callbacks));
    callbacks.set_timeout   = cb_set_timeout;
    callbacks.set_break     = cb_set_break;
    callbacks.set_dtr       = cb_set_dtr;
    callbacks.set_rts       = cb_set_rts;
    callbacks.get_lines     = cb_get_lines;
    callbacks.get_available = cb_get_available;
    callbacks.configure     = cb_configure;
    callbacks.poll          = cb_poll;
    callbacks.read          = cb_read;
    callbacks.write         = cb_write;
    callbacks.ioctl         = cb_ioctl;
    callbacks.flush         = cb_flush;
    callbacks.purge         = cb_purge;
    callbacks.sleep         = cb_sleep;
    callbacks.close         = cb_close;

    dc_iostream_t *iostream = nullptr;
    dc_status_t status = dc_custom_open(&iostream, context, DC_TRANSPORT_BLE,
                                         &callbacks, td);
    if (status != DC_STATUS_SUCCESS || !iostream) {
        LOGE("dc_custom_open failed: %d", (int)status);
        env->DeleteGlobalRef(td->transport);
        env->DeleteGlobalRef(td->transportCls);
        delete td;
        return 0;
    }

    LOGI("dc_custom_open succeeded: iostream=%p", iostream);
    return reinterpret_cast<jlong>(iostream);
}

extern "C" JNIEXPORT void JNICALL
Java_com_example_libdivecomputer_1plugin_BleTransport_nativeCloseIostream(
        JNIEnv *, jobject, jlong ptr) {
    if (ptr) {
        dc_iostream_close(reinterpret_cast<dc_iostream_t*>(ptr));
        LOGI("dc_iostream closed");
    }
}

// ---------------------------------------------------------------------------
// JNI EXPORTS: Device open / close
// ---------------------------------------------------------------------------

/**
 * Finds a libdivecomputer descriptor by family + model, then opens the device.
 * Returns the device pointer (as jlong) or 0 on failure.
 */
extern "C" JNIEXPORT jlong JNICALL
Java_com_example_libdivecomputer_1plugin_DiveComputerPlugin_nativeOpenDevice(
        JNIEnv *, jobject, jlong contextPtr, jint family, jint model, jlong iostreamPtr) {
    dc_context_t *context    = reinterpret_cast<dc_context_t*>(contextPtr);
    dc_iostream_t *iostream  = reinterpret_cast<dc_iostream_t*>(iostreamPtr);

    // Find matching descriptor
    dc_descriptor_t *matchedDesc = nullptr;
    dc_iterator_t *iterator = nullptr;
    dc_descriptor_t *desc = nullptr;

    if (dc_descriptor_iterator_new(&iterator, NULL) == DC_STATUS_SUCCESS) {
        while (dc_iterator_next(iterator, &desc) == DC_STATUS_SUCCESS) {
            if ((int)dc_descriptor_get_type(desc) == family &&
                (int)dc_descriptor_get_model(desc) == model) {
                matchedDesc = desc;
                break;
            }
            dc_descriptor_free(desc);
        }
        dc_iterator_free(iterator);
    }

    if (!matchedDesc) {
        LOGE("No descriptor found for family=%d model=%d", family, model);
        return 0;
    }

    dc_device_t *device = nullptr;
    dc_status_t status = dc_device_open(&device, context, matchedDesc, iostream);
    dc_descriptor_free(matchedDesc);

    if (status != DC_STATUS_SUCCESS || !device) {
        LOGE("dc_device_open failed: %d", (int)status);
        return 0;
    }

    LOGI("dc_device_open succeeded: device=%p", device);
    return reinterpret_cast<jlong>(device);
}

extern "C" JNIEXPORT void JNICALL
Java_com_example_libdivecomputer_1plugin_DiveComputerPlugin_nativeCloseDevice(
        JNIEnv *, jobject, jlong ptr) {
    if (ptr) {
        dc_device_close(reinterpret_cast<dc_device_t*>(ptr));
        LOGI("dc_device closed");
    }
}

// ---------------------------------------------------------------------------
// JNI EXPORTS: Fingerprint
// ---------------------------------------------------------------------------

extern "C" JNIEXPORT jint JNICALL
Java_com_example_libdivecomputer_1plugin_DiveDownloader_nativeSetFingerprint(
        JNIEnv *env, jobject, jlong devicePtr, jbyteArray fingerprint) {
    dc_device_t *device = reinterpret_cast<dc_device_t*>(devicePtr);
    if (!device || !fingerprint) return (jint)DC_STATUS_INVALIDARGS;

    jsize len = env->GetArrayLength(fingerprint);
    jbyte *fp = env->GetByteArrayElements(fingerprint, nullptr);

    dc_status_t status = dc_device_set_fingerprint(
        device, reinterpret_cast<const unsigned char*>(fp), (unsigned int)len
    );

    env->ReleaseByteArrayElements(fingerprint, fp, JNI_ABORT);
    return (jint)status;
}

// ---------------------------------------------------------------------------
// JNI EXPORTS: Download (runs on calling thread — must be background)
// ---------------------------------------------------------------------------

extern "C" JNIEXPORT jint JNICALL
Java_com_example_libdivecomputer_1plugin_DiveDownloader_nativeStartDownload(
        JNIEnv *env, jobject thiz, jlong devicePtr) {
    dc_device_t *device = reinterpret_cast<dc_device_t*>(devicePtr);
    if (!device) return (jint)DC_STATUS_INVALIDARGS;

    // Build download userdata
    auto *dd = new DownloadUserdata();
    dd->downloader = env->NewGlobalRef(thiz);
    jclass cls = env->GetObjectClass(thiz);
    dd->downloaderCls = (jclass)env->NewGlobalRef(cls);

    dd->midOnProgress  = env->GetMethodID(cls, "onNativeProgress",  "(II)V");
    dd->midOnDevInfo   = env->GetMethodID(cls, "onNativeDevInfo",   "(III)V");
    dd->midOnDive      = env->GetMethodID(cls, "onNativeDive",      "([B[B)Z");
    dd->midIsCancelled = env->GetMethodID(cls, "isCancelled",       "()Z");

    env->DeleteLocalRef(cls);

    // Register event callbacks
    dc_device_set_events(device,
        DC_EVENT_PROGRESS | DC_EVENT_DEVINFO,
        download_event_callback, dd);

    // Register cancel callback
    dc_device_set_cancel(device, download_cancel_callback, dd);

    // Run the download — this blocks until all dives are enumerated
    dc_status_t status = dc_device_foreach(device, download_dive_callback, dd);

    LOGI("dc_device_foreach completed: status=%d", (int)status);

    // Cleanup
    env->DeleteGlobalRef(dd->downloader);
    env->DeleteGlobalRef(dd->downloaderCls);
    delete dd;

    return (jint)status;
}

// ---------------------------------------------------------------------------
// JNI EXPORTS: Dive parsing
// ---------------------------------------------------------------------------

// Forward declare sample callback
static void parser_sample_callback(dc_sample_type_t type,
                                    const dc_sample_value_t *value,
                                    void *userdata);

struct ParserUserdata {
    JNIEnv  *env;
    jobject  sampleList; // ArrayList<HashMap>
    jobject  currentSample;
    jclass   mapClass;
    jmethodID mapInit;
    jmethodID mapPut;
    jmethodID listAdd;
};

extern "C" JNIEXPORT jobject JNICALL
Java_com_example_libdivecomputer_1plugin_DiveDownloader_nativeParseDive(
        JNIEnv *env, jobject, jlong devicePtr, jbyteArray diveData) {
    dc_device_t *device = reinterpret_cast<dc_device_t*>(devicePtr);
    if (!device || !diveData) return nullptr;

    jsize dataLen = env->GetArrayLength(diveData);
    jbyte *data = env->GetByteArrayElements(diveData, nullptr);

    // Create parser — 0.10.0 API takes data + size directly
    dc_parser_t *parser = nullptr;
    dc_status_t status = dc_parser_new(&parser, device,
        reinterpret_cast<const unsigned char*>(data), (size_t)dataLen);
    env->ReleaseByteArrayElements(diveData, data, JNI_ABORT);

    if (status != DC_STATUS_SUCCESS || !parser) {
        LOGE("dc_parser_new failed: %d", (int)status);
        return nullptr;
    }

    // Create result HashMap
    jclass mapClass = env->FindClass("java/util/HashMap");
    jmethodID mapInit = env->GetMethodID(mapClass, "<init>", "()V");
    jmethodID mapPut = env->GetMethodID(mapClass, "put",
        "(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;");

    jobject result = env->NewObject(mapClass, mapInit);

    // Helper lambdas
    auto putDouble = [&](const char* key, double val) {
        jclass dblCls = env->FindClass("java/lang/Double");
        jmethodID dblOf = env->GetStaticMethodID(dblCls, "valueOf", "(D)Ljava/lang/Double;");
        env->CallObjectMethod(result, mapPut,
            env->NewStringUTF(key),
            env->CallStaticObjectMethod(dblCls, dblOf, val));
        env->DeleteLocalRef(dblCls);
    };
    auto putInt = [&](const char* key, int val) {
        jclass intCls = env->FindClass("java/lang/Integer");
        jmethodID intOf = env->GetStaticMethodID(intCls, "valueOf", "(I)Ljava/lang/Integer;");
        env->CallObjectMethod(result, mapPut,
            env->NewStringUTF(key),
            env->CallStaticObjectMethod(intCls, intOf, val));
        env->DeleteLocalRef(intCls);
    };
    auto putString = [&](const char* key, const char* val) {
        env->CallObjectMethod(result, mapPut,
            env->NewStringUTF(key), env->NewStringUTF(val));
    };

    // Parse dive time
    dc_datetime_t datetime = {};
    if (dc_parser_get_datetime(parser, &datetime) == DC_STATUS_SUCCESS) {
        char buf[32];
        snprintf(buf, sizeof(buf), "%04d-%02d-%02dT%02d:%02d:%02d",
                 datetime.year, datetime.month, datetime.day,
                 datetime.hour, datetime.minute, datetime.second);
        putString("dateTime", buf);
    }

    // Max depth
    double maxDepth = 0;
    if (dc_parser_get_field(parser, DC_FIELD_MAXDEPTH, 0, &maxDepth) == DC_STATUS_SUCCESS) {
        putDouble("maxDepth", maxDepth);
    }

    // Dive time
    unsigned int diveTime = 0;
    if (dc_parser_get_field(parser, DC_FIELD_DIVETIME, 0, &diveTime) == DC_STATUS_SUCCESS) {
        putInt("diveTime", (int)diveTime);
    }

    // Temperature (min/max)
    double tempMin = 0, tempMax = 0;
    if (dc_parser_get_field(parser, DC_FIELD_TEMPERATURE_MINIMUM, 0, &tempMin) == DC_STATUS_SUCCESS) {
        putDouble("tempMin", tempMin);
    }
    if (dc_parser_get_field(parser, DC_FIELD_TEMPERATURE_MAXIMUM, 0, &tempMax) == DC_STATUS_SUCCESS) {
        putDouble("tempMax", tempMax);
    }

    // Atmospheric pressure
    double atm = 0;
    if (dc_parser_get_field(parser, DC_FIELD_ATMOSPHERIC, 0, &atm) == DC_STATUS_SUCCESS) {
        putDouble("atmospheric", atm);
    }

    // Dive mode
    dc_divemode_t diveMode;
    if (dc_parser_get_field(parser, DC_FIELD_DIVEMODE, 0, &diveMode) == DC_STATUS_SUCCESS) {
        const char *modeName;
        switch (diveMode) {
            case DC_DIVEMODE_FREEDIVE:  modeName = "freedive"; break;
            case DC_DIVEMODE_GAUGE:     modeName = "gauge"; break;
            case DC_DIVEMODE_OC:        modeName = "opencircuit"; break;
            case DC_DIVEMODE_CCR:       modeName = "closedcircuit"; break;
            case DC_DIVEMODE_SCR:       modeName = "semiclosed"; break;
            default:                    modeName = "unknown"; break;
        }
        putString("diveMode", modeName);
    }

    // Gas mixes
    unsigned int gasmixCount = 0;
    if (dc_parser_get_field(parser, DC_FIELD_GASMIX_COUNT, 0, &gasmixCount) == DC_STATUS_SUCCESS
        && gasmixCount > 0) {

        jclass listClass = env->FindClass("java/util/ArrayList");
        jmethodID listInit = env->GetMethodID(listClass, "<init>", "()V");
        jmethodID listAdd = env->GetMethodID(listClass, "add", "(Ljava/lang/Object;)Z");
        jobject gasList = env->NewObject(listClass, listInit);

        for (unsigned int i = 0; i < gasmixCount; i++) {
            dc_gasmix_t gasmix;
            if (dc_parser_get_field(parser, DC_FIELD_GASMIX, i, &gasmix) == DC_STATUS_SUCCESS) {
                jobject gasMap = env->NewObject(mapClass, mapInit);
                jclass dblCls = env->FindClass("java/lang/Double");
                jmethodID dblOf = env->GetStaticMethodID(dblCls, "valueOf", "(D)Ljava/lang/Double;");

                env->CallObjectMethod(gasMap, mapPut,
                    env->NewStringUTF("oxygen"),
                    env->CallStaticObjectMethod(dblCls, dblOf, gasmix.oxygen));
                env->CallObjectMethod(gasMap, mapPut,
                    env->NewStringUTF("helium"),
                    env->CallStaticObjectMethod(dblCls, dblOf, gasmix.helium));
                env->CallObjectMethod(gasMap, mapPut,
                    env->NewStringUTF("nitrogen"),
                    env->CallStaticObjectMethod(dblCls, dblOf, gasmix.nitrogen));

                env->CallBooleanMethod(gasList, listAdd, gasMap);
                env->DeleteLocalRef(gasMap);
                env->DeleteLocalRef(dblCls);
            }
        }
        env->CallObjectMethod(result, mapPut, env->NewStringUTF("gasMixes"), gasList);
        env->DeleteLocalRef(gasList);
        env->DeleteLocalRef(listClass);
    }

    // Tank info
    unsigned int tankCount = 0;
    if (dc_parser_get_field(parser, DC_FIELD_TANK_COUNT, 0, &tankCount) == DC_STATUS_SUCCESS
        && tankCount > 0) {

        jclass listClass = env->FindClass("java/util/ArrayList");
        jmethodID listInit = env->GetMethodID(listClass, "<init>", "()V");
        jmethodID listAdd = env->GetMethodID(listClass, "add", "(Ljava/lang/Object;)Z");
        jobject tankList = env->NewObject(listClass, listInit);

        for (unsigned int i = 0; i < tankCount; i++) {
            dc_tank_t tank;
            if (dc_parser_get_field(parser, DC_FIELD_TANK, i, &tank) == DC_STATUS_SUCCESS) {
                jobject tankMap = env->NewObject(mapClass, mapInit);
                jclass dblCls = env->FindClass("java/lang/Double");
                jmethodID dblOf = env->GetStaticMethodID(dblCls, "valueOf", "(D)Ljava/lang/Double;");

                env->CallObjectMethod(tankMap, mapPut,
                    env->NewStringUTF("beginPressure"),
                    env->CallStaticObjectMethod(dblCls, dblOf, tank.beginpressure));
                env->CallObjectMethod(tankMap, mapPut,
                    env->NewStringUTF("endPressure"),
                    env->CallStaticObjectMethod(dblCls, dblOf, tank.endpressure));
                if (tank.volume > 0) {
                    env->CallObjectMethod(tankMap, mapPut,
                        env->NewStringUTF("volume"),
                        env->CallStaticObjectMethod(dblCls, dblOf, tank.volume));
                }
                if (tank.workpressure > 0) {
                    env->CallObjectMethod(tankMap, mapPut,
                        env->NewStringUTF("workPressure"),
                        env->CallStaticObjectMethod(dblCls, dblOf, tank.workpressure));
                }

                env->CallBooleanMethod(tankList, listAdd, tankMap);
                env->DeleteLocalRef(tankMap);
                env->DeleteLocalRef(dblCls);
            }
        }
        env->CallObjectMethod(result, mapPut, env->NewStringUTF("tanks"), tankList);
        env->DeleteLocalRef(tankList);
        env->DeleteLocalRef(listClass);
    }

    // Samples (depth profile)
    jclass listClass = env->FindClass("java/util/ArrayList");
    jmethodID listInit = env->GetMethodID(listClass, "<init>", "()V");
    jmethodID listAdd = env->GetMethodID(listClass, "add", "(Ljava/lang/Object;)Z");
    jobject sampleList = env->NewObject(listClass, listInit);

    ParserUserdata pu;
    pu.env = env;
    pu.sampleList = sampleList;
    pu.currentSample = nullptr;
    pu.mapClass = mapClass;
    pu.mapInit = mapInit;
    pu.mapPut = mapPut;
    pu.listAdd = listAdd;

    dc_parser_samples_foreach(parser, parser_sample_callback, &pu);

    // Flush last sample
    if (pu.currentSample) {
        env->CallBooleanMethod(sampleList, listAdd, pu.currentSample);
        env->DeleteLocalRef(pu.currentSample);
    }

    env->CallObjectMethod(result, mapPut, env->NewStringUTF("samples"), sampleList);

    // Sample count
    jint sampleCount = 0;
    jmethodID listSize = env->GetMethodID(listClass, "size", "()I");
    sampleCount = env->CallIntMethod(sampleList, listSize);
    putInt("sampleCount", sampleCount);

    env->DeleteLocalRef(sampleList);
    env->DeleteLocalRef(listClass);

    dc_parser_destroy(parser);
    env->DeleteLocalRef(mapClass);

    return result;
}

// Sample callback for dc_parser_samples_foreach
static void parser_sample_callback(dc_sample_type_t type,
                                    const dc_sample_value_t *value,
                                    void *userdata) {
    auto *pu = static_cast<ParserUserdata*>(userdata);
    JNIEnv *env = pu->env;

    auto putDouble = [&](jobject map, const char* key, double val) {
        jclass dblCls = env->FindClass("java/lang/Double");
        jmethodID dblOf = env->GetStaticMethodID(dblCls, "valueOf", "(D)Ljava/lang/Double;");
        env->CallObjectMethod(map, pu->mapPut,
            env->NewStringUTF(key),
            env->CallStaticObjectMethod(dblCls, dblOf, val));
        env->DeleteLocalRef(dblCls);
    };
    auto putInt = [&](jobject map, const char* key, int val) {
        jclass intCls = env->FindClass("java/lang/Integer");
        jmethodID intOf = env->GetStaticMethodID(intCls, "valueOf", "(I)Ljava/lang/Integer;");
        env->CallObjectMethod(map, pu->mapPut,
            env->NewStringUTF(key),
            env->CallStaticObjectMethod(intCls, intOf, val));
        env->DeleteLocalRef(intCls);
    };

    switch (type) {
        case DC_SAMPLE_TIME:
            // Flush previous sample
            if (pu->currentSample) {
                env->CallBooleanMethod(pu->sampleList, pu->listAdd, pu->currentSample);
                env->DeleteLocalRef(pu->currentSample);
            }
            pu->currentSample = env->NewObject(pu->mapClass, pu->mapInit);
            putInt(pu->currentSample, "time", (int)value->time);
            break;
        case DC_SAMPLE_DEPTH:
            if (pu->currentSample)
                putDouble(pu->currentSample, "depth", value->depth);
            break;
        case DC_SAMPLE_TEMPERATURE:
            if (pu->currentSample)
                putDouble(pu->currentSample, "temperature", value->temperature);
            break;
        case DC_SAMPLE_PRESSURE:
            if (pu->currentSample)
                putDouble(pu->currentSample, "pressure", value->pressure.value);
            break;
        case DC_SAMPLE_SETPOINT:
            if (pu->currentSample)
                putDouble(pu->currentSample, "setpoint", value->setpoint);
            break;
        case DC_SAMPLE_PPO2:
            if (pu->currentSample)
                putDouble(pu->currentSample, "ppo2", value->ppo2.value);
            break;
        case DC_SAMPLE_HEARTBEAT:
            if (pu->currentSample)
                putInt(pu->currentSample, "heartbeat", (int)value->heartbeat);
            break;
        case DC_SAMPLE_CNS:
            if (pu->currentSample)
                putDouble(pu->currentSample, "cns", value->cns);
            break;
        case DC_SAMPLE_DECO:
            if (pu->currentSample) {
                putInt(pu->currentSample, "decoType", (int)value->deco.type);
                putDouble(pu->currentSample, "decoDepth", value->deco.depth);
                putInt(pu->currentSample, "decoTime", (int)value->deco.time);
            }
            break;
        case DC_SAMPLE_GASMIX:
            if (pu->currentSample)
                putInt(pu->currentSample, "gasmix", (int)value->gasmix);
            break;
        default:
            break;
    }
}