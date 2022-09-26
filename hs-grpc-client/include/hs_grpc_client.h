#pragma once

#include <HsFFI.h>

namespace hsgrpc { namespace client {

struct hs_ssl_credentials_options_t {
  // SslCredentialsOptions.pem_root_certs
  const char* pem_root_certs_data;
  HsInt pem_root_certs_len;
  // SslCredentialsOptions.pem_private_key
  const char* pem_private_key_data;
  HsInt pem_private_key_len;
  // SslCredentialsOptions.pem_cert_chain
  const char* pem_cert_chain_data;
  HsInt pem_cert_chain_len;
};

struct hs_grpc_channel_t {
  std::shared_ptr<grpc::Channel> rep;
};

}} // namespace hsgrpc::client
