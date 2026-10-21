/*
 * Minimal JNI compatibility layer for building the AOSP/HeliBoard LatinIME native core
 * outside of Android (HarmonyOS / host tests).
 *
 * Only the subset of the JNI API used by third_party/latinime/src is provided. JNI types are
 * mapped onto plain C++ buffers owned by an arena inside JNIEnv. Calls that would interact with
 * Java objects (FindClass, Call*Method, ...) are inert stubs; they are only used by optional
 * code paths (logging to android.util.Log, word property export).
 */
#ifndef OHOS_JNI_SHIM_H
#define OHOS_JNI_SHIM_H

#include <cstdint>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

typedef int32_t jint;
typedef int64_t jlong;
typedef int8_t jbyte;
typedef uint8_t jboolean;
typedef uint16_t jchar;
typedef int16_t jshort;
typedef float jfloat;
typedef double jdouble;
typedef jint jsize;

#define JNI_FALSE 0
#define JNI_TRUE 1

struct _jobject {
    virtual ~_jobject() {}
};
struct _jclass : _jobject {};
struct _jstring : _jobject {
    std::string utf8;
    jsize utf16Length = 0;
};
struct _jarray : _jobject {
    virtual jsize length() const = 0;
};
template <typename T>
struct _jprimitiveArray : _jarray {
    std::vector<T> data;
    jsize length() const override { return static_cast<jsize>(data.size()); }
};
struct _jintArray : _jprimitiveArray<jint> {};
struct _jfloatArray : _jprimitiveArray<jfloat> {};
struct _jbooleanArray : _jprimitiveArray<jboolean> {};
struct _jobjectArray : _jarray {
    std::vector<_jobject *> data;
    jsize length() const override { return static_cast<jsize>(data.size()); }
};

typedef _jobject *jobject;
typedef _jclass *jclass;
typedef _jstring *jstring;
typedef _jarray *jarray;
typedef _jintArray *jintArray;
typedef _jfloatArray *jfloatArray;
typedef _jbooleanArray *jbooleanArray;
typedef _jobjectArray *jobjectArray;
typedef struct _jmethodID *jmethodID;

struct JNIEnv {
    // --- arrays -------------------------------------------------------------------------------
    jsize GetArrayLength(jarray array) const { return array ? array->length() : 0; }

    jintArray NewIntArray(jsize length) { return newArray<_jintArray>(length); }
    jfloatArray NewFloatArray(jsize length) { return newArray<_jfloatArray>(length); }
    jbooleanArray NewBooleanArray(jsize length) { return newArray<_jbooleanArray>(length); }
    jobjectArray NewObjectArray(jsize length, jclass, jobject initial) {
        auto *array = own(new _jobjectArray());
        array->data.assign(static_cast<size_t>(length), initial);
        return array;
    }

    void GetIntArrayRegion(jintArray a, jsize start, jsize len, jint *buf) const { copyOut(a, start, len, buf); }
    void GetFloatArrayRegion(jfloatArray a, jsize start, jsize len, jfloat *buf) const { copyOut(a, start, len, buf); }
    void GetBooleanArrayRegion(jbooleanArray a, jsize start, jsize len, jboolean *buf) const { copyOut(a, start, len, buf); }
    void SetIntArrayRegion(jintArray a, jsize start, jsize len, const jint *buf) const { copyIn(a, start, len, buf); }
    void SetFloatArrayRegion(jfloatArray a, jsize start, jsize len, const jfloat *buf) const { copyIn(a, start, len, buf); }
    void SetBooleanArrayRegion(jbooleanArray a, jsize start, jsize len, const jboolean *buf) const { copyIn(a, start, len, buf); }

    jobject GetObjectArrayElement(jobjectArray array, jsize index) const {
        return (array && index >= 0 && index < array->length()) ? array->data[index] : nullptr;
    }
    void SetObjectArrayElement(jobjectArray array, jsize index, jobject value) const {
        if (array && index >= 0 && index < array->length()) array->data[index] = value;
    }

    // --- strings ------------------------------------------------------------------------------
    jstring NewStringUTF(const char *utf8) {
        auto *s = own(new _jstring());
        s->utf8 = utf8 ? utf8 : "";
        s->utf16Length = utf16LengthOf(s->utf8);
        return s;
    }
    jsize GetStringUTFLength(jstring s) const { return s ? static_cast<jsize>(s->utf8.size()) : 0; }
    jsize GetStringLength(jstring s) const { return s ? s->utf16Length : 0; }
    // The core always requests the whole string, so start/len (UTF-16 units) are not honoured
    // beyond copying the complete UTF-8 representation (no terminator, as in JNI).
    void GetStringUTFRegion(jstring s, jsize, jsize, char *buf) const {
        if (s && buf) memcpy(buf, s->utf8.data(), s->utf8.size());
    }

    // --- references / Java interop stubs ------------------------------------------------------
    // Local references are owned by the arena and released by clear(); deleting them individually
    // is a no-op, which matches JNI semantics where the reference, not the object, goes away.
    void DeleteLocalRef(jobject) const {}
    jclass FindClass(const char *) const { return nullptr; }
    jmethodID GetMethodID(jclass, const char *, const char *) const { return nullptr; }
    jmethodID GetStaticMethodID(jclass, const char *, const char *) const { return nullptr; }
    jobject NewObject(jclass, jmethodID, ...) const { return nullptr; }
    jboolean CallBooleanMethod(jobject, jmethodID, ...) const { return JNI_FALSE; }
    jint CallStaticIntMethod(jclass, jmethodID, ...) const { return 0; }
    void ExceptionClear() const {}

    // --- shim helpers (not part of JNI) -------------------------------------------------------
    jintArray wrapInts(const jint *values, jsize length) {
        jintArray a = NewIntArray(length);
        if (values && length > 0) memcpy(a->data.data(), values, sizeof(jint) * length);
        return a;
    }
    jfloatArray wrapFloats(const jfloat *values, jsize length) {
        jfloatArray a = NewFloatArray(length);
        if (values && length > 0) memcpy(a->data.data(), values, sizeof(jfloat) * length);
        return a;
    }
    void clear() { mArena.clear(); }

 private:
    std::vector<std::unique_ptr<_jobject>> mArena;

    template <typename T>
    T *own(T *object) {
        mArena.emplace_back(object);
        return object;
    }
    template <typename A>
    A *newArray(jsize length) {
        A *array = own(new A());
        array->data.assign(static_cast<size_t>(length > 0 ? length : 0), {});
        return array;
    }
    template <typename A, typename T>
    static void copyOut(const A *a, jsize start, jsize len, T *buf) {
        if (a && buf && len > 0) memcpy(buf, a->data.data() + start, sizeof(T) * len);
    }
    template <typename A, typename T>
    static void copyIn(A *a, jsize start, jsize len, const T *buf) {
        if (a && buf && len > 0) memcpy(a->data.data() + start, buf, sizeof(T) * len);
    }
    static jsize utf16LengthOf(const std::string &utf8) {
        jsize units = 0;
        for (size_t i = 0; i < utf8.size();) {
            const unsigned char c = static_cast<unsigned char>(utf8[i]);
            const size_t n = c < 0x80 ? 1 : (c >> 5) == 0x6 ? 2 : (c >> 4) == 0xE ? 3 : 4;
            units += n == 4 ? 2 : 1;
            i += n;
        }
        return units;
    }
};

#endif  // OHOS_JNI_SHIM_H
