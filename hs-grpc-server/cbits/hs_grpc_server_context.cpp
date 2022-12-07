#include "hs_grpc_server.h"

#include <grpcpp/generic/async_generic_service.h>

// ----------------------------------------------------------------------------
extern "C" {

std::string* serverContext_peer(grpc::GenericServerContext* ctx) {
  std::string peer_uri = ctx->peer();
  return new std::string(peer_uri); // delete by haskell gc
}

// TODO: a generic way to handle std::multimap
const std::multimap<grpc::string_ref, grpc::string_ref>*
serverContext_client_metadata(grpc::GenericServerContext* ctx) {
  auto& metadata = ctx->client_metadata();
  return &metadata;
}

// Finds an element with key equivalent to key. If there are several elements
// with key in the metadata, any of them may be returned.
std::string* serverContext_client_metadata_find(grpc::GenericServerContext* ctx,
                                                const char* key,
                                                HsInt key_len) {
  auto& metadata = ctx->client_metadata();
  if (auto search = metadata.find(grpc::string_ref(key, key_len));
      search != metadata.end()) {
    auto val = search->second;
    return new std::string(val.begin(), val.end()); // delete on haskell side
  } else {
    return nullptr;
  }
}

// ----------------------------------------------------------------------------
} // End extern "C"
