// Fatal signal handling for Tsiva crash reports.
//
// Code that runs inside the signal handler must be async-signal-safe: no malloc, no stdio, no locks. Everything
// it needs (the report path and the list of loaded binaries) is prepared ahead of time in static buffers, and
// numbers are formatted by hand. The crashed thread's stack is walked from the machine context of the signal,
// so the report starts at the faulting instruction rather than inside the handler.
//
// Report format (one item per line):
//
//   tsiva-crash-v1
//   kind=signal | kind=exception
//   timestamp=<unix seconds>
//   signal=<number>  code=<si_code>  fault_address=0x...             (signal reports)
//   exception_name=...  exception_reason=...                          (exception reports, newlines escaped)
//   frames
//   0x... (one return address per line, innermost first)
//   images
//   0x<load address> 0x<__TEXT size> <uuid> <path>
//   end

#include "tsiva_crash_handler.h"

#include <dlfcn.h>
#include <execinfo.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#if __has_feature(ptrauth_calls)
#include <ptrauth.h>
#endif
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define TSIVA_MAX_FRAMES 128
#define TSIVA_IMAGES_BUFFER (256 * 1024)
#define TSIVA_ALT_STACK_SIZE (64 * 1024)

static const int kSignals[] = {SIGABRT, SIGBUS, SIGFPE, SIGILL, SIGSEGV, SIGTRAP};
#define TSIVA_SIGNAL_COUNT ((int)(sizeof(kSignals) / sizeof(kSignals[0])))

static char g_report_path[1024];
static char g_images[TSIVA_IMAGES_BUFFER];
static atomic_size_t g_images_length;
static atomic_bool g_installed;
static atomic_bool g_reported;
static bool g_image_callback_registered;
static struct sigaction g_previous[TSIVA_SIGNAL_COUNT];
static char g_alt_stack[TSIVA_ALT_STACK_SIZE];

// MARK: - Async-signal-safe writing

typedef struct {
    int fd;
    char buffer[512];
    size_t length;
} tsiva_writer;

static void writer_flush(tsiva_writer *w) {
    size_t offset = 0;
    while (offset < w->length) {
        ssize_t written = write(w->fd, w->buffer + offset, w->length - offset);
        if (written <= 0) break;
        offset += (size_t)written;
    }
    w->length = 0;
}

static void writer_bytes(tsiva_writer *w, const char *bytes, size_t count) {
    for (size_t i = 0; i < count; i++) {
        if (w->length == sizeof(w->buffer)) writer_flush(w);
        w->buffer[w->length++] = bytes[i];
    }
}

static void writer_string(tsiva_writer *w, const char *string) {
    writer_bytes(w, string, strlen(string));
}

static void writer_unsigned(tsiva_writer *w, uint64_t value) {
    char digits[24];
    int count = 0;
    do {
        digits[count++] = (char)('0' + value % 10);
        value /= 10;
    } while (value > 0);
    while (count > 0) writer_bytes(w, &digits[--count], 1);
}

static void writer_signed(tsiva_writer *w, int64_t value) {
    if (value < 0) {
        writer_bytes(w, "-", 1);
        writer_unsigned(w, (uint64_t)(-(value + 1)) + 1);
    } else {
        writer_unsigned(w, (uint64_t)value);
    }
}

static void writer_hex(tsiva_writer *w, uint64_t value) {
    static const char hex[] = "0123456789abcdef";
    char digits[16];
    int count = 0;
    do {
        digits[count++] = hex[value & 0xf];
        value >>= 4;
    } while (value > 0);
    writer_string(w, "0x");
    while (count > 0) writer_bytes(w, &digits[--count], 1);
}

/// Writes a single-line value: backslashes and line breaks are escaped.
static void writer_escaped(tsiva_writer *w, const char *string) {
    for (const char *c = string; c && *c; c++) {
        if (*c == '\\') writer_string(w, "\\\\");
        else if (*c == '\n') writer_string(w, "\\n");
        else if (*c == '\r') writer_string(w, "\\r");
        else writer_bytes(w, c, 1);
    }
}

static void write_frames_and_images(tsiva_writer *w, void *const *frames, int frame_count) {
    writer_string(w, "frames\n");
    for (int i = 0; i < frame_count; i++) {
        writer_hex(w, (uint64_t)(uintptr_t)frames[i]);
        writer_string(w, "\n");
    }
    writer_string(w, "images\n");
    size_t images_length = atomic_load(&g_images_length);
    writer_flush(w);
    size_t offset = 0;
    while (offset < images_length) {
        ssize_t written = write(w->fd, g_images + offset, images_length - offset);
        if (written <= 0) break;
        offset += (size_t)written;
    }
    writer_string(w, "end\n");
    writer_flush(w);
}

