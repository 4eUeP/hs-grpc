#pragma once

#include <cstdint>

namespace hsgrpc {

enum class StreamingType : uint8_t {
  NonStreaming = 1,
  ClientStreaming,
  ServerStreaming,
  BiDiStreaming
};

struct server_request_t {
  uint8_t* data;
  size_t data_size;
  uint8_t* method;
  size_t method_size;
};

struct server_response_t {
  StreamingType streaming_type;
  uint8_t* data;
  size_t data_size;
};

using HsCallback = void (*)(server_request_t*, server_response_t*);

} // namespace hsgrpc
