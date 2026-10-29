#ifndef TSIVA_CRASH_HANDLER_H
#define TSIVA_CRASH_HANDLER_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Installs handlers for fatal signals (SIGABRT, SIGBUS, SIGFPE, SIGILL, SIGSEGV, SIGTRAP). When one is
/// received, a plain-text report is written to `report_path` and the signal is passed on to the previous
/// handler, so the system crash report is still produced. Returns 0 on success.
int tsiva_crash_install(const char *report_path);

/// Restores the previous signal handlers.
void tsiva_crash_uninstall(void);

/// Writes a report for an uncaught Objective-C exception. The SIGABRT that follows the exception is then
/// not reported a second time. Not async-signal-safe; call it from the exception handler only.
int tsiva_crash_write_exception_report(const char *name, const char *reason, const uintptr_t *frames, int frame_count);

/// Writes a signal report without crashing. For tests only.
int tsiva_crash_write_signal_report_for_testing(int signal_number);

#ifdef __cplusplus
}
#endif

#endif
