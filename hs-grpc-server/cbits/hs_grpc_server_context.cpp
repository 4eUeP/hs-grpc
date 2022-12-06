#include "hs_grpc_server.h"

#include <grpcpp/generic/async_generic_service.h>

// ----------------------------------------------------------------------------
extern "C" {

std::string* serverContext_peer(grpc::GenericServerContext* server_context) {
  std::string peer_uri = server_context->peer();
  return new std::string(peer_uri); // delete by haskell gc
}

// ----------------------------------------------------------------------------
} // End extern "C"
