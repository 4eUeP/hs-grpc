#include <grpcpp/server.h>

#include "example.grpc.pb.h"

class SendMessageInterceptor : public grpc::experimental::Interceptor {
public:
  explicit SendMessageInterceptor(grpc::experimental::ServerRpcInfo* info) {
    if (std::string(info->method()) == "/example.Example/Unary") {
      should_intercept_ = true;
    }
  }

  void
  Intercept(grpc::experimental::InterceptorBatchMethods* methods) override {
    if (should_intercept_ &&
        methods->QueryInterceptionHookPoint(
            grpc::experimental::InterceptionHookPoints::PRE_SEND_MESSAGE)) {

      auto msg_bs = methods->GetSerializedSendMessage();
      GPR_ASSERT(msg_bs);

      example::Request msg;
      // Note: grpc::GenericDeserialize will clear the input buffer
      const auto deserialize_status =
          grpc::GenericDeserialize<grpc::ProtoBufferReader, example::Request>(
              msg_bs, &msg);
      GPR_ASSERT(deserialize_status.ok());

      new_msg_.set_msg("hi, " + msg.msg());

      bool own_buffer;
      grpc::GenericSerialize<grpc::ProtoBufferWriter, example::Request>(
          new_msg_, msg_bs, &own_buffer);
    }
    methods->Proceed();
  }

private:
  example::Request new_msg_;
  bool should_intercept_{false};
};

class SendMessageInterceptorFactory
    : public grpc::experimental::ServerInterceptorFactoryInterface {
public:
  grpc::experimental::Interceptor*
  CreateServerInterceptor(grpc::experimental::ServerRpcInfo* info) override {
    return new SendMessageInterceptor(info);
  }
};

// ----------------------------------------------------------------------------
extern "C" {

grpc::experimental::ServerInterceptorFactoryInterface*
sendMessageInterceptorFactory() {
  return new SendMessageInterceptorFactory();
}

// ----------------------------------------------------------------------------
} // End extern "C"
