// libcurl for the helper's Linux WebSocket (CurlRPCSocket). curl_easy_setopt and curl_easy_getinfo are variadic, which
// Swift can't call, so these wrap the few forms it needs.
#include <curl/curl.h>
#include <curl/websockets.h>

static inline CURLcode ccurl_set_long(CURL *h, CURLoption o, long v) { return curl_easy_setopt(h, o, v); }
static inline CURLcode ccurl_set_string(CURL *h, CURLoption o, const char *v) { return curl_easy_setopt(h, o, v); }
static inline CURLcode ccurl_set_slist(CURL *h, CURLoption o, struct curl_slist *v) { return curl_easy_setopt(h, o, v); }
static inline CURLcode ccurl_get_long(CURL *h, CURLINFO i, long *v) { return curl_easy_getinfo(h, i, v); }
static inline CURLcode ccurl_get_socket(CURL *h, curl_socket_t *v) { return curl_easy_getinfo(h, CURLINFO_ACTIVESOCKET, v); }
