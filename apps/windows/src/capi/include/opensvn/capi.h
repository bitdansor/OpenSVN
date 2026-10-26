#pragma once

#include <stdint.h>

#if defined(_WIN32)
#  if defined(OPENSVN_CAPI_EXPORTS)
#    define OPENSVN_CAPI __declspec(dllexport)
#  else
#    define OPENSVN_CAPI __declspec(dllimport)
#  endif
#else
#  define OPENSVN_CAPI
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef struct opensvn_service opensvn_service;

/// Progress lines arrive on the worker thread that runs the operation.
/// Do not call opensvn_destroy_service from this callback.
typedef void (*opensvn_progress_callback)(const char* line_utf8, void* user_data);

/// Creates the service from a JSON configuration:
/// {"svnPath": "...", "timeoutSeconds": 300, "journalDirectory": "...",
///  "conflictBackupRoot": "...", "inMemoryCredentials": false,
///  "maxConcurrentWrites": 4}
/// On failure returns 0 and writes a JSON error to out_error_json.
/// Both the returned service and every successful result/error string belong to
/// the caller; strings are released with opensvn_free_string.
OPENSVN_CAPI int32_t opensvn_create_service(const char* config_json_utf8,
                                            opensvn_service** out_service,
                                            char** out_error_json);

/// Waits for in-flight invocations, requests cancellation of all registered
/// requests, then destroys the service. It is safe to call concurrently with
/// opensvn_invoke, but not from a progress callback. An operation that never
/// returns (for example, a hung child process) will block destruction.
OPENSVN_CAPI void opensvn_destroy_service(opensvn_service* service);

/// Registers a request id before arguments are serialized, so a cancellation
/// that arrives during serialization cannot be lost. A registered request must
/// be consumed by opensvn_invoke or released with opensvn_release_request;
/// otherwise opensvn_destroy_service waits. Returns 1 on success, or 0 with a
/// JSON error in out_error_json.
OPENSVN_CAPI int32_t opensvn_register_request(opensvn_service* service,
                                              uint64_t request_id,
                                              char** out_error_json);

/// Abandons a request registered by opensvn_register_request without invoking
/// it. Stops any work already associated with the id. Late calls are harmless.
OPENSVN_CAPI void opensvn_release_request(opensvn_service* service,
                                          uint64_t request_id);

/// Runs one operation. `request_id` may be 0; otherwise it can be passed to
/// opensvn_cancel from another thread and must be unique among in-flight
/// requests. If the id was registered with opensvn_register_request, this call
/// consumes that registration. Returns a JSON string owned by the caller (free
/// with opensvn_free_string), or NULL with out_error_json set. out_error_json,
/// when set, is also freed with opensvn_free_string.
OPENSVN_CAPI char* opensvn_invoke(opensvn_service* service, uint64_t request_id,
                                  const char* operation_utf8,
                                  const char* parameters_json_utf8,
                                  opensvn_progress_callback progress,
                                  void* user_data, char** out_error_json);

/// Requests cancellation of an in-flight request. Late calls are harmless.
OPENSVN_CAPI void opensvn_cancel(opensvn_service* service, uint64_t request_id);

OPENSVN_CAPI void opensvn_free_string(char* value);

/// Version of the native bridge, for diagnostics.
OPENSVN_CAPI const char* opensvn_capi_version(void);

#ifdef __cplusplus
}
#endif
