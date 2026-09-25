// C ABI of crates/cascade-backend (src/ffi.rs). Keep in sync by hand.
#ifndef CASCADE_BACKEND_H
#define CASCADE_BACKEND_H
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct CascadeBackend CascadeBackend;

typedef void (*cascade_response_callback)(void *ctx, int32_t status, const char *content_type, const uint8_t *body, size_t len);
typedef void (*cascade_event_callback)(void *ctx, const uint8_t *json, size_t len);
typedef void (*cascade_drop_callback)(void *ctx);

int32_t cascade_backend_start(const char *data_dir, int32_t packaged, const char *instance_id, CascadeBackend **out, char **error);
uint16_t cascade_backend_port(const CascadeBackend *backend);
void cascade_backend_request(const CascadeBackend *backend, const char *method, const char *path_and_query, const uint8_t *body, size_t body_len, void *ctx, cascade_response_callback callback);
uint64_t cascade_backend_subscribe(const CascadeBackend *backend, void *ctx, cascade_event_callback callback, cascade_drop_callback dropped);
void cascade_backend_unsubscribe(const CascadeBackend *backend, uint64_t id);
void cascade_backend_stop(CascadeBackend *backend);
void cascade_string_free(char *value);

#ifdef __cplusplus
}
#endif
#endif