static int open_report(void) {
    if (g_report_path[0] == '\0') return -1;
    return open(g_report_path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
}

// MARK: - Loaded images

/// Records name, UUID, load address and __TEXT size of a binary. Runs when dyld loads it, not in a signal.
static void image_added(const struct mach_header *header, intptr_t slide) {
    (void)slide;
    Dl_info info;
    if (dladdr(header, &info) == 0 || info.dli_fname == NULL) return;

    uint8_t uuid[16] = {0};
    bool has_uuid = false;
    uint64_t text_size = 0;

    if (header->magic == MH_MAGIC_64) {
        const uint8_t *command = (const uint8_t *)header + sizeof(struct mach_header_64);
        for (uint32_t i = 0; i < header->ncmds; i++) {
            const struct load_command *lc = (const struct load_command *)command;
            if (lc->cmd == LC_UUID) {
                memcpy(uuid, ((const struct uuid_command *)lc)->uuid, 16);
                has_uuid = true;
            } else if (lc->cmd == LC_SEGMENT_64) {
                const struct segment_command_64 *segment = (const struct segment_command_64 *)lc;
                if (strncmp(segment->segname, SEG_TEXT, sizeof(segment->segname)) == 0) text_size = segment->vmsize;
            }
            command += lc->cmdsize;
        }
    }

    char line[1200];
    size_t length = 0;
    static const char hex[] = "0123456789abcdef";
    #define APPEND_CHAR(ch) do { if (length < sizeof(line) - 1) line[length++] = (ch); } while (0)
    #define APPEND_HEX(value) do { \
        uint64_t v = (value); char d[16]; int n = 0; \
        do { d[n++] = hex[v & 0xf]; v >>= 4; } while (v > 0); \
        APPEND_CHAR('0'); APPEND_CHAR('x'); while (n > 0) APPEND_CHAR(d[--n]); \
    } while (0)

    APPEND_HEX((uint64_t)(uintptr_t)header);
    APPEND_CHAR(' ');
    APPEND_HEX(text_size);
    APPEND_CHAR(' ');
    if (has_uuid) {
        for (int i = 0; i < 16; i++) {
            if (i == 4 || i == 6 || i == 8 || i == 10) APPEND_CHAR('-');
            APPEND_CHAR(hex[uuid[i] >> 4]);
            APPEND_CHAR(hex[uuid[i] & 0xf]);
        }
    } else {
        APPEND_CHAR('-');
    }
    APPEND_CHAR(' ');
    for (const char *c = info.dli_fname; *c; c++) APPEND_CHAR(*c);
    APPEND_CHAR('\n');
    #undef APPEND_HEX
    #undef APPEND_CHAR

    size_t current = atomic_load(&g_images_length);
    if (current + length > sizeof(g_images)) return;
    memcpy(g_images + current, line, length);
    atomic_store(&g_images_length, current + length);
}

// MARK: - Signal handling

/// Reads the program counter and frame pointer of the interrupted thread.
static bool machine_state(void *context, uintptr_t *pc, uintptr_t *fp) {
    if (context == NULL) return false;
    ucontext_t *uc = (ucontext_t *)context;
    if (uc->uc_mcontext == NULL) return false;
#if defined(__arm64__)
    *pc = (uintptr_t)__darwin_arm_thread_state64_get_pc(uc->uc_mcontext->__ss);
    *fp = (uintptr_t)__darwin_arm_thread_state64_get_fp(uc->uc_mcontext->__ss);
    return true;
#elif defined(__x86_64__)
    *pc = (uintptr_t)uc->uc_mcontext->__ss.__rip;
    *fp = (uintptr_t)uc->uc_mcontext->__ss.__rbp;
    return true;
#else
    return false;
#endif
}

/// Collects the faulting address followed by the return addresses of the frame pointer chain. Every frame
/// pointer is checked against the thread's stack bounds before it is read, so a corrupt stack ends the walk
/// instead of faulting again inside the handler.
static int walk_stack(uintptr_t pc, uintptr_t fp, void **frames, int capacity) {
    pthread_t thread = pthread_self();
    uintptr_t stack_high = (uintptr_t)pthread_get_stackaddr_np(thread);
    uintptr_t stack_low = stack_high - pthread_get_stacksize_np(thread);

    int count = 0;
    if (pc != 0) frames[count++] = (void *)pc;
    while (count < capacity) {
        if (fp == 0 || fp % sizeof(uintptr_t) != 0 || fp < stack_low || fp + 2 * sizeof(uintptr_t) > stack_high) break;
        uintptr_t next_fp = ((uintptr_t *)fp)[0];
        uintptr_t return_address = ((uintptr_t *)fp)[1];
#if __has_feature(ptrauth_calls)
        // arm64e signs return addresses; strip the signature so the address can be matched to a binary.
        return_address = (uintptr_t)ptrauth_strip((void *)return_address, ptrauth_key_return_address);
#endif
        if (return_address == 0) break;
        frames[count++] = (void *)return_address;
        if (next_fp <= fp) break;
        fp = next_fp;
    }
    return count;
}

