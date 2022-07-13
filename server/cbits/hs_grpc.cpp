#include <HsFFI.h>

#include <iostream>
#include <memory>
#include <string>
#include <thread>

#include <grpc/support/log.h>
#include <grpcpp/generic/async_generic_service.h>
#include <grpcpp/grpcpp.h>
#include <grpcpp/support/proto_buffer_reader.h>

#include "hs_grpc.h"

using grpc::AsyncGenericService;
using grpc::ByteBuffer;
using grpc::GenericServerAsyncReaderWriter;
using grpc::GenericServerContext;
using grpc::ServerCompletionQueue;
using grpc::ServerContext;
using grpc::Slice;
using grpc::Status;

// ----------------------------------------------------------------------------

namespace hsgrpc {

enum class ProcessorStatus { CREATE, RECEIVING, RECEIVED, FINISH, DESTROY };

class HsAsyncProcessor {
public:
  HsAsyncProcessor(AsyncGenericService* service, ServerCompletionQueue* cq,
                   HsCallback callback)
      : service_(service), cq_(cq), stream_(&ctx_),
        status_(ProcessorStatus::CREATE), callback_(callback) {
    service_->RequestCall(&ctx_, &stream_, cq_, cq_, this);
    status_ = ProcessorStatus::RECEIVING;
  }

  void proceed() {
    if (status_ == ProcessorStatus::RECEIVING) {
      // Spawn a new instance to serve new clients while we process
      // the one for this HsAsyncProcessor. The instance will deallocate itself
      // as part of its FINISH state.
      new HsAsyncProcessor(service_, cq_, callback_);

      // Wait for the request message
      stream_.Read(&buffer, this);
      status_ = ProcessorStatus::RECEIVED;
    } else if (status_ == ProcessorStatus::RECEIVED) {
      auto method = ctx_.method();
      auto size = buffer.Length();

      std::vector<Slice> input_slices;
      std::string input;
      input.reserve(size);
      // TODO: grpc 1.39+ support DumpToSingleSlice
      buffer.Dump(&input_slices);
      for (auto& slice : input_slices) {
        input += std::string(std::begin(slice), std::end(slice));
      }

      server_request_t request;
      server_response_t response;

      request.data = (uint8_t*)input.data();
      request.data_size = input.size();
      request.method = (uint8_t*)method.data();
      request.method_size = method.size();

      // TODO: if (!callback_) ...
      (*callback_)(&request, &response);

      StreamingType streaming_type = response.streaming_type;
      switch (streaming_type) {
      case StreamingType::NonStreaming: {
        auto replySlice = Slice(response.data, response.data_size);
        std::free(response.data);
        stream_.Write(ByteBuffer(&replySlice, 1), this);
        status_ = ProcessorStatus::FINISH;
        break;
      }
      case StreamingType::ClientStreaming:
        // TODO
        throw std::logic_error("NotImplemented");
        break;
      case StreamingType::ServerStreaming:
        // TODO
        throw std::logic_error("NotImplemented");
        break;
      case StreamingType::BiDiStreaming:
        // TODO
        throw std::logic_error("NotImplemented");
        break;
      } // Let compiler check that all enum values are handled.
    } else if (status_ == ProcessorStatus::FINISH) {
      // TODO: also finish with error
      stream_.Finish(Status::OK, this);
      status_ = ProcessorStatus::DESTROY;
    } else {
      GPR_ASSERT(status_ == ProcessorStatus::DESTROY);
      delete this;
    }
  }

private:
  ProcessorStatus status_;
  ByteBuffer buffer;
  HsCallback callback_ = nullptr;

  AsyncGenericService* service_;
  GenericServerContext ctx_;
  ServerCompletionQueue* cq_;
  GenericServerAsyncReaderWriter stream_;
};

// This can be run in multiple threads if needed.
void processRpcs(AsyncGenericService* service, ServerCompletionQueue* cq,
                 HsCallback callback) {
  new HsAsyncProcessor(service, cq, callback);

  void* tag;
  bool ok;
  while (true) {
    GPR_ASSERT(cq->Next(&tag, &ok));
    // GPR_ASSERT(ok);
    static_cast<HsAsyncProcessor*>(tag)->proceed();
  }
}

} // namespace hsgrpc

// ----------------------------------------------------------------------------
extern "C" {

struct CppServer {
  std::unique_ptr<grpc::Server> server_;
  grpc::AsyncGenericService service_;
  std::vector<std::unique_ptr<ServerCompletionQueue>> cq_;
  std::vector<std::thread> server_threads_;
};

CppServer* new_server(const char* host, HsInt host_len, HsInt port,
                      HsInt parallelism) {
  const auto total_conc = std::thread::hardware_concurrency();
  if (parallelism <= 0 || parallelism > total_conc) {
    parallelism = total_conc;
  }
  std::string server_address(std::string(host, host_len) + ":" +
                             std::to_string(port));

  CppServer* server_data = new CppServer;
  grpc::ServerBuilder builder;
  builder.AddListeningPort(server_address, grpc::InsecureServerCredentials());
  builder.RegisterAsyncGenericService(&server_data->service_);
  for (int i = 0; i < parallelism; i++) {
    server_data->cq_.emplace_back(builder.AddCompletionQueue());
  }

  server_data->server_ = builder.BuildAndStart();
  if (server_data->server_) {
    std::cout << "Server listening on " << server_address << std::endl;
    return server_data;
  } else {
    delete server_data;
    return nullptr;
  }
}

void shutdown_server(CppServer* server) {
  server->server_->Shutdown();
  for (auto& cq : server->cq_) {
    cq->Shutdown();
  }
}

void delete_server(CppServer* server) { delete server; }

void run_server(CppServer* server, hsgrpc::HsCallback callback) {
  auto parallelism = server->cq_.size();
  // Proceed to the server's main loop.
  for (int i = 0; i < parallelism; i++) {
    server->server_threads_.emplace_back(std::thread([server, i, callback] {
      hsgrpc::processRpcs(&server->service_, server->cq_[i].get(), callback);
    }));
  }

  for (auto& thread : server->server_threads_) {
    thread.join();
  }
}

// ----------------------------------------------------------------------------
} // End extern "C"
