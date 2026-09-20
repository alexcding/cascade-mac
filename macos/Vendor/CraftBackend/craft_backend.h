// C ABI of crates/craft-backend (src/ffi.rs). Keep in sync by hand.
#ifndef CRAFT_BACKEND_H
#define CRAFT_BACKEND_H
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct CraftBackend CraftBackend;

typedef void (*craft_response_callback)(void *ctx, int32_t status, const char *content_type, const uint8_t *body, size_t len);
typedef void (*craft_event_callback)(void *ctx, const uint8_t *json, size_t len);
typedef void (*craft_drop_callback)(void *ctx);

int32_t craft_backend_start(const char *data_dir, int32_t packaged, const char *instance_id, CraftBackend **out, char **error);
uint16_t craft_backend_port(const CraftBackend *backend);
void craft_backend_request(const CraftBackend *backend, const char *method, const char *path_and_query, const uint8_t *body, size_t body_len, void *ctx, craft_response_callback callback);
uint64_t craft_backend_subscribe(const CraftBackend *backend, void *ctx, craft_event_callback callback, craft_drop_callback dropped);
void craft_backend_unsubscribe(const CraftBackend *backend, uint64_t id);
void craft_backend_stop(CraftBackend *backend);
void craft_string_free(char *value);

#ifdef __cplusplus
}
#endif
#endif