static void write_signal_report(int signal_number, siginfo_t *info, void *context) {
    int fd = open_report();
    if (fd < 0) return;

    tsiva_writer w = {.fd = fd, .length = 0};
    writer_string(&w, "tsiva-crash-v1\nkind=signal\ntimestamp=");
    writer_unsigned(&w, (uint64_t)time(NULL));
    writer_string(&w, "\nsignal=");
    writer_signed(&w, signal_number);
    writer_string(&w, "\ncode=");
    writer_signed(&w, info ? info->si_code : 0);
    writer_string(&w, "\nfault_address=");
    writer_hex(&w, info ? (uint64_t)(uintptr_t)info->si_addr : 0);
    writer_string(&w, "\n");

    void *frames[TSIVA_MAX_FRAMES];
    uintptr_t pc = 0, fp = 0;
    int count = machine_state(context, &pc, &fp)
        ? walk_stack(pc, fp, frames, TSIVA_MAX_FRAMES)
        : backtrace(frames, TSIVA_MAX_FRAMES);  // No context (tests): the current stack is the best we have.
    write_frames_and_images(&w, frames, count);
    close(fd);
}

static void restore_previous_handlers(void) {
    for (int i = 0; i < TSIVA_SIGNAL_COUNT; i++) sigaction(kSignals[i], &g_previous[i], NULL);
}

static void handle_signal(int signal_number, siginfo_t *info, void *context) {
    bool expected = false;
    if (atomic_compare_exchange_strong(&g_reported, &expected, true)) {
        write_signal_report(signal_number, info, context);
    }

    // Hand the signal to whoever was installed before us (or the default action), so the process still
    // terminates and the system writes its own crash report.
    restore_previous_handlers();
    for (int i = 0; i < TSIVA_SIGNAL_COUNT; i++) {
        if (kSignals[i] != signal_number) continue;
        struct sigaction *previous = &g_previous[i];
        if ((previous->sa_flags & SA_SIGINFO) && previous->sa_sigaction != NULL) {
            previous->sa_sigaction(signal_number, info, context);
            return;
        }
        if (previous->sa_handler != SIG_DFL && previous->sa_handler != SIG_IGN && previous->sa_handler != NULL) {
            previous->sa_handler(signal_number);
            return;
        }
    }
    raise(signal_number);
}

// MARK: - Public API

int tsiva_crash_install(const char *report_path) {
    if (report_path == NULL || strlen(report_path) >= sizeof(g_report_path)) return -1;
    strncpy(g_report_path, report_path, sizeof(g_report_path) - 1);
    g_report_path[sizeof(g_report_path) - 1] = '\0';
    atomic_store(&g_reported, false);

    if (!g_image_callback_registered) {
        // Called immediately for every binary already loaded, then for each one loaded later.
        _dyld_register_func_for_add_image(image_added);
        g_image_callback_registered = true;
    }
    if (atomic_load(&g_installed)) return 0;

    // A separate stack lets the handler run even when the crash is a stack overflow.
    stack_t stack = {.ss_sp = g_alt_stack, .ss_size = sizeof(g_alt_stack), .ss_flags = 0};
    sigaltstack(&stack, NULL);

    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_sigaction = handle_signal;
    action.sa_flags = SA_SIGINFO | SA_ONSTACK;
    sigemptyset(&action.sa_mask);

    for (int i = 0; i < TSIVA_SIGNAL_COUNT; i++) {
        if (sigaction(kSignals[i], &action, &g_previous[i]) != 0) {
            for (int j = 0; j < i; j++) sigaction(kSignals[j], &g_previous[j], NULL);
            return -1;
        }
    }
    atomic_store(&g_installed, true);
    return 0;
}

void tsiva_crash_uninstall(void) {
    if (!atomic_load(&g_installed)) return;
    restore_previous_handlers();
    atomic_store(&g_installed, false);
}

int tsiva_crash_write_exception_report(const char *name, const char *reason, const uintptr_t *frames, int frame_count) {
    bool expected = false;
    if (!atomic_compare_exchange_strong(&g_reported, &expected, true)) return -1;

    int fd = open_report();
    if (fd < 0) return -1;
    tsiva_writer w = {.fd = fd, .length = 0};
    writer_string(&w, "tsiva-crash-v1\nkind=exception\ntimestamp=");
    writer_unsigned(&w, (uint64_t)time(NULL));
    writer_string(&w, "\nexception_name=");
    writer_escaped(&w, name);
    writer_string(&w, "\nexception_reason=");
    writer_escaped(&w, reason);
    writer_string(&w, "\n");

    void *pointers[TSIVA_MAX_FRAMES];
    int count = frame_count < TSIVA_MAX_FRAMES ? frame_count : TSIVA_MAX_FRAMES;
    for (int i = 0; i < count; i++) pointers[i] = (void *)frames[i];
    write_frames_and_images(&w, pointers, count);
    close(fd);
    return 0;
}

int tsiva_crash_write_signal_report_for_testing(int signal_number) {
    siginfo_t info;
    memset(&info, 0, sizeof(info));
    info.si_signo = signal_number;
    write_signal_report(signal_number, &info, NULL);
    atomic_store(&g_reported, false);
    return 0;
}
