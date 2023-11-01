#ifndef HSGRPC_AUTH_HPP
#define HSGRPC_AUTH_HPP

#include <grpc/support/log.h>
#include <grpcpp/server.h>
#include <set>

// TODO: hash tokens

namespace hsgrpc {

// Really insecure! Only for debugging usage
//
// https://datatracker.ietf.org/doc/html/rfc7617
class InsecureBasicAuthMetadataInterceptor
    : public grpc::experimental::Interceptor {
public:
  explicit InsecureBasicAuthMetadataInterceptor(
      grpc::experimental::ServerRpcInfo* info, std::set<std::string>& tokens)
      : info_(info), tokens_(tokens) {}

  void
  Intercept(grpc::experimental::InterceptorBatchMethods* methods) override {
    bool exit = false;
    if (methods->QueryInterceptionHookPoint(
            grpc::experimental::InterceptionHookPoints::
                POST_RECV_INITIAL_METADATA)) {
      // Here metadata is a multimap, however there should be only one
      // authorization key.
      //
      // TODO: support comma-separated value
      //
      // `authorization: Bearer foo, Basic bar`
      //
      // https://www.rfc-editor.org/rfc/rfc7230#section-3.2.2
      auto& metadata = info_->server_context()->client_metadata();
      if (auto authorization = metadata.find("authorization");
          authorization != metadata.end()) {
        auto auth_val = authorization->second;
        auto token =
            tokens_.find(std::string(auth_val.data(), auth_val.length()));
        exit = token == tokens_.end();
      } else {
        exit = true;
      }
    }
    if (exit) {
      // [?] Since this is in the POST_RECV_INITIAL_METADATA hook, there should
      // not be a race condition between TryCancel and the handler
      //
      // https://grpc.github.io/grpc/cpp/classgrpc_1_1_server_context_base.html#a88d3a0c3d53e39f38654ce8fba968301
      info_->server_context()->TryCancel();
    }
    methods->Proceed();
  }

private:
  grpc::experimental::ServerRpcInfo* info_;
  // e.g. "Basic dGVzdDoxMjMK"
  std::set<std::string>& tokens_;
};

class InsecureBasicAuthMetadataInterceptorFactory
    : public grpc::experimental::ServerInterceptorFactoryInterface {
public:
  explicit InsecureBasicAuthMetadataInterceptorFactory(
      std::set<std::string>& tokens)
      : tokens_(tokens) {}

  grpc::experimental::Interceptor*
  CreateServerInterceptor(grpc::experimental::ServerRpcInfo* info) override {
    return new InsecureBasicAuthMetadataInterceptor(info, tokens_);
  }

private:
  std::set<std::string> tokens_;
};

// ----------------------------------------------------------------------------

class BasicAuthMetadataProcessor : public grpc::AuthMetadataProcessor {
public:
  explicit BasicAuthMetadataProcessor(std::set<std::string> tokens)
      : tokens_(tokens) {}

  bool IsBlocking() const override { return false; }

  grpc::Status Process(const InputMetadata& auth_metadata,
                       grpc::AuthContext* context,
                       OutputMetadata* consumed_auth_metadata,
                       OutputMetadata* response_metadata) override {
    auto auth_md = auth_metadata.find("authorization");
    if (auth_md != auth_metadata.end()) {
      auto auth_md_value =
          std::string(auth_md->second.data(), auth_md->second.length());
      auto token = tokens_.find(auth_md_value);
      if (token != tokens_.end()) {
        // context->AddProperty("novel identity", *token);
        // context->SetPeerIdentityPropertyName("novel identity");
        consumed_auth_metadata->insert(std::make_pair(
            std::string(auth_md->first.data(), auth_md->first.length()),
            std::string(auth_md->second.data(), auth_md->second.length())));
        return grpc::Status::OK;
      } else {
        return grpc::Status(grpc::StatusCode::UNAUTHENTICATED,
                            std::string("Invalid token: ") + auth_md_value);
      }
    } else {
      return grpc::Status(grpc::StatusCode::UNAUTHENTICATED,
                          "No auth metadata found");
    }
  }

private:
  std::set<std::string> tokens_;
};

} // namespace hsgrpc

#endif // HSGRPC_AUTH_HPP
