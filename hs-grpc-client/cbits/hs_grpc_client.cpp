#include <agrpc/asio_grpc.hpp>
#include <forward_list>
#include <grpcpp/create_channel.h>
#include <grpcpp/generic/generic_stub.h>
#include <thread>

#include "hs_grpc_client.h"

namespace hc = hsgrpc::client;

// ----------------------------------------------------------------------------
extern "C" {

hc::hs_grpc_channel_t*
new_hs_grpc_channel(const char* target, HsInt target_len,
                    hc::hs_ssl_credentials_options_t* ssl_opts) {
  std::shared_ptr<grpc::ChannelCredentials> creds;
  if (ssl_opts) {
    auto opts = grpc::SslCredentialsOptions();
    if (ssl_opts->pem_root_certs_data) {
      opts.pem_root_certs = std::string(ssl_opts->pem_root_certs_data,
                                        ssl_opts->pem_root_certs_len);
    }
    if (ssl_opts->pem_private_key_data) {
      opts.pem_private_key = std::string(ssl_opts->pem_private_key_data,
                                         ssl_opts->pem_private_key_len);
    }
    if (ssl_opts->pem_cert_chain_data) {
      opts.pem_cert_chain = std::string(ssl_opts->pem_cert_chain_data,
                                        ssl_opts->pem_cert_chain_len);
    }
    creds = grpc::SslCredentials(opts);
  } else {
    creds = grpc::InsecureChannelCredentials();
  }
  auto channel = grpc::CreateChannel(std::string(target, target_len), creds);
  return new hc::hs_grpc_channel_t{std::move(channel)};
}

void delete_hs_grpc_channel(hc::hs_grpc_channel_t* channel) { delete channel; }

struct hs_grpc_client_t {
  std::unique_ptr<grpc::GenericStub> stub_;
  agrpc::GrpcContext grpc_context_;
};

hs_grpc_client_t* new_hs_grpc_client(hc::hs_grpc_channel_t* channel,
                                     HsInt parallelism) {
  // Valid parallelism is [1, hardware_concurrency]
  const auto total_conc = std::thread::hardware_concurrency();
  if (parallelism <= 0 || parallelism > total_conc) {
    parallelism = total_conc;
  }

  auto stub = std::make_unique<grpc::GenericStub>(channel->rep);

  agrpc::GrpcContext grpc_context{std::make_unique<grpc::CompletionQueue>()};
  return new hs_grpc_client_t;
}

void run_grpc_client() {}

// ----------------------------------------------------------------------------
} // End extern "C"
