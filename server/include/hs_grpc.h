#pragma once

#include <HsFFI.h>

#include <asio/experimental/channel.hpp>
#include <cstdint>
#include <grpcpp/server.h>

namespace hsgrpc {

bool byteBufferDumpToString(grpc::ByteBuffer& buffer, std::string& input);

using ChannelIn =
    asio::experimental::channel<void(asio::error_code, std::string)>;

using ChannelOut =
    asio::experimental::channel<void(asio::error_code, grpc::ByteBuffer)>;

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
  uint8_t* method;
  size_t method_size;
  HsInt handler_idx;
  ChannelIn* channel_in = nullptr;
  ChannelOut* channel_out = nullptr;
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
  std::string* buf;
};

} // namespace hsgrpc
