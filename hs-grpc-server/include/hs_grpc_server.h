#pragma once

#include <HsFFI.h>

#include <asio/experimental/concurrent_channel.hpp>
#include <cstdint>
#include <grpcpp/server.h>
#include <grpcpp/support/slice.h>

namespace hsgrpc {

using ChannelIn =
    asio::experimental::concurrent_channel<void(asio::error_code, grpc::Slice)>;

using ChannelOut = asio::experimental::concurrent_channel<void(
    asio::error_code, grpc::ByteBuffer)>;

// FIXME: use a lightweight structure instead (a real coroutine lock)
//
// Using bool for convenience, this can be any type actually.
using CoroLock =
    asio::experimental::concurrent_channel<void(asio::error_code, bool)>;

struct channel_in_t {
  std::shared_ptr<ChannelIn> rep;
};

struct channel_out_t {
  std::shared_ptr<ChannelOut> rep;
};

enum class StreamingType : uint8_t {
  NonStreaming = 1,
  ClientStreaming,
  ServerStreaming,
  BiDiStreaming
};

struct hs_ssl_server_credentials_options_t {
  // SslServerCredentialsOptions: pem_root_certs
  const char* pem_root_certs_data;
  HsInt pem_root_certs_len;
  // SslServerCredentialsOptions: list of pem_key_cert_pairs.private_key
  const char** pem_private_key_datas;
  HsInt* pem_private_key_lens;
  // SslServerCredentialsOptions: contents of pem_key_cert_pairs.cert_chain
  const char** pem_cert_chain_datas;
  HsInt* pem_cert_chain_lens;
  // SslServerCredentialsOptions: size of pem_key_cert_pairs
  HsInt pem_key_cert_pairs_size;
  // SslServerCredentialsOptions: client_certificate_request
  grpc_ssl_client_certificate_request_type client_certificate_request;
};

struct server_request_t {
  uint8_t* data;
  size_t data_size;
  HsInt handler_idx;
  channel_in_t* channel_in = nullptr;
  channel_out_t* channel_out = nullptr;
  CoroLock* coro_lock = nullptr;
  grpc::GenericServerContext* server_context = nullptr;
};

struct server_response_t {
  uint8_t* data;
  size_t data_size;
  HsInt status_code = GRPC_STATUS_OK;
  std::string* error_msg = nullptr;
  std::string* error_details = nullptr;
};

using HsCallback = void (*)(server_request_t*, server_response_t*);

struct read_channel_cb_data_t {
  HsInt ec;
  uint8_t* buff_data = nullptr;
  size_t buff_size = 0;
};

} // namespace hsgrpc
